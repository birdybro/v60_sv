#!/usr/bin/env python3
"""Simple V60 assembler for test binaries.
Encodes instructions as raw bytes for loading into the simulator.
"""

import struct
import sys

class V60Asm:
    """Minimal V60 instruction assembler."""

    # Format I ALU opcode table: {mnemonic: {size: opcode}}
    _FMT1_OPCODES = {
        'mov':  {'b': 0x09, 'h': 0x1B, 'w': 0x2D},
        'add':  {'b': 0x80, 'h': 0x82, 'w': 0x84},
        'or':   {'b': 0x88, 'h': 0x8A, 'w': 0x8C},
        'addc': {'b': 0x90, 'h': 0x92, 'w': 0x94},
        'subc': {'b': 0x98, 'h': 0x9A, 'w': 0x9C},
        'and':  {'b': 0xA0, 'h': 0xA2, 'w': 0xA4},
        'sub':  {'b': 0xA8, 'h': 0xAA, 'w': 0xAC},
        'xor':  {'b': 0xB0, 'h': 0xB2, 'w': 0xB4},
        'cmp':  {'b': 0xB8, 'h': 0xBA, 'w': 0xBC},
        'not':  {'b': 0x38, 'h': 0x3A, 'w': 0x3C},
        'neg':  {'b': 0x39, 'h': 0x3B, 'w': 0x3D},
    }

    def __init__(self):
        self.code = bytearray()

    def nop(self):
        self.code.append(0xCD)

    def halt(self):
        self.code.append(0x00)

    def _encode_mod_register(self, reg):
        """Encode mod field for register addressing mode (m=1, mod[7:5]=011)."""
        return 0x60 | (reg & 0x1F)

    def _encode_mod_imm_quick(self, val):
        """Encode mod field for immediate quick (m=0, mod[7:4]=1110, mod[3:0]=val)."""
        return 0xE0 | (val & 0x0F)

    def _encode_mod_immediate(self):
        """Encode mod byte for full immediate (m=0, mod=0xF4)."""
        return 0xF4

    def _size_byte_count(self, size):
        """Return byte count for a data size ('b'=1, 'h'=2, 'w'=4)."""
        return {'b': 1, 'h': 2, 'w': 4}[size]

    # =========================================================================
    # Generic Format I helper
    # =========================================================================
    def _fmt1_reg_reg(self, mnemonic, size, src_reg, dst_reg):
        """Format I: Rsrc, Rdst — register to register.
        d=0 (reg=source), m=1 (mod=register dest)."""
        opcode = self._FMT1_OPCODES[mnemonic][size]
        byte1 = (1 << 6) | (0 << 5) | (src_reg & 0x1F)
        mod = self._encode_mod_register(dst_reg)
        self.code.extend([opcode, byte1, mod])

    def _fmt1_imm_reg(self, mnemonic, size, imm_val, dst_reg):
        """Format I: #imm, Rdst — immediate to register.
        d=1 (reg=destination), m=0 (mod=immediate source)."""
        opcode = self._FMT1_OPCODES[mnemonic][size]
        byte1 = (0 << 6) | (1 << 5) | (dst_reg & 0x1F)
        mod = self._encode_mod_immediate()
        self.code.extend([opcode, byte1, mod])
        nbytes = self._size_byte_count(size)
        self.code.extend(imm_val.to_bytes(nbytes, 'little'))

    def _fmt1_immq_reg(self, mnemonic, size, quick_val, dst_reg):
        """Format I: #quick, Rdst — immediate quick to register.
        d=1 (reg=destination), m=0 (mod=imm quick source)."""
        opcode = self._FMT1_OPCODES[mnemonic][size]
        byte1 = (0 << 6) | (1 << 5) | (dst_reg & 0x1F)
        mod = self._encode_mod_imm_quick(quick_val)
        self.code.extend([opcode, byte1, mod])

    # =========================================================================
    # MOV convenience methods (preserved from Phase 2)
    # =========================================================================
    def mov_reg_reg(self, size, src_reg, dst_reg):
        self._fmt1_reg_reg('mov', size, src_reg, dst_reg)

    def mov_imm_reg(self, size, imm_val, dst_reg):
        self._fmt1_imm_reg('mov', size, imm_val, dst_reg)

    def mov_immq_reg(self, size, quick_val, dst_reg):
        self._fmt1_immq_reg('mov', size, quick_val, dst_reg)

    # =========================================================================
    # ALU Format I convenience methods
    # =========================================================================
    def add_reg_reg(self, size, src_reg, dst_reg):
        self._fmt1_reg_reg('add', size, src_reg, dst_reg)

    def add_imm_reg(self, size, imm_val, dst_reg):
        self._fmt1_imm_reg('add', size, imm_val, dst_reg)

    def sub_reg_reg(self, size, src_reg, dst_reg):
        self._fmt1_reg_reg('sub', size, src_reg, dst_reg)

    def sub_imm_reg(self, size, imm_val, dst_reg):
        self._fmt1_imm_reg('sub', size, imm_val, dst_reg)

    def cmp_reg_reg(self, size, src_reg, dst_reg):
        self._fmt1_reg_reg('cmp', size, src_reg, dst_reg)

    def cmp_imm_reg(self, size, imm_val, dst_reg):
        self._fmt1_imm_reg('cmp', size, imm_val, dst_reg)

    def and_reg_reg(self, size, src_reg, dst_reg):
        self._fmt1_reg_reg('and', size, src_reg, dst_reg)

    def and_imm_reg(self, size, imm_val, dst_reg):
        self._fmt1_imm_reg('and', size, imm_val, dst_reg)

    def or_reg_reg(self, size, src_reg, dst_reg):
        self._fmt1_reg_reg('or', size, src_reg, dst_reg)

    def or_imm_reg(self, size, imm_val, dst_reg):
        self._fmt1_imm_reg('or', size, imm_val, dst_reg)

    def xor_reg_reg(self, size, src_reg, dst_reg):
        self._fmt1_reg_reg('xor', size, src_reg, dst_reg)

    def xor_imm_reg(self, size, imm_val, dst_reg):
        self._fmt1_imm_reg('xor', size, imm_val, dst_reg)

    def not_reg_reg(self, size, src_reg, dst_reg):
        self._fmt1_reg_reg('not', size, src_reg, dst_reg)

    def not_imm_reg(self, size, imm_val, dst_reg):
        self._fmt1_imm_reg('not', size, imm_val, dst_reg)

    def neg_reg_reg(self, size, src_reg, dst_reg):
        self._fmt1_reg_reg('neg', size, src_reg, dst_reg)

    def neg_imm_reg(self, size, imm_val, dst_reg):
        self._fmt1_imm_reg('neg', size, imm_val, dst_reg)

    def addc_reg_reg(self, size, src_reg, dst_reg):
        self._fmt1_reg_reg('addc', size, src_reg, dst_reg)

    def addc_imm_reg(self, size, imm_val, dst_reg):
        self._fmt1_imm_reg('addc', size, imm_val, dst_reg)

    def subc_reg_reg(self, size, src_reg, dst_reg):
        self._fmt1_reg_reg('subc', size, src_reg, dst_reg)

    def subc_imm_reg(self, size, imm_val, dst_reg):
        self._fmt1_imm_reg('subc', size, imm_val, dst_reg)

    # =========================================================================
    # Format III: INC/DEC
    # =========================================================================
    def inc_reg(self, size, reg):
        """INC.size Rreg — Format III (m=1 for register dest)."""
        base = {'b': 0xD8, 'h': 0xDA, 'w': 0xDC}[size]
        opcode = base | 1  # m=1 for register
        mod = self._encode_mod_register(reg)
        self.code.extend([opcode, mod])

    def dec_reg(self, size, reg):
        """DEC.size Rreg — Format III (m=1 for register dest)."""
        base = {'b': 0xD0, 'h': 0xD2, 'w': 0xD4}[size]
        opcode = base | 1  # m=1 for register
        mod = self._encode_mod_register(reg)
        self.code.extend([opcode, mod])

    # =========================================================================
    # Format IV: Bcc (branches)
    # =========================================================================
    # Condition codes
    BV, BNV, BL, BNL = 0x0, 0x1, 0x2, 0x3
    BE, BNE, BNH, BH = 0x4, 0x5, 0x6, 0x7
    BN, BP, BR, BNOP = 0x8, 0x9, 0xA, 0xB
    BLT, BGE, BLE, BGT = 0xC, 0xD, 0xE, 0xF

    def bcc_short(self, cond, disp):
        """Bcc short: 2 bytes (opcode=0x60|cond, 8-bit signed displacement).
        Target = PC_of_branch + disp."""
        opcode = 0x60 | (cond & 0xF)
        self.code.extend([opcode, disp & 0xFF])

    def bcc_long(self, cond, disp):
        """Bcc long: 3 bytes (opcode=0x70|cond, 16-bit signed LE displacement).
        Target = PC_of_branch + disp."""
        opcode = 0x70 | (cond & 0xF)
        self.code.append(opcode)
        self.code.extend((disp & 0xFFFF).to_bytes(2, 'little'))

    def br_short(self, disp):
        self.bcc_short(self.BR, disp)

    def br_long(self, disp):
        self.bcc_long(self.BR, disp)

    # =========================================================================
    # GETPSW
    # =========================================================================
    def getpsw(self, dst_reg):
        """GETPSW Rdst — store PSW to register.
        Format III: opcode = 0xF7 (m=1 for register dest)."""
        opcode = 0xF7  # GETPSW with m=1
        mod = self._encode_mod_register(dst_reg)
        self.code.extend([opcode, mod])

    def write(self, filename):
        with open(filename, 'wb') as f:
            f.write(self.code)
        print(f"Wrote {len(self.code)} bytes to {filename}")


def build_phase2_test():
    """Build Phase 2 test: MOV and GETPSW instructions."""
    a = V60Asm()

    # Test 1: MOV.W #0x12345678, R0  (immediate to register, word)
    a.mov_imm_reg('w', 0x12345678, 0)

    # Test 2: MOV.W R0, R1  (register to register, word)
    a.mov_reg_reg('w', 0, 1)

    # Test 3: MOV.W #7, R2  (immediate quick to register, word)
    a.mov_immq_reg('w', 7, 2)

    # Test 4: MOV.H #0xABCD, R3  (immediate to register, half)
    a.mov_imm_reg('h', 0xABCD, 3)

    # Test 5: MOV.B #0x42, R4  (immediate to register, byte)
    a.mov_imm_reg('b', 0x42, 4)

    # Test 6: GETPSW R5  (read PSW into R5)
    a.getpsw(5)

    # Test 7: MOV.W R2, R6  (register to register — copies R2's value)
    a.mov_reg_reg('w', 2, 6)

    # HALT
    a.halt()

    a.write('tests/phase2_test.bin')


def build_phase3_test():
    """Build Phase 3 test: ALU instructions with flag verification."""
    a = V60Asm()

    # --- Setup: load known values into registers ---
    # R0 = 0x00000010 (16)
    a.mov_imm_reg('w', 0x00000010, 0)
    # R1 = 0x00000003
    a.mov_imm_reg('w', 0x00000003, 1)

    # Test 1: ADD.W R1, R0 → R0 = 0x13, flags: Z=0 S=0 OV=0 CY=0
    a.add_reg_reg('w', 1, 0)
    a.getpsw(20)   # R20 = PSW after ADD

    # Test 2: SUB.W R1, R0 → R0 = 0x13 - 3 = 0x10
    a.sub_reg_reg('w', 1, 0)
    a.getpsw(21)   # R21 = PSW after SUB

    # Test 3: CMP.W #0x10, R0 → flags only (equal: Z=1), R0 unchanged
    a.cmp_imm_reg('w', 0x00000010, 0)
    a.getpsw(22)   # R22 = PSW after CMP (expect Z=1)

    # Test 4: AND.W R1, R0 → R0 = 0x10 & 0x03 = 0x00
    a.and_reg_reg('w', 1, 0)
    a.getpsw(23)   # R23 = PSW after AND (expect Z=1)

    # Reload R0 = 0x10
    a.mov_imm_reg('w', 0x00000010, 0)

    # Test 5: OR.W #0x0F, R0 → R0 = 0x10 | 0x0F = 0x1F
    a.or_imm_reg('w', 0x0000000F, 0)
    a.getpsw(24)   # R24 = PSW after OR

    # Test 6: XOR.W R1, R0 → R0 = 0x1F ^ 0x03 = 0x1C
    a.xor_reg_reg('w', 1, 0)

    # Test 7: NOT.W R0, R2 → R2 = ~0x1C = 0xFFFFFFE3
    a.not_reg_reg('w', 0, 2)
    a.getpsw(25)   # R25 = PSW after NOT (expect S=1)

    # Test 8: NEG.W R1, R3 → R3 = -3 = 0xFFFFFFFD
    a.neg_reg_reg('w', 1, 3)
    a.getpsw(26)   # R26 = PSW after NEG (expect S=1, CY=1)

    # Test 9: INC.W R0 → R0 = 0x1C + 1 = 0x1D
    a.inc_reg('w', 0)
    a.getpsw(27)   # R27 = PSW after INC

    # Test 10: DEC.W R0 → R0 = 0x1D - 1 = 0x1C
    a.dec_reg('w', 0)
    a.getpsw(28)   # R28 = PSW after DEC

    # Test 11: ADDC.W R1, R0 — first set up carry with CMP
    # CMP.W #0, R1 → CY=0 (3 - 0 = 3, no borrow)
    a.cmp_imm_reg('w', 0x00000000, 1)
    # ADDC.W R1, R0 → R0 = 0x1C + 3 + CY(0) = 0x1F
    a.addc_reg_reg('w', 1, 0)

    # Test 12: Set up carry by subtracting larger value
    # CMP.W #0x20, R0 → 0x1F - 0x20 → borrow → CY=1
    a.cmp_imm_reg('w', 0x00000020, 0)
    # SUBC.W R1, R0 → R0 = 0x1F - 3 - CY(1) = 0x1B
    a.subc_reg_reg('w', 1, 0)
    a.getpsw(29)   # R29 = PSW after SUBC (will be AP reg but that's fine)

    # HALT
    a.halt()

    a.write('tests/phase3_test.bin')

    # Print disassembly
    print("\nPhase 3 test disassembly:")
    offset = 0x1000
    print(f"  0x{offset:04X}: MOV.W #0x10, R0")
    print(f"         MOV.W #0x03, R1")
    print(f"         ADD.W R1, R0        ; R0=0x13")
    print(f"         GETPSW R20")
    print(f"         SUB.W R1, R0        ; R0=0x10")
    print(f"         GETPSW R21")
    print(f"         CMP.W #0x10, R0     ; Z=1, R0 unchanged")
    print(f"         GETPSW R22")
    print(f"         AND.W R1, R0        ; R0=0x00")
    print(f"         GETPSW R23")
    print(f"         MOV.W #0x10, R0     ; reload")
    print(f"         OR.W #0x0F, R0      ; R0=0x1F")
    print(f"         GETPSW R24")
    print(f"         XOR.W R1, R0        ; R0=0x1C")
    print(f"         NOT.W R0, R2        ; R2=0xFFFFFFE3")
    print(f"         GETPSW R25")
    print(f"         NEG.W R1, R3        ; R3=0xFFFFFFFD")
    print(f"         GETPSW R26")
    print(f"         INC.W R0            ; R0=0x1D")
    print(f"         GETPSW R27")
    print(f"         DEC.W R0            ; R0=0x1C")
    print(f"         GETPSW R28")
    print(f"         CMP.W #0, R1        ; CY=0")
    print(f"         ADDC.W R1, R0       ; R0=0x1F")
    print(f"         CMP.W #0x20, R0     ; CY=1")
    print(f"         SUBC.W R1, R0       ; R0=0x1B")
    print(f"         GETPSW R29")
    print(f"         HALT")

    # Print hex dump
    print(f"\nHex dump ({len(a.code)} bytes):")
    for i, b in enumerate(a.code):
        print(f"  0x{0x1000+i:04X}: 0x{b:02X}")


def build_phase4_test():
    """Build Phase 4 test: All 14 Bcc conditions."""
    a = V60Asm()

    # Setup
    a.mov_imm_reg('w', 10, 0)    # R0 = 10 (reference for CMP)
    a.mov_imm_reg('w', 0, 10)    # R10 = 0 (success counter)
    a.mov_imm_reg('w', 0, 11)    # R11 = 0 (fail marker)

    # Pattern for each "taken" test:
    #   CMP.W #val, R0     ; set flags (7 bytes)
    #   Bcc.short +4       ; taken → skip 2-byte INC R11 (2 bytes)
    #   INC.W R11          ; FAIL: reached if branch not taken (2 bytes)
    #   INC.W R10          ; SUCCESS counter (2 bytes)
    # Total per test: 13 bytes (with CMP) or 6 bytes (without CMP)

    # === Group 1: CMP #5, R0 → 10-5=5 → Z=0, S=0, OV=0, CY=0 ===

    # Test 1: BNV (OV=0 → taken)
    a.cmp_imm_reg('w', 5, 0)
    a.bcc_short(a.BNV, 4)
    a.inc_reg('w', 11)
    a.inc_reg('w', 10)          # R10=1

    # Test 2: BNL (CY=0 → taken)
    a.cmp_imm_reg('w', 5, 0)
    a.bcc_short(a.BNL, 4)
    a.inc_reg('w', 11)
    a.inc_reg('w', 10)          # R10=2

    # Test 3: BNE (Z=0 → taken)
    a.cmp_imm_reg('w', 5, 0)
    a.bcc_short(a.BNE, 4)
    a.inc_reg('w', 11)
    a.inc_reg('w', 10)          # R10=3

    # Test 4: BH (!CY & !Z → taken)
    a.cmp_imm_reg('w', 5, 0)
    a.bcc_short(a.BH, 4)
    a.inc_reg('w', 11)
    a.inc_reg('w', 10)          # R10=4

    # Test 5: BP (S=0 → taken)
    a.cmp_imm_reg('w', 5, 0)
    a.bcc_short(a.BP, 4)
    a.inc_reg('w', 11)
    a.inc_reg('w', 10)          # R10=5

    # Test 6: BGE (!(S^OV) → taken)
    a.cmp_imm_reg('w', 5, 0)
    a.bcc_short(a.BGE, 4)
    a.inc_reg('w', 11)
    a.inc_reg('w', 10)          # R10=6

    # Test 7: BGT (!((S^OV)|Z) → taken)
    a.cmp_imm_reg('w', 5, 0)
    a.bcc_short(a.BGT, 4)
    a.inc_reg('w', 11)
    a.inc_reg('w', 10)          # R10=7

    # === Group 2: CMP #10, R0 → 10-10=0 → Z=1, S=0, OV=0, CY=0 ===

    # Test 8: BE (Z=1 → taken)
    a.cmp_imm_reg('w', 10, 0)
    a.bcc_short(a.BE, 4)
    a.inc_reg('w', 11)
    a.inc_reg('w', 10)          # R10=8

    # Test 9: BNH (CY|Z → taken since Z=1)
    a.cmp_imm_reg('w', 10, 0)
    a.bcc_short(a.BNH, 4)
    a.inc_reg('w', 11)
    a.inc_reg('w', 10)          # R10=9

    # Test 10: BLE ((S^OV)|Z → taken since Z=1)
    a.cmp_imm_reg('w', 10, 0)
    a.bcc_short(a.BLE, 4)
    a.inc_reg('w', 11)
    a.inc_reg('w', 10)          # R10=10

    # === Group 3: CMP #15, R0 → 10-15=-5 → Z=0, S=1, OV=0, CY=1 ===

    # Test 11: BL (CY=1 → taken)
    a.cmp_imm_reg('w', 15, 0)
    a.bcc_short(a.BL, 4)
    a.inc_reg('w', 11)
    a.inc_reg('w', 10)          # R10=11

    # Test 12: BN (S=1 → taken)
    a.cmp_imm_reg('w', 15, 0)
    a.bcc_short(a.BN, 4)
    a.inc_reg('w', 11)
    a.inc_reg('w', 10)          # R10=12

    # Test 13: BLT (S^OV = 1^0 = 1 → taken)
    a.cmp_imm_reg('w', 15, 0)
    a.bcc_short(a.BLT, 4)
    a.inc_reg('w', 11)
    a.inc_reg('w', 10)          # R10=13

    # === Group 4: Overflow test ===
    # R2 = 0x7FFFFFFF, INC → 0x80000000, OV=1
    a.mov_imm_reg('w', 0x7FFFFFFF, 2)
    a.inc_reg('w', 2)

    # Test 14: BV (OV=1 → taken)
    a.bcc_short(a.BV, 4)
    a.inc_reg('w', 11)
    a.inc_reg('w', 10)          # R10=14

    # === Group 5: BR (always) and NOP (never) ===

    # Test 15: BR (always → taken)
    a.bcc_short(a.BR, 4)
    a.inc_reg('w', 11)
    a.inc_reg('w', 10)          # R10=15

    # Test 16: BNOP (never → NOT taken, falls through to INC R10)
    a.bcc_short(a.BNOP, 4)
    a.inc_reg('w', 10)          # R10=16 (success: branch was not taken)

    # Final: capture R10 (should be 16) into R12 for easy trace inspection
    a.mov_reg_reg('w', 10, 12)
    a.getpsw(13)

    # HALT
    a.halt()

    a.write('tests/phase4_test.bin')

    print("\nPhase 4 test: 14 Bcc conditions + BR + NOP")
    print(f"  Binary size: {len(a.code)} bytes")
    print(f"  Expected R10 = 16 (all tests passed)")
    print(f"  Expected R11 = 0 (no failures)")


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'phase3':
        build_phase3_test()
    elif len(sys.argv) > 1 and sys.argv[1] == 'phase4':
        build_phase4_test()
    else:
        build_phase2_test()
