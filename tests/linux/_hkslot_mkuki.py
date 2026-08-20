#!/usr/bin/env python3
# Build a minimal but STRUCTURALLY REAL PE/COFF file carrying a `.linux`
# section, which is the exact and only thing user/hkslot.ad's has_linux_section
# sniffs for. This is a fixture, not a kernel: it exists so the DOWNLOAD path
# can be measured without a 74 MB kernel build in the loop. The on-machine
# gate uses a real UKI.
import struct, sys, hashlib

def build(total, fill_byte):
    lfa = 128                       # e_lfanew: offset of the PE signature
    nsec = 2
    optsz = 240
    tab = lfa + 24 + optsz          # section table offset
    hdr_end = tab + nsec * 40
    body_off = 4096                 # where .linux's raw data starts
    assert hdr_end < body_off
    buf = bytearray(total)
    buf[0:2] = b'MZ'
    struct.pack_into('<I', buf, 60, lfa)
    # COFF header at lfa
    struct.pack_into('<I', buf, lfa, 0x00004550)          # "PE\0\0"
    struct.pack_into('<H', buf, lfa+4, 0x8664)            # machine x86-64
    struct.pack_into('<H', buf, lfa+6, nsec)              # NumberOfSections
    struct.pack_into('<H', buf, lfa+20, optsz)            # SizeOfOptionalHeader
    # section table
    def sec(i, name, raw_off, raw_sz):
        o = tab + i*40
        buf[o:o+8] = name.ljust(8, b'\0')
        struct.pack_into('<I', buf, o+16, raw_sz)         # SizeOfRawData
        struct.pack_into('<I', buf, o+20, raw_off)        # PointerToRawData
    linux_sz = total - body_off
    sec(0, b'.text',  body_off, 0)
    sec(1, b'.linux', body_off, linux_sz)
    # deterministic, incompressible-ish payload so two fixtures differ
    for i in range(body_off, total):
        buf[i] = (i * 31 + fill_byte) & 0xFF
    return bytes(buf)

if __name__ == '__main__':
    total = int(sys.argv[1]); fill = int(sys.argv[2]); out = sys.argv[3]
    b = build(total, fill)
    open(out,'wb').write(b)
    print(hashlib.sha256(b).hexdigest())
