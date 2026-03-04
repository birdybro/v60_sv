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

    def _encode_mod_reg_indirect(self, reg):
        """Encode mod for [Rn] (m=0, hi=3): mod = 0x60|reg."""
        return 0x60 | (reg & 0x1F)

    def _encode_mod_autoinc(self, reg):
        """Encode mod for [Rn]+ (m=1, hi=4): mod = 0x80|reg."""
        return 0x80 | (reg & 0x1F)

    def _encode_mod_autodec(self, reg):
        """Encode mod for -[Rn] (m=1, hi=5): mod = 0xA0|reg."""
        return 0xA0 | (reg & 0x1F)

    def _encode_mod_disp8(self, reg):
        """Encode mod for Disp8[Rn] (m=0, hi=0): mod = 0x00|reg."""
        return 0x00 | (reg & 0x1F)

    def _encode_mod_disp16(self, reg):
        """Encode mod for Disp16[Rn] (m=0, hi=1): mod = 0x20|reg."""
        return 0x20 | (reg & 0x1F)

    def _encode_mod_disp32(self, reg):
        """Encode mod for Disp32[Rn] (m=0, hi=2): mod = 0x40|reg."""
        return 0x40 | (reg & 0x1F)

    def _encode_mod_dispind8(self, reg):
        """Encode mod for DispInd8[Rn] (m=0, hi=4): mod = 0x80|reg."""
        return 0x80 | (reg & 0x1F)

    def _encode_mod_dispind16(self, reg):
        """Encode mod for DispInd16[Rn] (m=0, hi=5): mod = 0xA0|reg."""
        return 0xA0 | (reg & 0x1F)

    def _encode_mod_dispind32(self, reg):
        """Encode mod for DispInd32[Rn] (m=0, hi=6): mod = 0xC0|reg."""
        return 0xC0 | (reg & 0x1F)

    def _encode_mod_dbldisp8(self, reg):
        """Encode mod for DblDisp8[Rn] (m=1, hi=0): mod = 0x00|reg."""
        return 0x00 | (reg & 0x1F)

    def _encode_mod_dbldisp16(self, reg):
        """Encode mod for DblDisp16[Rn] (m=1, hi=1): mod = 0x20|reg."""
        return 0x20 | (reg & 0x1F)

    def _encode_mod_dbldisp32(self, reg):
        """Encode mod for DblDisp32[Rn] (m=1, hi=2): mod = 0x40|reg."""
        return 0x40 | (reg & 0x1F)

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
    # Format I: Register to memory (d=0: reg=source, mod=destination)
    # =========================================================================
    def _fmt1_reg_mem_rind(self, mnemonic, size, src_reg, addr_reg):
        """Rsrc, [Raddr] — register indirect destination (m=0, hi=3)."""
        opcode = self._FMT1_OPCODES[mnemonic][size]
        byte1 = (0 << 6) | (0 << 5) | (src_reg & 0x1F)  # m=0, d=0
        mod = self._encode_mod_reg_indirect(addr_reg)
        self.code.extend([opcode, byte1, mod])

    def _fmt1_reg_mem_disp8(self, mnemonic, size, src_reg, addr_reg, disp):
        """Rsrc, disp8[Raddr]."""
        opcode = self._FMT1_OPCODES[mnemonic][size]
        byte1 = (0 << 6) | (0 << 5) | (src_reg & 0x1F)  # m=0, d=0
        mod = self._encode_mod_disp8(addr_reg)
        self.code.extend([opcode, byte1, mod, disp & 0xFF])

    def _fmt1_reg_mem_disp16(self, mnemonic, size, src_reg, addr_reg, disp):
        """Rsrc, disp16[Raddr]."""
        opcode = self._FMT1_OPCODES[mnemonic][size]
        byte1 = (0 << 6) | (0 << 5) | (src_reg & 0x1F)
        mod = self._encode_mod_disp16(addr_reg)
        self.code.extend([opcode, byte1, mod])
        self.code.extend((disp & 0xFFFF).to_bytes(2, 'little'))

    def _fmt1_reg_mem_autodec(self, mnemonic, size, src_reg, addr_reg):
        """Rsrc, -[Raddr] — autodecrement destination (m=1, hi=5)."""
        opcode = self._FMT1_OPCODES[mnemonic][size]
        byte1 = (1 << 6) | (0 << 5) | (src_reg & 0x1F)  # m=1, d=0
        mod = self._encode_mod_autodec(addr_reg)
        self.code.extend([opcode, byte1, mod])

    # =========================================================================
    # Format I: Memory to register (d=1: reg=destination, mod=source)
    # =========================================================================
    def _fmt1_mem_rind_reg(self, mnemonic, size, addr_reg, dst_reg):
        """[Raddr], Rdst — register indirect source (m=0, hi=3)."""
        opcode = self._FMT1_OPCODES[mnemonic][size]
        byte1 = (0 << 6) | (1 << 5) | (dst_reg & 0x1F)  # m=0, d=1
        mod = self._encode_mod_reg_indirect(addr_reg)
        self.code.extend([opcode, byte1, mod])

    def _fmt1_mem_disp8_reg(self, mnemonic, size, addr_reg, disp, dst_reg):
        """disp8[Raddr], Rdst."""
        opcode = self._FMT1_OPCODES[mnemonic][size]
        byte1 = (0 << 6) | (1 << 5) | (dst_reg & 0x1F)  # m=0, d=1
        mod = self._encode_mod_disp8(addr_reg)
        self.code.extend([opcode, byte1, mod, disp & 0xFF])

    def _fmt1_mem_disp16_reg(self, mnemonic, size, addr_reg, disp, dst_reg):
        """disp16[Raddr], Rdst."""
        opcode = self._FMT1_OPCODES[mnemonic][size]
        byte1 = (0 << 6) | (1 << 5) | (dst_reg & 0x1F)
        mod = self._encode_mod_disp16(addr_reg)
        self.code.extend([opcode, byte1, mod])
        self.code.extend((disp & 0xFFFF).to_bytes(2, 'little'))

    def _fmt1_mem_autoinc_reg(self, mnemonic, size, addr_reg, dst_reg):
        """[Raddr]+, Rdst — autoincrement source (m=1, hi=4)."""
        opcode = self._FMT1_OPCODES[mnemonic][size]
        byte1 = (1 << 6) | (1 << 5) | (dst_reg & 0x1F)  # m=1, d=1
        mod = self._encode_mod_autoinc(addr_reg)
        self.code.extend([opcode, byte1, mod])

    # =========================================================================
    # Format I: Memory indirect to register (d=1: reg=destination, mod=source)
    # DispInd modes: m=0, hi=4/5/6
    # =========================================================================
    def _fmt1_mem_dispind8_reg(self, mnemonic, size, addr_reg, disp, dst_reg):
        """DispInd8[Raddr], Rdst — indirect via 8-bit displacement (m=0)."""
        opcode = self._FMT1_OPCODES[mnemonic][size]
        byte1 = (0 << 6) | (1 << 5) | (dst_reg & 0x1F)  # m=0, d=1
        mod = self._encode_mod_dispind8(addr_reg)
        self.code.extend([opcode, byte1, mod, disp & 0xFF])

    def _fmt1_mem_dispind16_reg(self, mnemonic, size, addr_reg, disp, dst_reg):
        """DispInd16[Raddr], Rdst — indirect via 16-bit displacement (m=0)."""
        opcode = self._FMT1_OPCODES[mnemonic][size]
        byte1 = (0 << 6) | (1 << 5) | (dst_reg & 0x1F)
        mod = self._encode_mod_dispind16(addr_reg)
        self.code.extend([opcode, byte1, mod])
        self.code.extend((disp & 0xFFFF).to_bytes(2, 'little'))

    # Format I: Register to memory indirect (d=0: reg=source, mod=destination)
    def _fmt1_reg_mem_dispind8(self, mnemonic, size, src_reg, addr_reg, disp):
        """Rsrc, DispInd8[Raddr] — store via indirect 8-bit displacement (m=0)."""
        opcode = self._FMT1_OPCODES[mnemonic][size]
        byte1 = (0 << 6) | (0 << 5) | (src_reg & 0x1F)  # m=0, d=0
        mod = self._encode_mod_dispind8(addr_reg)
        self.code.extend([opcode, byte1, mod, disp & 0xFF])

    # =========================================================================
    # Format I: Double displacement modes (m=1, hi=0/1/2)
    # =========================================================================
    def _fmt1_mem_dbldisp8_reg(self, mnemonic, size, addr_reg, disp1, disp2, dst_reg):
        """DblDisp8[Raddr], Rdst — double displacement 8-bit (m=1)."""
        opcode = self._FMT1_OPCODES[mnemonic][size]
        byte1 = (1 << 6) | (1 << 5) | (dst_reg & 0x1F)  # m=1, d=1
        mod = self._encode_mod_dbldisp8(addr_reg)
        self.code.extend([opcode, byte1, mod, disp1 & 0xFF, disp2 & 0xFF])

    def _fmt1_mem_dbldisp16_reg(self, mnemonic, size, addr_reg, disp1, disp2, dst_reg):
        """DblDisp16[Raddr], Rdst — double displacement 16-bit (m=1)."""
        opcode = self._FMT1_OPCODES[mnemonic][size]
        byte1 = (1 << 6) | (1 << 5) | (dst_reg & 0x1F)  # m=1, d=1
        mod = self._encode_mod_dbldisp16(addr_reg)
        self.code.extend([opcode, byte1, mod])
        self.code.extend((disp1 & 0xFFFF).to_bytes(2, 'little'))
        self.code.extend((disp2 & 0xFFFF).to_bytes(2, 'little'))

    # =========================================================================
    # Format I: Group7 indirect modes (m=0, mod[7:5]=7, mod[4:0]=24-30)
    # =========================================================================
    def _fmt1_mem_directaddr_deferred_reg(self, mnemonic, size, addr, dst_reg):
        """[addr], Rdst — direct address deferred (m=0, Group7 index 27)."""
        opcode = self._FMT1_OPCODES[mnemonic][size]
        byte1 = (0 << 6) | (1 << 5) | (dst_reg & 0x1F)  # m=0, d=1
        mod = 0xE0 | 27  # Group7, index 27 = 0xFB
        self.code.extend([opcode, byte1, mod])
        self.code.extend((addr & 0xFFFFFFFF).to_bytes(4, 'little'))

    # =========================================================================
    # Format I: Immediate to memory
    # =========================================================================
    def _fmt1_imm_mem_rind(self, mnemonic, size, imm_val, addr_reg):
        """#imm, [Raddr] — immediate to memory via register indirect.
        For CMP: d=0 would mean reg=src, but we want imm=src.
        Actually, for imm source + mem dest, we need d=0 (mod=dest), but
        source is immediate which means... V60 can't do imm→mem in one instruction
        for most ALU ops. CMP #imm, [Rn] uses d=1 with mod as source.
        Wait: CMP #imm, [Rn]: we need the mod field to be [Rn] as destination
        but CMP doesn't write. The encoding is:
        d=0: reg=source, mod=dest. But source needs to be immediate.
        For Format I, the reg field is always a register. To use imm source
        we need to go through a different path.
        Actually, CMP #imm, Rdst uses d=1 (reg=dest), m=0 (mod=immediate source).
        For CMP [Rn], Rdst: d=1, m=0, mod=[Rn]. That gives mem source.
        For CMP #imm, [Rn]: this isn't directly encodable in Format I since
        we can't have both imm and mem. We need to use a register intermediary.

        Let's skip this and use register-based CMP instead."""
        pass  # Not directly encodable

    # =========================================================================
    # Format III: Memory modes for INC/DEC
    # =========================================================================
    def inc_mem_rind(self, size, addr_reg):
        """INC.size [Raddr] — Format III with register indirect (m=0)."""
        base = {'b': 0xD8, 'h': 0xDA, 'w': 0xDC}[size]
        opcode = base | 0  # m=0 for register indirect
        mod = self._encode_mod_reg_indirect(addr_reg)
        self.code.extend([opcode, mod])

    def dec_mem_rind(self, size, addr_reg):
        """DEC.size [Raddr] — Format III with register indirect (m=0)."""
        base = {'b': 0xD0, 'h': 0xD2, 'w': 0xD4}[size]
        opcode = base | 0  # m=0
        mod = self._encode_mod_reg_indirect(addr_reg)
        self.code.extend([opcode, mod])

    def inc_mem_disp8(self, size, addr_reg, disp):
        """INC.size disp8[Raddr] — Format III with Disp8."""
        base = {'b': 0xD8, 'h': 0xDA, 'w': 0xDC}[size]
        opcode = base | 0  # m=0
        mod = self._encode_mod_disp8(addr_reg)
        self.code.extend([opcode, mod, disp & 0xFF])

    def inc_mem_dispind8(self, size, addr_reg, disp):
        """INC.size DispInd8[Raddr] — Format III with DispInd8 (m=0, hi=4)."""
        base = {'b': 0xD8, 'h': 0xDA, 'w': 0xDC}[size]
        opcode = base | 0  # m=0 for DispInd
        mod = self._encode_mod_dispind8(addr_reg)
        self.code.extend([opcode, mod, disp & 0xFF])

    # =========================================================================
    # MOV convenience methods (preserved from Phase 2)
    # =========================================================================
    def mov_reg_reg(self, size, src_reg, dst_reg):
        self._fmt1_reg_reg('mov', size, src_reg, dst_reg)

    def mov_imm_reg(self, size, imm_val, dst_reg):
        self._fmt1_imm_reg('mov', size, imm_val, dst_reg)

    def mov_immq_reg(self, size, quick_val, dst_reg):
        self._fmt1_immq_reg('mov', size, quick_val, dst_reg)

    # MOV memory modes
    def mov_reg_mem_rind(self, size, src_reg, addr_reg):
        self._fmt1_reg_mem_rind('mov', size, src_reg, addr_reg)

    def mov_mem_rind_reg(self, size, addr_reg, dst_reg):
        self._fmt1_mem_rind_reg('mov', size, addr_reg, dst_reg)

    def mov_reg_mem_disp8(self, size, src_reg, addr_reg, disp):
        self._fmt1_reg_mem_disp8('mov', size, src_reg, addr_reg, disp)

    def mov_mem_disp8_reg(self, size, addr_reg, disp, dst_reg):
        self._fmt1_mem_disp8_reg('mov', size, addr_reg, disp, dst_reg)

    def mov_mem_autoinc_reg(self, size, addr_reg, dst_reg):
        self._fmt1_mem_autoinc_reg('mov', size, addr_reg, dst_reg)

    def mov_reg_mem_autodec(self, size, src_reg, addr_reg):
        self._fmt1_reg_mem_autodec('mov', size, src_reg, addr_reg)

    # MOV indirect modes
    def mov_mem_dispind8_reg(self, size, addr_reg, disp, dst_reg):
        self._fmt1_mem_dispind8_reg('mov', size, addr_reg, disp, dst_reg)

    def mov_mem_dispind16_reg(self, size, addr_reg, disp, dst_reg):
        self._fmt1_mem_dispind16_reg('mov', size, addr_reg, disp, dst_reg)

    def mov_reg_mem_dispind8(self, size, src_reg, addr_reg, disp):
        self._fmt1_reg_mem_dispind8('mov', size, src_reg, addr_reg, disp)

    def mov_mem_dbldisp8_reg(self, size, addr_reg, disp1, disp2, dst_reg):
        self._fmt1_mem_dbldisp8_reg('mov', size, addr_reg, disp1, disp2, dst_reg)

    def mov_mem_dbldisp16_reg(self, size, addr_reg, disp1, disp2, dst_reg):
        self._fmt1_mem_dbldisp16_reg('mov', size, addr_reg, disp1, disp2, dst_reg)

    def mov_mem_directaddr_deferred_reg(self, size, addr, dst_reg):
        self._fmt1_mem_directaddr_deferred_reg('mov', size, addr, dst_reg)

    # ADD indirect modes
    def add_mem_dispind8_reg(self, size, addr_reg, disp, dst_reg):
        self._fmt1_mem_dispind8_reg('add', size, addr_reg, disp, dst_reg)

    # =========================================================================
    # ALU Format I convenience methods
    # =========================================================================
    def add_reg_reg(self, size, src_reg, dst_reg):
        self._fmt1_reg_reg('add', size, src_reg, dst_reg)

    def add_imm_reg(self, size, imm_val, dst_reg):
        self._fmt1_imm_reg('add', size, imm_val, dst_reg)

    def add_mem_rind_reg(self, size, addr_reg, dst_reg):
        self._fmt1_mem_rind_reg('add', size, addr_reg, dst_reg)

    def add_reg_mem_rind(self, size, src_reg, addr_reg):
        self._fmt1_reg_mem_rind('add', size, src_reg, addr_reg)

    def sub_reg_reg(self, size, src_reg, dst_reg):
        self._fmt1_reg_reg('sub', size, src_reg, dst_reg)

    def sub_imm_reg(self, size, imm_val, dst_reg):
        self._fmt1_imm_reg('sub', size, imm_val, dst_reg)

    def cmp_reg_reg(self, size, src_reg, dst_reg):
        self._fmt1_reg_reg('cmp', size, src_reg, dst_reg)

    def cmp_imm_reg(self, size, imm_val, dst_reg):
        self._fmt1_imm_reg('cmp', size, imm_val, dst_reg)

    def cmp_mem_rind_reg(self, size, addr_reg, dst_reg):
        """CMP [Raddr], Rdst — compare memory value against register."""
        self._fmt1_mem_rind_reg('cmp', size, addr_reg, dst_reg)

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

    # =========================================================================
    # Raw data embedding
    # =========================================================================
    def data_byte(self, val):
        self.code.append(val & 0xFF)

    def data_word(self, val):
        self.code.extend((val & 0xFFFF).to_bytes(2, 'little'))

    def data_dword(self, val):
        self.code.extend((val & 0xFFFFFFFF).to_bytes(4, 'little'))

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

    # === Group 5: BR (always) ===

    # Test 15: BR (always → taken)
    a.bcc_short(a.BR, 4)
    a.inc_reg('w', 11)
    a.inc_reg('w', 10)          # R10=15

    # Note: BNOP (condition 0xB / opcode 0x6B) is not a valid V60 opcode.
    # Real MAME marks it as opUNHANDLED. Removed from test.

    # Final: capture R10 (should be 15) into R12 for easy trace inspection
    a.mov_reg_reg('w', 10, 12)
    a.getpsw(13)

    # HALT
    a.halt()

    a.write('tests/phase4_test.bin')

    print("\nPhase 4 test: 14 Bcc conditions + BR")
    print(f"  Binary size: {len(a.code)} bytes")
    print(f"  Expected R10 = 15 (all tests passed)")
    print(f"  Expected R11 = 0 (no failures)")


def build_phase5a_test():
    """Build Phase 5A test: Memory addressing modes."""
    a = V60Asm()

    # =====================================================================
    # Setup: R0 = data area address (0x2000), R1 = test value
    # =====================================================================
    a.mov_imm_reg('w', 0x00002000, 0)   # R0 = 0x2000 (data area)
    a.mov_imm_reg('w', 0xDEADBEEF, 1)  # R1 = 0xDEADBEEF

    # =====================================================================
    # Test 1: MOV.W R1, [R0]  — store via register indirect
    # Expected: mem[0x2000] = 0xDEADBEEF
    # =====================================================================
    a.mov_reg_mem_rind('w', 1, 0)       # 3 bytes

    # =====================================================================
    # Test 2: MOV.W [R0], R2  — load via register indirect
    # Expected: R2 = 0xDEADBEEF
    # =====================================================================
    a.mov_mem_rind_reg('w', 0, 2)       # 3 bytes

    # =====================================================================
    # Test 3: MOV.W R1, 8[R0]  — store with Disp8
    # Expected: mem[0x2008] = 0xDEADBEEF
    # =====================================================================
    a.mov_reg_mem_disp8('w', 1, 0, 8)   # 4 bytes

    # =====================================================================
    # Test 4: MOV.W 8[R0], R3  — load with Disp8
    # Expected: R3 = 0xDEADBEEF
    # =====================================================================
    a.mov_mem_disp8_reg('w', 0, 8, 3)   # 4 bytes

    # =====================================================================
    # Test 5: ADD.W [R0], R4  — load + operate (mem src, reg dst)
    # R4 starts at 0. After: R4 = 0 + 0xDEADBEEF = 0xDEADBEEF
    # =====================================================================
    a.add_mem_rind_reg('w', 0, 4)       # 3 bytes

    # =====================================================================
    # Test 6: ADD.W R1, [R0]  — read-modify-write (reg src, mem dst)
    # mem[0x2000] was 0xDEADBEEF, add 0xDEADBEEF → 0xBD5B7DDE
    # =====================================================================
    a.add_reg_mem_rind('w', 1, 0)       # 3 bytes

    # =====================================================================
    # Test 7: CMP.W [R0], R4  — load, compare, flags only (no mem write)
    # mem[0x2000] = 0xBD5B7DDE, R4 = 0xDEADBEEF
    # R4 - [R0] = 0xDEADBEEF - 0xBD5B7DDE = 0x21524111 → Z=0, S=0
    # =====================================================================
    a.cmp_mem_rind_reg('w', 0, 4)       # 3 bytes
    a.getpsw(20)                         # R20 = PSW after CMP

    # =====================================================================
    # Test 8: MOV.W [R5]+, R6  — autoincrement load
    # Setup: R5 = 0x2000
    # Expected: R6 = mem[0x2000] = 0xBD5B7DDE (current value), R5 = 0x2004
    # =====================================================================
    a.mov_imm_reg('w', 0x00002000, 5)   # R5 = 0x2000
    a.mov_mem_autoinc_reg('w', 5, 6)    # 3 bytes

    # =====================================================================
    # Test 9: MOV.W R1, -[R5]  — autodecrement store
    # R5 = 0x2004 (from test 8). Pre-dec: R5 = 0x2000, then mem[0x2000] = R1
    # Expected: R5 = 0x2000, mem[0x2000] = 0xDEADBEEF
    # =====================================================================
    a.mov_reg_mem_autodec('w', 1, 5)    # 3 bytes

    # =====================================================================
    # Test 10: INC.W [R0]  — Format III read-modify-write on memory
    # mem[0x2000] = 0xDEADBEEF (from test 9). After: mem[0x2000] = 0xDEADBEF0
    # Load result back to verify
    # =====================================================================
    a.inc_mem_rind('w', 0)              # 2 bytes
    a.mov_mem_rind_reg('w', 0, 7)       # R7 = mem[0x2000] = 0xDEADBEF0

    # =====================================================================
    # Test 11: MOV.B R1, [R0]  — byte store
    # Stores low byte of R1 (0xEF) to mem[0x2000]
    # =====================================================================
    a.mov_reg_mem_rind('b', 1, 0)       # 3 bytes
    # Load back as byte to verify
    a.mov_mem_rind_reg('b', 0, 8)       # R8 = 0xEF

    # =====================================================================
    # Test 12: MOV.H R1, 4[R0]  — halfword store with displacement
    # Stores low halfword of R1 (0xBEEF) to mem[0x2004]
    # =====================================================================
    a.mov_reg_mem_disp8('h', 1, 0, 4)   # 4 bytes
    a.mov_mem_disp8_reg('h', 0, 4, 9)   # R9 = 0xBEEF

    # =====================================================================
    # Verify all results are correct by loading into high registers
    # =====================================================================
    a.mov_reg_reg('w', 2, 21)    # R21 = R2 (should be 0xDEADBEEF)
    a.mov_reg_reg('w', 5, 22)    # R22 = R5 (should be 0x2000)
    a.mov_reg_reg('w', 6, 23)    # R23 = R6 (should be 0xBD5B7DDE)
    a.mov_reg_reg('w', 7, 24)    # R24 = R7 (should be 0xDEADBEF0)

    # HALT
    a.halt()

    a.write('tests/phase5a_test.bin')

    print("\nPhase 5A test: Memory addressing modes")
    print(f"  Binary size: {len(a.code)} bytes")
    print(f"  Expected R2  = 0xDEADBEEF (load via [R0])")
    print(f"  Expected R3  = 0xDEADBEEF (load via 8[R0])")
    print(f"  Expected R4  = 0xDEADBEEF (ADD [R0], R4)")
    print(f"  Expected R5  = 0x00002000 (autodec restore)")
    print(f"  Expected R6  = 0xBD5B7DDE (autoinc load)")
    print(f"  Expected R7  = 0xDEADBEF0 (INC [R0])")
    print(f"  Expected R8  = 0x000000EF (byte load)")
    print(f"  Expected R9  = 0x0000BEEF (half load)")


def build_phase5b_test():
    """Build Phase 5B test: Indirect + double-displacement addressing modes."""
    a = V60Asm()

    # =====================================================================
    # Data area layout (base 0x1000, data at 0x2000):
    #   0x2000: pointer → 0x2100 (target data area)
    #   0x2004: pointer → 0x2200 (second target)
    #   0x2100: data = 0xCAFEBABE
    #   0x2200: data = 0x00000000 (write target)
    # =====================================================================

    # Setup: R0 = 0x2000 (pointer area base)
    a.mov_imm_reg('w', 0x00002000, 0)  # R0 = 0x2000

    # Store pointer at 0x2000 → 0x2100
    a.mov_imm_reg('w', 0x00002100, 1)  # R1 = 0x2100
    a.mov_reg_mem_rind('w', 1, 0)      # mem[0x2000] = 0x2100

    # Store data at 0x2100 = 0xCAFEBABE
    a.mov_imm_reg('w', 0xCAFEBABE, 2)  # R2 = 0xCAFEBABE
    a.mov_reg_mem_rind('w', 2, 1)      # mem[0x2100] = 0xCAFEBABE

    # Store pointer at 0x2004 → 0x2200
    a.mov_imm_reg('w', 0x00002200, 3)  # R3 = 0x2200
    a.mov_reg_mem_disp8('w', 3, 0, 4)  # mem[0x2004] = 0x2200

    # Clear destination registers
    a.mov_imm_reg('w', 0x00000000, 4)  # R4 = 0
    a.mov_imm_reg('w', 0x00000000, 5)  # R5 = 0
    a.mov_imm_reg('w', 0x00000000, 6)  # R6 = 0
    a.mov_imm_reg('w', 0x00000000, 7)  # R7 = 0
    a.mov_imm_reg('w', 0x00000000, 8)  # R8 = 0
    a.mov_imm_reg('w', 0x00000000, 9)  # R9 = 0
    a.mov_imm_reg('w', 0x00000000, 10) # R10 = 0

    # =====================================================================
    # Test 1: DispInd8 load — MOV.W DispInd8[R0], R4
    # Pointer at R0+0 = mem[0x2000] = 0x2100, data at [0x2100] = 0xCAFEBABE
    # Expected: R4 = 0xCAFEBABE
    # =====================================================================
    a.mov_mem_dispind8_reg('w', 0, 0, 4)

    # =====================================================================
    # Test 2: DispInd8 store — MOV.W R2, DispInd8[R0]
    # Pointer at R0+4 = mem[0x2004] = 0x2200, write R2 to [0x2200]
    # Expected: mem[0x2200] = 0xCAFEBABE
    # =====================================================================
    a.mov_reg_mem_dispind8('w', 2, 0, 4)

    # Verify: load back from 0x2200
    a.mov_mem_rind_reg('w', 3, 5)      # R5 = mem[R3=0x2200] = 0xCAFEBABE

    # =====================================================================
    # Test 3: DispInd16 load — MOV.W DispInd16[R0], R6
    # Pointer at R0+0 = mem[0x2000] = 0x2100, data at [0x2100] = 0xCAFEBABE
    # Expected: R6 = 0xCAFEBABE
    # =====================================================================
    a.mov_mem_dispind16_reg('w', 0, 0, 6)

    # =====================================================================
    # Test 4: DblDisp8 load — MOV.W DblDisp8(0,8)[R0], R7
    # Pointer at R0+0 = mem[0x2000] = 0x2100, data at [0x2100+8]
    # First store known value at 0x2108
    # =====================================================================
    a.mov_imm_reg('w', 0x12345678, 11) # R11 = 0x12345678
    a.mov_imm_reg('w', 0x00002108, 12) # R12 = 0x2108
    a.mov_reg_mem_rind('w', 11, 12)    # mem[0x2108] = 0x12345678
    a.mov_mem_dbldisp8_reg('w', 0, 0, 8, 7)  # R7 = mem[mem[R0+0]+8] = mem[0x2108]
    # Expected: R7 = 0x12345678

    # =====================================================================
    # Test 5: DblDisp16 load — MOV.W DblDisp16(0,8)[R0], R8
    # Same as test 4 but with 16-bit displacements
    # Expected: R8 = 0x12345678
    # =====================================================================
    a.mov_mem_dbldisp16_reg('w', 0, 0, 8, 8)

    # =====================================================================
    # Test 6: DirectAddrDeferred load — MOV.W [0x2000], R9
    # Pointer at abs addr 0x2000 = 0x2100, data at [0x2100] = 0xCAFEBABE
    # Expected: R9 = 0xCAFEBABE
    # =====================================================================
    a.mov_mem_directaddr_deferred_reg('w', 0x00002000, 9)

    # =====================================================================
    # Test 7: ADD with indirect source — ADD.W DispInd8[R0], R10
    # R10 = 0, pointer at R0+0 → 0x2100, data at [0x2100] = 0xCAFEBABE
    # Expected: R10 = 0 + 0xCAFEBABE = 0xCAFEBABE, flags updated
    # =====================================================================
    a.add_mem_dispind8_reg('w', 0, 0, 10)
    a.getpsw(20)   # R20 = PSW after ADD (S=1)

    # =====================================================================
    # Test 8: INC via Format III indirect — INC.W DispInd8[R0]
    # Pointer at R0+0 → 0x2100, data at [0x2100] = 0xCAFEBABE
    # After: mem[0x2100] = 0xCAFEBABF
    # =====================================================================
    a.inc_mem_dispind8('w', 0, 0)

    # Verify: load back from 0x2100
    a.mov_mem_rind_reg('w', 1, 13)     # R13 = mem[R1=0x2100] = 0xCAFEBABF

    # =====================================================================
    # Capture final results
    # =====================================================================
    a.mov_reg_reg('w', 4, 21)    # R21 = R4 (should be 0xCAFEBABE)
    a.mov_reg_reg('w', 5, 22)    # R22 = R5 (should be 0xCAFEBABE)
    a.mov_reg_reg('w', 6, 23)    # R23 = R6 (should be 0xCAFEBABE)
    a.mov_reg_reg('w', 7, 24)    # R24 = R7 (should be 0x12345678)
    a.mov_reg_reg('w', 8, 25)    # R25 = R8 (should be 0x12345678)
    a.mov_reg_reg('w', 9, 26)    # R26 = R9 (should be 0xCAFEBABE)
    a.mov_reg_reg('w', 10, 27)   # R27 = R10 (should be 0xCAFEBABE)

    # HALT
    a.halt()

    a.write('tests/phase5b_test.bin')

    print("\nPhase 5B test: Indirect + double-displacement addressing modes")
    print(f"  Binary size: {len(a.code)} bytes")
    print(f"  Expected R4  = 0xCAFEBABE (DispInd8 load)")
    print(f"  Expected R5  = 0xCAFEBABE (DispInd8 store verify)")
    print(f"  Expected R6  = 0xCAFEBABE (DispInd16 load)")
    print(f"  Expected R7  = 0x12345678 (DblDisp8 load)")
    print(f"  Expected R8  = 0x12345678 (DblDisp16 load)")
    print(f"  Expected R9  = 0xCAFEBABE (DirectAddrDeferred load)")
    print(f"  Expected R10 = 0xCAFEBABE (ADD via indirect)")
    print(f"  Expected R13 = 0xCAFEBABF (INC via indirect)")


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'phase3':
        build_phase3_test()
    elif len(sys.argv) > 1 and sys.argv[1] == 'phase4':
        build_phase4_test()
    elif len(sys.argv) > 1 and sys.argv[1] == 'phase5a':
        build_phase5a_test()
    elif len(sys.argv) > 1 and sys.argv[1] == 'phase5b':
        build_phase5b_test()
    else:
        build_phase2_test()
