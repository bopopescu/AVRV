import sys, pprint
from collections import defaultdict
from struct import pack
from myhdl import intbv, bin as biny
from pass2 import ops
from m328P_def import defs as G
from util import (
  update,
  int2addr,
  ibv,
  low,
  high,
  compute_dw,
  compute_db,
  instr,
  spec,
  spec_reversed,
  )


class InstructionsMixin(object):

  @instr
  def jmp(self, address):
    self.here += 2
    return address

  @instr
  def rjmp(self, address):
    return address

  @instr
  def rcall(self, address):
    return address

  @instr
  def cli(self):
    pass

  @instr
  def sei(self):
    pass

  @instr
  def ret(self):
    pass

  @instr
  def ldi(self, target, address):
    if isinstance(address, str):
      assert len(address) == 1, repr(address)
      address = ord(address)
    return target, address << 1

  @instr
  def out(self, target, address):
    return target, address

  @instr
  def sts(self, address, register):
    self.here += 2
    return address << 1, register

  @instr
  def mov(self, target, source):
    return target, source

  @instr
  def lds(self, target, address):
    self.here += 2
    return target, address << 1

  @instr
  def sbrs(self, target, address):
    return target, address

  @spec
  def st_post_incr(self, ptr, register):
    pass

  @spec_reversed
  def ld_post_incr(self, register, ptr):
    pass

  @spec_reversed
  def ld_pre_decr(self, register, ptr):
    pass

  @spec_reversed
  def lpm_post_incr(self, register, ptr):
    pass

  @instr
  def cpi(self, register, immediate):
    return register, immediate

  @instr
  def brne(self, address):
    return address

  @instr
  def breq(self, address):
    return address

  @instr
  def inc(self, address):
    return address

  @instr
  def mul(self, target, source):
    return target, source

  @instr
  def brlo(self, address):
    return address

  @instr
  def subi(self, target, source):
    return target, source

  @instr
  def add(self, target, source):
    return target, source

  @instr
  def dec(self, address):
    return address

  @instr
  def clr(self, address):
    return address

  @instr
  def lsl(self, address):
    return address

  @instr
  def brcc(self, address):
    return address

  @instr
  def or_(self, target, source):
    return target, source

  @instr
  def push(self, address):
    return address

  @instr
  def swap(self, address):
    return address

  @instr
  def pop(self, address):
    return address

  @instr
  def movw(self, target, source):
    return target, source

  @instr
  def andi(self, target, source):
    return target, source

  @instr
  def adiw(self, target, source):
    return target, source

  def lpm(self, target, source):
    assert source == 30, repr(source) # Must be Z
    self._one('lpm', target)

  @instr
  def cp(self, target, source):
    return target, source

  @instr
  def cpc(self, target, source):
    return target, source

  @instr
  def brsh(self, address):
    return address

  @instr
  def cpse(self, target, source):
    return target, source

  @instr
  def sbiw(self, target, source):
    return target, source

  @instr
  def lsr(self, address):
    return address

  @instr
  def ijmp(self):
    pass

  def _one(self, op, address):
    name, address = self._name_or_addr(address)
    addr = self._get_here()
##    print 'assembling %s instruction at %s to %s' % (op, addr, name)
    self.data[addr] = (op, address)
    self.here += 2

  def _instruction_namespace(self):
    for n in dir(InstructionsMixin):
      if n.startswith('_'):
        continue
      yield n, getattr(self, n)


class AVRAssembly(InstructionsMixin, object):

  def __init__(self, initial_context=None):
    if initial_context is None:
      initial_context = G.copy()

    self.context = defaultdict(lambda: int2addr(0))
    self.context.update(self._instruction_namespace())
    self.context.update((f.__name__, f) for f in (
        self.define,
        self.org,
        self.label,
        self.dw,
        self.db,
        low,
        high,
        )
      )
    self.context['range'] = xrange
    self.context.update(initial_context)

    self.here = int2addr(0)
    self.data = {}

  # Directives

  def define(self, **defs):
    for k, v in defs.iteritems():
      if isinstance(v, int):
        defs[k] = v = ibv(v)
##      print 'defining %s = %#x' % (k, v)
    self.context.update(defs)

  def org(self, address):
    address = ibv(address)
##    print 'setting org to %#06x' % (address,)
    update(self.here, address)

  def label(self, label_thunk, reserves=0):
    assert isinstance(label_thunk, intbv), repr(label_thunk)
    assert label_thunk == 0, repr(label_thunk)
    name = self._name_of_address_thunk(label_thunk)
##    print 'label %s => %#06x' % (name, self.here)
    update(label_thunk, self.here)
    if reserves:
      assert reserves > 0, repr(reserves)
      self.here += reserves

  def dw(self, *values):
    addr = self._get_here()
    data = compute_dw(values)
    nbytes = len(data)
    print 'assembling %i data words at %s for %s => %r' % (nbytes/2, addr, values, data)
    self.data[addr] = ('dw', values, data)
    self.here += nbytes
##    values_bin_str = values_to_dw(values)
##    self.here += len(values_bin_str)

  def db(self, *values):
    addr = self._get_here()
    data = compute_db(values)
    nbytes = len(data)
    print 'assembling %i data bytes at %s for %s => %r' % (nbytes, addr, values, data)
    self.data[addr] = ('db', values, data)
    self.here += nbytes

  # Assembler proper

  def assemble(self, text):
    exec text in self.context
    del self.context['__builtins__']

  def assemble_file(self, filename):
    execfile(filename, self.context)
    del self.context['__builtins__']

  def pass2(self):
    accumulator = {}
    for addr in sorted(self.data):
      instruction = self.data[addr]
      op, args = instruction[0], instruction[1:]

      # Adjust addresses for relative ops.
      if op in ('rcall', 'rjmp'):
        args = self._adjust(op, args, ibv(int(addr, 16)))

      opf = ops.get(op, lambda *args: args)
      n, data = opf(*args)

      if n == -1:
        bindata = data
      elif n == 16:
        bindata = pack('H', data)
      else:
        bindata = pack('2H', data[32:16], data[16:])

##      if op in ('db', 'dw'):
##        print addr, 10 * ' ', op, len(data), 'bytes:', repr(data)
##      else:
##        try:
##          fdata = '%-10x' % (data,)
##        except TypeError:
##          print addr, 10 * '.', instruction, repr(data)
##        else:
##          print addr, fdata, instruction, repr(bindata)

      accumulator[addr] = bindata

    return accumulator

  def _name_of_address_thunk(self, thunk):
    for k, v in self.context.iteritems():
      if v is thunk:
        return k
    return '%#06x' % thunk

  def _get_here(self):
    addr = '%#06x' % (self.here,)
    assert addr not in self.data
    return addr

  def _name_or_addr(self, address):
    if isinstance(address, str):
      assert len(address) == 1, repr(address)
      address = ord(address)

    if isinstance(address, int):
      name = '%#06x' % address
      address = int2addr(address)
    else:
      assert isinstance(address, intbv), repr(address)
      name = self._name_of_address_thunk(address)
    return name, address

  def _adjust(self, op, args, addr):
    return (ibv(args[0] - addr - 1),)


if __name__ == '__main__':
  aa = AVRAssembly()
  aa.assemble_file('asm.py')

##  print ; print ; print
##  pprint.pprint(dict(aa.context))
##  print ; print ; print
##  pprint.pprint(dict(aa.data))
##  print ; print ; print
##  pprint.pprint(aa.pass2())
  data = aa.pass2()
  print ; print ; print
  pprint.pprint(data)
  from intelhex import IntelHex
  ih = IntelHex()
  for addr, val in data.iteritems():
    addr = int(addr, 16)
    if isinstance(val, str):
      ih.puts(addr, val)
    else:
      print 'non-str', addr, repr(val)
  ih.dump(tofile=open('pavr.hex', 'w'))
