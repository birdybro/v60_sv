// v60_string.cpp — DPI-C implementation of V60 string/bitfield/decimal operations
// Opcodes 0x58 (byte string), 0x5A (half string), 0x5B (bit string),
// 0x5D (bitfield), 0x59 (decimal)
// Matches MAME op7a.hxx behavior exactly.

#include <cstdint>
#include <cstdio>
#include <cstring>
#include "svdpi.h"

// DPI exports from testbench
extern "C" {
    extern int  get_gpr(int idx);
}

// Shadow memory — synced with SV memory via DPI at init and after string ops
static constexpr int MEM_SIZE = 1 << 20;
static uint8_t shadow_mem[MEM_SIZE];
static bool shadow_valid = false;

// Track memory writes from string operations to replay into SV memory
struct MemWrite { uint32_t addr; uint8_t data; };
static MemWrite mem_writes[65536];  // buffer for deferred writes
static int num_mem_writes = 0;

// Scope handles
static svScope scope_top = nullptr;
static svScope scope_mem = nullptr;

// DPI exports
extern "C" {
    extern int  mem_read_byte(int addr);
    extern void mem_write_byte(int addr, int data);
}

// =========================================================================
// Memory access helpers — use shadow memory for reads, buffer writes
// =========================================================================
static uint8_t rb(uint32_t addr) {
    uint32_t a = addr & (MEM_SIZE - 1);
    if (!shadow_valid) {
        svSetScope(scope_mem);
        return (uint8_t)mem_read_byte((int)a);
    }
    return shadow_mem[a];
}

static uint16_t rh(uint32_t addr) {
    return (uint16_t)rb(addr) | ((uint16_t)rb(addr + 1) << 8);
}

static uint32_t rw(uint32_t addr) {
    return (uint32_t)rb(addr) | ((uint32_t)rb(addr + 1) << 8) |
           ((uint32_t)rb(addr + 2) << 16) | ((uint32_t)rb(addr + 3) << 24);
}

static void wb(uint32_t addr, uint8_t data) {
    uint32_t a = addr & (MEM_SIZE - 1);
    shadow_mem[a] = data;
    if (num_mem_writes < 65536) {
        mem_writes[num_mem_writes++] = {a, data};
    }
}

static void wh(uint32_t addr, uint16_t data) {
    wb(addr, data & 0xFF);
    wb(addr + 1, (data >> 8) & 0xFF);
}

static void ww(uint32_t addr, uint32_t data) {
    wb(addr, data & 0xFF);
    wb(addr + 1, (data >> 8) & 0xFF);
    wb(addr + 2, (data >> 16) & 0xFF);
    wb(addr + 3, (data >> 24) & 0xFF);
}

// Register read helper
static uint32_t gpr(int idx) {
    svSetScope(scope_top);
    return (uint32_t)get_gpr(idx);
}

// Convenience: read memory value by dimension (0=byte, 1=half, 2=word)
static uint32_t read_dim(uint32_t addr, int dim) {
    switch (dim) {
        case 0: return rb(addr);
        case 1: return rh(addr);
        case 2: return rw(addr);
        default: return rw(addr);
    }
}

static void write_dim(uint32_t addr, uint32_t data, int dim) {
    switch (dim) {
        case 0: wb(addr, (uint8_t)data); break;
        case 1: wh(addr, (uint16_t)data); break;
        case 2: ww(addr, data); break;
    }
}

static int dim_bytes(int dim) {
    switch (dim) { case 0: return 1; case 1: return 2; default: return 4; }
}

// SETREG8/SETREG16 — sub-word register merge (matches MAME)
static uint32_t setreg8(uint32_t old_val, uint8_t new_byte) {
    return (old_val & 0xFFFFFF00) | new_byte;
}

static uint32_t setreg16(uint32_t old_val, uint16_t new_half) {
    return (old_val & 0xFFFF0000) | new_half;
}

// =========================================================================
// Addressing Mode Decoder (based on MAME am1.hxx / am2.hxx / am3.hxx)
// =========================================================================

struct AMResult {
    uint32_t value;       // data value (ReadAM) or address/reg_idx (ReadAMAddress)
    int      flag;        // 1=register, 0=memory (ReadAMAddress only)
    int      length;      // bytes consumed
    int      bam_offset;  // bit offset for bit operations
};

// ReadAM: read data value
static AMResult decode_read_am(uint32_t base, uint32_t pc, int m_bit, int dim) {
    AMResult r = {0, 0, 1, 0};
    uint8_t mod = rb(base);
    int grp = (mod >> 5) & 7;
    int ri  = mod & 0x1F;

    if (m_bit) {
        switch (grp) {
            case 0: { // DblDisp8
                int8_t d1 = (int8_t)rb(base + 1);
                uint32_t ptr = rw(gpr(ri) + d1);
                int8_t d2 = (int8_t)rb(base + 2);
                r.value = read_dim(ptr + d2, dim); r.length = 3; return r;
            }
            case 1: { // DblDisp16
                int16_t d1 = (int16_t)rh(base + 1);
                uint32_t ptr = rw(gpr(ri) + d1);
                int16_t d2 = (int16_t)rh(base + 3);
                r.value = read_dim(ptr + d2, dim); r.length = 5; return r;
            }
            case 2: { // DblDisp32
                int32_t d1 = (int32_t)rw(base + 1);
                uint32_t ptr = rw(gpr(ri) + d1);
                int32_t d2 = (int32_t)rw(base + 5);
                r.value = read_dim(ptr + d2, dim); r.length = 9; return r;
            }
            case 3: { // Register
                uint32_t v = gpr(ri);
                switch (dim) {
                    case 0: r.value = v & 0xFF; break;
                    case 1: r.value = v & 0xFFFF; break;
                    default: r.value = v; break;
                }
                r.flag = 1; r.length = 1; return r;
            }
            case 4: { // AutoInc [Rn]+
                r.value = read_dim(gpr(ri), dim); r.length = 1; return r;
            }
            case 5: { // AutoDec -[Rn]
                r.value = read_dim(gpr(ri) - dim_bytes(dim), dim); r.length = 1; return r;
            }
            case 6: { // Group6 — indexed modes
                uint8_t mod2 = rb(base + 1);
                int grp2 = (mod2 >> 5) & 7;
                int ri2 = mod2 & 0x1F;
                switch (grp2) {
                    case 0: { // Disp8[Rn][Rx]
                        int8_t d = (int8_t)rb(base + 2);
                        r.value = read_dim(gpr(ri2) + d + gpr(ri) * dim_bytes(dim), dim);
                        r.length = 3; return r;
                    }
                    case 1: { // Disp16[Rn][Rx]
                        int16_t d = (int16_t)rh(base + 2);
                        r.value = read_dim(gpr(ri2) + d + gpr(ri) * dim_bytes(dim), dim);
                        r.length = 4; return r;
                    }
                    case 2: { // Disp32[Rn][Rx]
                        int32_t d = (int32_t)rw(base + 2);
                        r.value = read_dim(gpr(ri2) + d + gpr(ri) * dim_bytes(dim), dim);
                        r.length = 6; return r;
                    }
                    default: break;
                }
                // Group7a — PC-relative indexed, direct indexed
                if (mod2 & 0x10) {
                    int sub = mod2 & 0x0F;
                    switch (sub) {
                        case 0: { // PCDisp8[Rx]
                            int8_t d = (int8_t)rb(base + 2);
                            r.value = read_dim(pc + d + gpr(ri) * dim_bytes(dim), dim);
                            r.length = 3; return r;
                        }
                        case 1: { // PCDisp16[Rx]
                            int16_t d = (int16_t)rh(base + 2);
                            r.value = read_dim(pc + d + gpr(ri) * dim_bytes(dim), dim);
                            r.length = 4; return r;
                        }
                        case 2: { // PCDisp32[Rx]
                            int32_t d = (int32_t)rw(base + 2);
                            r.value = read_dim(pc + d + gpr(ri) * dim_bytes(dim), dim);
                            r.length = 6; return r;
                        }
                        case 3: { // DirectAddr[Rx]
                            uint32_t addr = rw(base + 2);
                            r.value = read_dim(addr + gpr(ri) * dim_bytes(dim), dim);
                            r.length = 6; return r;
                        }
                        default: break;
                    }
                }
                fprintf(stderr, "v60_string: unimpl ReadAM m=1 Group6 mod2=0x%02x\n", mod2);
                r.length = 2; return r;
            }
            default: break;
        }
    } else {
        switch (grp) {
            case 0: { // Disp8[Rn]
                int8_t d = (int8_t)rb(base + 1);
                r.value = read_dim(gpr(ri) + d, dim); r.length = 2; return r;
            }
            case 1: { // Disp16[Rn]
                int16_t d = (int16_t)rh(base + 1);
                r.value = read_dim(gpr(ri) + d, dim); r.length = 3; return r;
            }
            case 2: { // Disp32[Rn]
                int32_t d = (int32_t)rw(base + 1);
                r.value = read_dim(gpr(ri) + d, dim); r.length = 5; return r;
            }
            case 3: { // RegIndirect [Rn]
                r.value = read_dim(gpr(ri), dim); r.length = 1; return r;
            }
            case 4: { // DispInd8
                int8_t d = (int8_t)rb(base + 1);
                uint32_t ptr = rw(gpr(ri) + d);
                r.value = read_dim(ptr, dim); r.length = 2; return r;
            }
            case 5: { // DispInd16
                int16_t d = (int16_t)rh(base + 1);
                uint32_t ptr = rw(gpr(ri) + d);
                r.value = read_dim(ptr, dim); r.length = 3; return r;
            }
            case 6: { // DispInd32
                int32_t d = (int32_t)rw(base + 1);
                uint32_t ptr = rw(gpr(ri) + d);
                r.value = read_dim(ptr, dim); r.length = 5; return r;
            }
            case 7: { // Group7
                int sub = mod & 0x1F;
                if (sub < 16) {
                    // ImmediateQuick
                    r.value = sub; r.flag = 1; r.length = 1; return r;
                }
                switch (sub) {
                    case 16: { int8_t d = (int8_t)rb(base + 1);
                        r.value = read_dim(pc + d, dim); r.length = 2; return r; }
                    case 17: { int16_t d = (int16_t)rh(base + 1);
                        r.value = read_dim(pc + d, dim); r.length = 3; return r; }
                    case 18: { int32_t d = (int32_t)rw(base + 1);
                        r.value = read_dim(pc + d, dim); r.length = 5; return r; }
                    case 19: { uint32_t a = rw(base + 1);
                        r.value = read_dim(a, dim); r.length = 5; return r; }
                    case 20: { // Immediate
                        switch (dim) {
                            case 0: r.value = rb(base + 1); r.length = 2; break;
                            case 1: r.value = rh(base + 1); r.length = 3; break;
                            default: r.value = rw(base + 1); r.length = 5; break;
                        }
                        r.flag = 1; return r;
                    }
                    case 24: { // PCDispInd8
                        int8_t d = (int8_t)rb(base + 1);
                        uint32_t ptr = rw(pc + d);
                        r.value = read_dim(ptr, dim); r.length = 2; return r;
                    }
                    case 25: { // PCDispInd16
                        int16_t d = (int16_t)rh(base + 1);
                        uint32_t ptr = rw(pc + d);
                        r.value = read_dim(ptr, dim); r.length = 3; return r;
                    }
                    case 26: { // PCDispInd32
                        int32_t d = (int32_t)rw(base + 1);
                        uint32_t ptr = rw(pc + d);
                        r.value = read_dim(ptr, dim); r.length = 5; return r;
                    }
                    case 27: { // DirectAddrDeferred
                        uint32_t a = rw(base + 1);
                        uint32_t ptr = rw(a);
                        r.value = read_dim(ptr, dim); r.length = 5; return r;
                    }
                    default: break;
                }
                break;
            }
        }
    }

    fprintf(stderr, "v60_string: unimpl ReadAM m=%d mod=0x%02x at 0x%08x\n", m_bit?1:0, mod, base);
    return r;
}

// ReadAMAddress: read effective address (flag=1 if register, value=reg_idx)
static AMResult decode_read_am_address(uint32_t base, uint32_t pc, int m_bit, int dim) {
    AMResult r = {0, 0, 1, 0};
    uint8_t mod = rb(base);
    int grp = (mod >> 5) & 7;
    int ri  = mod & 0x1F;

    if (m_bit) {
        switch (grp) {
            case 0: { int8_t d = (int8_t)rb(base+1);
                r.value = rw(gpr(ri) + d); int8_t d2 = (int8_t)rb(base+2);
                r.value += d2; r.length = 3; return r; }
            case 1: { int16_t d = (int16_t)rh(base+1);
                r.value = rw(gpr(ri) + d); int16_t d2 = (int16_t)rh(base+3);
                r.value += d2; r.length = 5; return r; }
            case 2: { int32_t d = (int32_t)rw(base+1);
                r.value = rw(gpr(ri) + d); int32_t d2 = (int32_t)rw(base+5);
                r.value += d2; r.length = 9; return r; }
            case 3: { r.value = ri; r.flag = 1; r.length = 1; return r; }
            case 4: { r.value = gpr(ri); r.length = 1; return r; }
            case 5: { r.value = gpr(ri) - dim_bytes(dim); r.length = 1; return r; }
            case 6: {
                uint8_t mod2 = rb(base + 1);
                int grp2 = (mod2 >> 5) & 7;
                int ri2 = mod2 & 0x1F;
                switch (grp2) {
                    case 0: { int8_t d = (int8_t)rb(base+2);
                        r.value = gpr(ri2) + d + gpr(ri) * dim_bytes(dim);
                        r.length = 3; return r; }
                    case 1: { int16_t d = (int16_t)rh(base+2);
                        r.value = gpr(ri2) + d + gpr(ri) * dim_bytes(dim);
                        r.length = 4; return r; }
                    case 2: { int32_t d = (int32_t)rw(base+2);
                        r.value = gpr(ri2) + d + gpr(ri) * dim_bytes(dim);
                        r.length = 6; return r; }
                    default: break;
                }
                if (mod2 & 0x10) {
                    int sub = mod2 & 0x0F;
                    switch (sub) {
                        case 0: { int8_t d = (int8_t)rb(base+2);
                            r.value = pc + d + gpr(ri) * dim_bytes(dim);
                            r.length = 3; return r; }
                        case 1: { int16_t d = (int16_t)rh(base+2);
                            r.value = pc + d + gpr(ri) * dim_bytes(dim);
                            r.length = 4; return r; }
                        case 2: { int32_t d = (int32_t)rw(base+2);
                            r.value = pc + d + gpr(ri) * dim_bytes(dim);
                            r.length = 6; return r; }
                        case 3: { uint32_t a = rw(base+2);
                            r.value = a + gpr(ri) * dim_bytes(dim);
                            r.length = 6; return r; }
                        default: break;
                    }
                }
                fprintf(stderr, "v60_string: unimpl AMAddr m=1 G6 mod2=0x%02x\n", mod2);
                r.length = 2; return r;
            }
            default: break;
        }
    } else {
        switch (grp) {
            case 0: { int8_t d = (int8_t)rb(base+1);
                r.value = gpr(ri) + d; r.length = 2; return r; }
            case 1: { int16_t d = (int16_t)rh(base+1);
                r.value = gpr(ri) + d; r.length = 3; return r; }
            case 2: { int32_t d = (int32_t)rw(base+1);
                r.value = gpr(ri) + d; r.length = 5; return r; }
            case 3: { r.value = gpr(ri); r.length = 1; return r; }
            case 4: { int8_t d = (int8_t)rb(base+1);
                r.value = rw(gpr(ri) + d); r.length = 2; return r; }
            case 5: { int16_t d = (int16_t)rh(base+1);
                r.value = rw(gpr(ri) + d); r.length = 3; return r; }
            case 6: { int32_t d = (int32_t)rw(base+1);
                r.value = rw(gpr(ri) + d); r.length = 5; return r; }
            case 7: {
                int sub = mod & 0x1F;
                switch (sub) {
                    case 16: { int8_t d = (int8_t)rb(base+1);
                        r.value = pc + d; r.length = 2; return r; }
                    case 17: { int16_t d = (int16_t)rh(base+1);
                        r.value = pc + d; r.length = 3; return r; }
                    case 18: { int32_t d = (int32_t)rw(base+1);
                        r.value = pc + d; r.length = 5; return r; }
                    case 19: { r.value = rw(base+1); r.length = 5; return r; }
                    case 24: { int8_t d = (int8_t)rb(base+1);
                        r.value = rw(pc + d); r.length = 2; return r; }
                    case 25: { int16_t d = (int16_t)rh(base+1);
                        r.value = rw(pc + d); r.length = 3; return r; }
                    case 26: { int32_t d = (int32_t)rw(base+1);
                        r.value = rw(pc + d); r.length = 5; return r; }
                    case 27: { uint32_t a = rw(base+1);
                        r.value = rw(a); r.length = 5; return r; }
                    default: break;
                }
                break;
            }
        }
    }

    fprintf(stderr, "v60_string: unimpl AMAddr m=%d mod=0x%02x at 0x%08x\n", m_bit?1:0, mod, base);
    return r;
}

// BitReadAM: read 32-bit word for bit operations + bam_offset
static AMResult decode_bit_read_am(uint32_t base, uint32_t pc, int m_bit, int dim) {
    AMResult r = {0, 0, 1, 0};
    uint8_t mod = rb(base);
    int grp = (mod >> 5) & 7;
    int ri  = mod & 0x1F;

    if (m_bit) {
        // BAM table m=1: DblDisp, Error, AutoInc, AutoDec, Group6, Error
        switch (grp) {
            case 0: { // DblDisp8
                int8_t d1 = (int8_t)rb(base + 1);
                uint32_t addr = rw(gpr(ri) + d1);
                r.bam_offset = 0;
                r.value = rw(addr); r.length = 2; return r;
            }
            case 1: { // DblDisp16
                int16_t d1 = (int16_t)rh(base + 1);
                uint32_t addr = rw(gpr(ri) + d1);
                r.bam_offset = 0;
                r.value = rw(addr); r.length = 3; return r;
            }
            case 2: { // DblDisp32
                int32_t d1 = (int32_t)rw(base + 1);
                uint32_t addr = rw(gpr(ri) + d1);
                r.bam_offset = 0;
                r.value = rw(addr); r.length = 5; return r;
            }
            // group 3: Error (register not valid for BitReadAM m=1)
            case 4: { // AutoInc
                r.bam_offset = 0;
                r.value = rw(gpr(ri)); r.length = 1; return r;
            }
            case 5: { // AutoDec
                r.bam_offset = 0;
                r.value = rw(gpr(ri)); r.length = 1; return r;
            }
            default: break;
        }
    } else {
        // BAM table m=0: Disp8/16/32, RegIndirect, DispInd8/16/32, Group7
        switch (grp) {
            case 0: { // Disp8[Rn]
                int8_t d = (int8_t)rb(base + 1);
                uint32_t addr = gpr(ri) + d;
                r.bam_offset = 0;
                r.value = rw(addr); r.length = 2; return r;
            }
            case 1: { // Disp16[Rn]
                int16_t d = (int16_t)rh(base + 1);
                uint32_t addr = gpr(ri) + d;
                r.bam_offset = 0;
                r.value = rw(addr); r.length = 3; return r;
            }
            case 2: { // Disp32[Rn]
                int32_t d = (int32_t)rw(base + 1);
                uint32_t addr = gpr(ri) + d;
                r.bam_offset = 0;
                r.value = rw(addr); r.length = 5; return r;
            }
            case 3: { // RegIndirect [Rn]
                r.bam_offset = 0;
                r.value = rw(gpr(ri)); r.length = 1; return r;
            }
            case 7: {
                int sub = mod & 0x1F;
                switch (sub) {
                    case 19: { uint32_t a = rw(base+1);
                        r.bam_offset = 0;
                        r.value = rw(a); r.length = 5; return r; }
                    case 20: { // Immediate
                        r.bam_offset = 0;
                        r.value = rw(base+1); r.flag = 1; r.length = 5; return r; }
                    default: break;
                }
                break;
            }
            default: break;
        }
    }

    fprintf(stderr, "v60_string: unimpl BitReadAM m=%d mod=0x%02x\n", m_bit?1:0, mod);
    return r;
}

// BitReadAMAddress: read address for bit string operations
static AMResult decode_bit_read_am_address(uint32_t base, uint32_t pc, int m_bit, int dim) {
    AMResult r = {0, 0, 1, 0};
    uint8_t mod = rb(base);
    int grp = (mod >> 5) & 7;
    int ri  = mod & 0x1F;

    if (m_bit) {
        switch (grp) {
            case 3: { r.value = ri; r.flag = 1; r.length = 1; return r; }
            case 4: { r.value = gpr(ri); r.length = 1; return r; }
            default: break;
        }
    } else {
        switch (grp) {
            case 0: { int8_t d = (int8_t)rb(base+1);
                r.value = gpr(ri) + d; r.length = 2; return r; }
            case 1: { int16_t d = (int16_t)rh(base+1);
                r.value = gpr(ri) + d; r.length = 3; return r; }
            case 2: { int32_t d = (int32_t)rw(base+1);
                r.value = gpr(ri) + d; r.length = 5; return r; }
            case 3: { r.value = gpr(ri); r.length = 1; return r; }
            case 7: {
                int sub = mod & 0x1F;
                switch (sub) {
                    case 19: { r.value = rw(base+1); r.length = 5; return r; }
                    default: break;
                }
                break;
            }
            default: break;
        }
    }

    fprintf(stderr, "v60_string: unimpl BitReadAMAddr m=%d mod=0x%02x\n", m_bit?1:0, mod);
    return r;
}

// =========================================================================
// Format 7A/7B/7C Decode Helpers (matching MAME op7a.hxx)
// =========================================================================

struct OpState {
    uint32_t op1, op2;           // operand values/addresses
    int      flag1, flag2;       // 1=register, 0=memory
    uint32_t lenop1, lenop2;     // lengths (from length bytes)
    int      amlength1, amlength2;
    int      bamoffset, bamoffset1, bamoffset2;
    uint32_t modwritevalw;       // write value (word)
    // PSW flag results
    int fz, fs, fov, fcy;
    // Register writes (up to 3)
    int num_wr;
    int wr_idx[3];
    uint32_t wr_val[3];
};

static void add_wr(OpState& s, int idx, uint32_t val) {
    if (s.num_wr < 3) {
        s.wr_idx[s.num_wr] = idx;
        s.wr_val[s.num_wr] = val;
        s.num_wr++;
    }
}

// Decode length byte: if bit 7 set, use register value; else literal
static uint32_t decode_len_byte(uint32_t addr) {
    uint8_t b = rb(addr);
    if (b & 0x80)
        return gpr(b & 0x1F);
    else
        return b;
}

// F7aDecodeOperands: two addresses + two lengths
static int f7a_decode(uint32_t pc, uint8_t subop, int dim1, int dim2, OpState& s) {
    int m1 = subop & 0x40;
    int m2 = subop & 0x20;

    AMResult am1 = decode_read_am_address(pc + 2, pc, m1 ? 1 : 0, dim1);
    s.flag1 = am1.flag;
    s.op1 = am1.value;
    s.amlength1 = am1.length;

    s.lenop1 = decode_len_byte(pc + 2 + s.amlength1);

    AMResult am2 = decode_read_am_address(pc + 3 + s.amlength1, pc, m2 ? 1 : 0, dim2);
    s.flag2 = am2.flag;
    s.op2 = am2.value;
    s.amlength2 = am2.length;

    s.lenop2 = decode_len_byte(pc + 3 + s.amlength1 + s.amlength2);

    return s.amlength1 + s.amlength2 + 4;
}

// F7bDecodeFirstOperand
static void f7b_decode_first(uint32_t pc, uint8_t subop, int dim1, OpState& s,
                              bool use_bit_am, bool use_bit_addr) {
    int m1 = subop & 0x40;

    AMResult am1;
    if (use_bit_addr)
        am1 = decode_bit_read_am_address(pc + 2, pc, m1 ? 1 : 0, dim1);
    else if (use_bit_am)
        am1 = decode_bit_read_am(pc + 2, pc, m1 ? 1 : 0, dim1);
    else
        am1 = decode_read_am_address(pc + 2, pc, m1 ? 1 : 0, dim1);
    s.flag1 = am1.flag;
    s.op1 = am1.value;
    s.amlength1 = am1.length;
    s.bamoffset = am1.bam_offset;
    s.bamoffset1 = am1.bam_offset;

    s.lenop1 = decode_len_byte(pc + 2 + s.amlength1);
}

// F7bDecodeOperands: first operand + ext + second operand
static int f7b_decode(uint32_t pc, uint8_t subop, int dim1, int dim2, OpState& s,
                       bool bit_am1 = false, bool bit_addr1 = false,
                       bool bit_am2 = false, bool bit_addr2 = false,
                       bool read_val2 = false) {
    f7b_decode_first(pc, subop, dim1, s, bit_am1, bit_addr1);

    int m2 = subop & 0x20;
    uint32_t am2_base = pc + 3 + s.amlength1;

    AMResult am2;
    if (bit_addr2)
        am2 = decode_bit_read_am_address(am2_base, pc, m2 ? 1 : 0, dim2);
    else if (bit_am2)
        am2 = decode_bit_read_am(am2_base, pc, m2 ? 1 : 0, dim2);
    else if (read_val2)
        am2 = decode_read_am(am2_base, pc, m2 ? 1 : 0, dim2);
    else
        am2 = decode_read_am_address(am2_base, pc, m2 ? 1 : 0, dim2);
    s.flag2 = am2.flag;
    s.op2 = am2.value;
    s.amlength2 = am2.length;
    s.bamoffset2 = am2.bam_offset;

    return s.amlength1 + s.amlength2 + 3;
}

// F7cDecodeOperands: AM1 value + AM2 address + ext byte
static int f7c_decode(uint32_t pc, uint8_t subop, int dim1, int dim2, OpState& s,
                       bool bit_addr2 = false) {
    int m1 = subop & 0x40;
    int m2 = subop & 0x20;

    AMResult am1 = decode_read_am(pc + 2, pc, m1 ? 1 : 0, dim1);
    s.flag1 = am1.flag;
    s.op1 = am1.value;
    s.amlength1 = am1.length;

    uint32_t am2_base = pc + 2 + s.amlength1;
    AMResult am2;
    if (bit_addr2)
        am2 = decode_bit_read_am_address(am2_base, pc, m2 ? 1 : 0, dim2);
    else
        am2 = decode_read_am_address(am2_base, pc, m2 ? 1 : 0, dim2);
    s.flag2 = am2.flag;
    s.op2 = am2.value;
    s.amlength2 = am2.length;
    s.bamoffset2 = am2.bam_offset;

    s.lenop1 = decode_len_byte(pc + 2 + s.amlength1 + s.amlength2);

    return s.amlength1 + s.amlength2 + 3;
}

// =========================================================================
// String Operations (0x58 = byte, 0x5A = half)
// =========================================================================

// CMPC: compare strings
static int op_cmpstr_b(uint32_t pc, uint8_t subop, OpState& s, int bFill, int bStop) {
    int ilen = f7a_decode(pc, subop, 0, 0, s);
    uint32_t dest = (s.lenop1 < s.lenop2) ? s.lenop1 : s.lenop2;
    uint32_t i;

    // Filling
    if (bFill) {
        uint8_t fill = (uint8_t)gpr(26);
        if (s.lenop1 < s.lenop2)
            for (i = s.lenop1; i < s.lenop2; i++) wb(s.op1 + i, fill);
        else if (s.lenop2 < s.lenop1)
            for (i = s.lenop2; i < s.lenop1; i++) wb(s.op2 + i, fill);
    }

    s.fz = 0; s.fs = 0;
    if (bStop) s.fcy = 1;

    for (i = 0; i < dest; i++) {
        uint8_t c1 = rb(s.op1 + i);
        uint8_t c2 = rb(s.op2 + i);
        if (c1 > c2) { s.fs = 1; break; }
        else if (c2 > c1) { s.fs = 0; break; }
        if (bStop) {
            uint8_t stop = (uint8_t)gpr(26);
            if (c1 == stop || c2 == stop) { s.fcy = 0; break; }
        }
    }

    add_wr(s, 28, s.lenop1 + i);
    add_wr(s, 27, s.lenop2 + i);

    if (i == dest) {
        if (s.lenop1 > s.lenop2) s.fs = 1;
        else if (s.lenop2 > s.lenop1) s.fs = 0;
        else s.fz = 1;
    }
    return ilen;
}

static int op_cmpstr_h(uint32_t pc, uint8_t subop, OpState& s, int bFill, int bStop) {
    int ilen = f7a_decode(pc, subop, 0, 0, s);
    uint32_t dest = (s.lenop1 < s.lenop2) ? s.lenop1 : s.lenop2;
    uint32_t i;

    if (bFill) {
        uint16_t fill = (uint16_t)gpr(26);
        if (s.lenop1 < s.lenop2)
            for (i = s.lenop1; i < s.lenop2; i++) wh(s.op1 + i * 2, fill);
        else if (s.lenop2 < s.lenop1)
            for (i = s.lenop2; i < s.lenop1; i++) wh(s.op2 + i * 2, fill);
    }

    s.fz = 0; s.fs = 0;
    if (bStop) s.fcy = 1;

    for (i = 0; i < dest; i++) {
        uint16_t c1 = rh(s.op1 + i * 2);
        uint16_t c2 = rh(s.op2 + i * 2);
        if (c1 > c2) { s.fs = 1; break; }
        else if (c2 > c1) { s.fs = 0; break; }
        if (bStop) {
            uint16_t stop = (uint16_t)gpr(26);
            if (c1 == stop || c2 == stop) { s.fcy = 0; break; }
        }
    }

    add_wr(s, 28, s.lenop1 + i * 2);
    add_wr(s, 27, s.lenop2 + i * 2);

    if (i == dest) {
        if (s.lenop1 > s.lenop2) s.fs = 1;
        else if (s.lenop2 > s.lenop1) s.fs = 0;
        else s.fz = 1;
    }
    return ilen;
}

// MOVC: move string upward
static int op_movstr_ub(uint32_t pc, uint8_t subop, OpState& s, int bFill, int bStop) {
    int ilen = f7a_decode(pc, subop, 0, 0, s);
    uint32_t dest = (s.lenop1 < s.lenop2) ? s.lenop1 : s.lenop2;
    uint32_t i;

    for (i = 0; i < dest; i++) {
        uint8_t c1 = rb(s.op1 + i);
        wb(s.op2 + i, c1);
        if (bStop && c1 == (uint8_t)gpr(26)) break;
    }

    add_wr(s, 28, s.op1 + i);
    add_wr(s, 27, s.op2 + i);

    if (bFill && s.lenop1 < s.lenop2) {
        uint8_t fill = (uint8_t)gpr(26);
        for (; i < s.lenop2; i++) wb(s.op2 + i, fill);
        // Update R27 to final position
        s.wr_val[1] = s.op2 + i;
    }
    return ilen;
}

// MOVC: move string downward
static int op_movstr_db(uint32_t pc, uint8_t subop, OpState& s, int bFill, int bStop) {
    int ilen = f7a_decode(pc, subop, 0, 0, s);
    uint32_t dest = (s.lenop1 < s.lenop2) ? s.lenop1 : s.lenop2;
    uint32_t i;

    for (i = 0; i < dest; i++) {
        uint8_t c1 = rb(s.op1 + (dest - i - 1));
        wb(s.op2 + (dest - i - 1), c1);
        if (bStop && c1 == (uint8_t)gpr(26)) break;
    }

    add_wr(s, 28, s.op1 + (s.lenop1 - i - 1));
    add_wr(s, 27, s.op2 + (s.lenop2 - i - 1));

    if (bFill && s.lenop1 < s.lenop2) {
        for (; i < s.lenop2; i++)
            wb(s.op2 + dest + (s.lenop2 - i - 1), (uint8_t)gpr(26));
        s.wr_val[1] = s.op2 + (s.lenop2 - i - 1);
    }
    return ilen;
}

// MOVC halfword variants
static int op_movstr_uh(uint32_t pc, uint8_t subop, OpState& s, int bFill, int bStop) {
    int ilen = f7a_decode(pc, subop, 1, 1, s);
    uint32_t dest = (s.lenop1 < s.lenop2) ? s.lenop1 : s.lenop2;
    uint32_t i;

    for (i = 0; i < dest; i++) {
        uint16_t c1 = rh(s.op1 + i * 2);
        wh(s.op2 + i * 2, c1);
        if (bStop && c1 == (uint16_t)gpr(26)) break;
    }

    add_wr(s, 28, s.op1 + i * 2);
    add_wr(s, 27, s.op2 + i * 2);

    if (bFill && s.lenop1 < s.lenop2) {
        uint16_t fill = (uint16_t)gpr(26);
        for (; i < s.lenop2; i++) wh(s.op2 + i * 2, fill);
        s.wr_val[1] = s.op2 + i * 2;
    }
    return ilen;
}

static int op_movstr_dh(uint32_t pc, uint8_t subop, OpState& s, int bFill, int bStop) {
    int ilen = f7a_decode(pc, subop, 1, 1, s);
    uint32_t dest = (s.lenop1 < s.lenop2) ? s.lenop1 : s.lenop2;
    uint32_t i;

    for (i = 0; i < dest; i++) {
        uint16_t c1 = rh(s.op1 + (dest - i - 1) * 2);
        wh(s.op2 + (dest - i - 1) * 2, c1);
        if (bStop && c1 == (uint16_t)gpr(26)) break;
    }

    add_wr(s, 28, s.op1 + (s.lenop1 - i - 1) * 2);
    add_wr(s, 27, s.op2 + (s.lenop2 - i - 1) * 2);

    if (bFill && s.lenop1 < s.lenop2) {
        for (; i < s.lenop2; i++)
            wh(s.op2 + (s.lenop2 - i - 1) * 2, (uint16_t)gpr(26));
        s.wr_val[1] = s.op2 + (s.lenop2 - i - 1) * 2;
    }
    return ilen;
}

// SCHC: search character (upward/downward, byte/half)
static int op_search_ub(uint32_t pc, uint8_t subop, OpState& s, int bSearch) {
    int ilen = f7b_decode(pc, subop, 0, 0, s, false, true, false, false, true);
    uint32_t i;

    for (i = 0; i < s.lenop1; i++) {
        uint8_t match = (rb(s.op1 + i) == (uint8_t)s.op2);
        if ((bSearch && match) || (!bSearch && !match)) break;
    }

    add_wr(s, 28, s.op1 + i);
    add_wr(s, 27, i);

    // Opposite of V60 manual (matches MAME)
    s.fz = (i == s.lenop1) ? 1 : 0;
    return ilen;
}

static int op_search_uh(uint32_t pc, uint8_t subop, OpState& s, int bSearch) {
    int ilen = f7b_decode(pc, subop, 1, 1, s, false, true, false, false, true);
    uint32_t i;

    for (i = 0; i < s.lenop1; i++) {
        uint8_t match = (rh(s.op1 + i * 2) == (uint16_t)s.op2);
        if ((bSearch && match) || (!bSearch && !match)) break;
    }

    add_wr(s, 28, s.op1 + i * 2);
    add_wr(s, 27, i);

    s.fz = (i == s.lenop1) ? 1 : 0;
    return ilen;
}

static int op_search_db(uint32_t pc, uint8_t subop, OpState& s, int bSearch) {
    int ilen = f7b_decode(pc, subop, 0, 0, s, false, true, false, false, true);
    int32_t i;

    for (i = (int32_t)s.lenop1; i >= 0; i--) {
        uint8_t match = (rb(s.op1 + i) == (uint8_t)s.op2);
        if ((bSearch && match) || (!bSearch && !match)) break;
    }

    add_wr(s, 28, s.op1 + (uint32_t)i);
    add_wr(s, 27, (uint32_t)i);

    s.fz = ((uint32_t)i == s.lenop1) ? 1 : 0;
    return ilen;
}

static int op_search_dh(uint32_t pc, uint8_t subop, OpState& s, int bSearch) {
    int ilen = f7b_decode(pc, subop, 1, 1, s, false, true, false, false, true);
    int32_t i;

    for (i = (int32_t)s.lenop1 - 1; i >= 0; i--) {
        uint8_t match = (rh(s.op1 + i * 2) == (uint16_t)s.op2);
        if ((bSearch && match) || (!bSearch && !match)) break;
    }

    add_wr(s, 28, s.op1 + (uint32_t)(i * 2));
    add_wr(s, 27, (uint32_t)i);

    s.fz = ((uint32_t)i == s.lenop1) ? 1 : 0;
    return ilen;
}

// =========================================================================
// Bit String Operations (0x5B)
// =========================================================================

// SCH0BSU / SCH1BSU: search bit string
static int op_schbs(uint32_t pc, uint8_t subop, OpState& s, int bSearch1) {
    f7b_decode_first(pc, subop, 10, s, false, true);

    s.op1 += s.bamoffset / 8;
    uint8_t data = rb(s.op1);
    uint32_t offset = s.bamoffset & 7;
    uint32_t i;

    for (i = 0; i < s.lenop1; i++) {
        add_wr(s, 28, s.op1); // R28 updated each iteration (last wins)
        s.num_wr = 1; // reset to just R28

        if ((bSearch1 && (data & (1 << offset))) ||
            (!bSearch1 && !(data & (1 << offset))))
            break;

        offset++;
        if (offset == 8) {
            offset = 0;
            s.op1++;
            data = rb(s.op1);
        }
    }

    s.fz = (i == s.lenop1) ? 1 : 0;

    // Write result to AM2 destination
    s.modwritevalw = i;
    int m2 = subop & 0x20;
    uint32_t am2_base = pc + 3 + s.amlength1;
    AMResult am2 = decode_read_am_address(am2_base, pc, m2 ? 1 : 0, 2);
    s.amlength2 = am2.length;

    if (am2.flag) {
        add_wr(s, am2.value, i);
    } else {
        ww(am2.value, i);
    }

    return s.amlength1 + s.amlength2 + 3;
}

// MOVBSU: move bit string upward
static int op_movbsu(uint32_t pc, uint8_t subop, OpState& s) {
    int ilen = f7b_decode(pc, subop, 10, 10, s, false, true, false, true);

    s.op1 += s.bamoffset1 / 8;
    s.op2 += s.bamoffset2 / 8;
    s.bamoffset1 &= 7;
    s.bamoffset2 &= 7;

    uint8_t srcdata = rb(s.op1);
    uint8_t dstdata = rb(s.op2);

    for (uint32_t i = 0; i < s.lenop1; i++) {
        dstdata &= ~(1 << s.bamoffset2);
        dstdata |= ((srcdata >> s.bamoffset1) & 1) << s.bamoffset2;

        s.bamoffset1++;
        s.bamoffset2++;
        if (s.bamoffset1 == 8) {
            s.bamoffset1 = 0;
            s.op1++;
            srcdata = rb(s.op1);
        }
        if (s.bamoffset2 == 8) {
            wb(s.op2, dstdata);
            s.bamoffset2 = 0;
            s.op2++;
            dstdata = rb(s.op2);
        }
    }

    if (s.bamoffset2 != 0) wb(s.op2, dstdata);

    add_wr(s, 28, s.op1);
    add_wr(s, 27, s.op2);
    return ilen;
}

// MOVBSD: move bit string downward
static int op_movbsd(uint32_t pc, uint8_t subop, OpState& s) {
    int ilen = f7b_decode(pc, subop, 10, 10, s, false, true, false, true);

    s.bamoffset1 += s.lenop1 - 1;
    s.bamoffset2 += s.lenop1 - 1;

    s.op1 += s.bamoffset1 / 8;
    s.op2 += s.bamoffset2 / 8;
    s.bamoffset1 &= 7;
    s.bamoffset2 &= 7;

    uint8_t srcdata = rb(s.op1);
    uint8_t dstdata = rb(s.op2);

    for (uint32_t i = 0; i < s.lenop1; i++) {
        dstdata &= ~(1 << s.bamoffset2);
        dstdata |= ((srcdata >> s.bamoffset1) & 1) << s.bamoffset2;

        if (s.bamoffset1 == 0) {
            s.bamoffset1 = 8;
            s.op1--;
            srcdata = rb(s.op1);
        }
        if (s.bamoffset2 == 0) {
            wb(s.op2, dstdata);
            s.bamoffset2 = 8;
            s.op2--;
            dstdata = rb(s.op2);
        }
        s.bamoffset1--;
        s.bamoffset2--;
    }

    if (s.bamoffset2 != 7) wb(s.op2, dstdata);

    add_wr(s, 28, s.op1);
    add_wr(s, 27, s.op2);
    return ilen;
}

// =========================================================================
// Bitfield Operations (0x5D)
// =========================================================================

static int op_extbfz(uint32_t pc, uint8_t subop, OpState& s) {
    f7b_decode_first(pc, subop, 11, s, true, false);

    uint32_t mask = ((1u << s.lenop1) - 1);
    s.modwritevalw = (s.op1 >> s.bamoffset) & mask;

    int m2 = subop & 0x20;
    uint32_t am2_base = pc + 3 + s.amlength1;
    AMResult am2 = decode_read_am_address(am2_base, pc, m2 ? 1 : 0, 2);
    s.amlength2 = am2.length;

    if (am2.flag)
        add_wr(s, am2.value, s.modwritevalw);
    else
        ww(am2.value, s.modwritevalw);

    return s.amlength1 + s.amlength2 + 3;
}

static int op_extbfs(uint32_t pc, uint8_t subop, OpState& s) {
    f7b_decode_first(pc, subop, 11, s, true, false);

    uint32_t mask = ((1u << s.lenop1) - 1);
    s.modwritevalw = (s.op1 >> s.bamoffset) & mask;
    if (s.modwritevalw & ((mask + 1) >> 1))
        s.modwritevalw |= ~mask;

    int m2 = subop & 0x20;
    uint32_t am2_base = pc + 3 + s.amlength1;
    AMResult am2 = decode_read_am_address(am2_base, pc, m2 ? 1 : 0, 2);
    s.amlength2 = am2.length;

    if (am2.flag)
        add_wr(s, am2.value, s.modwritevalw);
    else
        ww(am2.value, s.modwritevalw);

    return s.amlength1 + s.amlength2 + 3;
}

static int op_extbfl(uint32_t pc, uint8_t subop, OpState& s) {
    f7b_decode_first(pc, subop, 11, s, true, false);

    uint32_t appw = s.lenop1;
    uint32_t mask = ((1u << s.lenop1) - 1);
    s.modwritevalw = (s.op1 >> s.bamoffset) & mask;
    s.modwritevalw <<= (32 - appw);

    int m2 = subop & 0x20;
    uint32_t am2_base = pc + 3 + s.amlength1;
    AMResult am2 = decode_read_am_address(am2_base, pc, m2 ? 1 : 0, 2);
    s.amlength2 = am2.length;

    if (am2.flag)
        add_wr(s, am2.value, s.modwritevalw);
    else
        ww(am2.value, s.modwritevalw);

    return s.amlength1 + s.amlength2 + 3;
}

static int op_insbfr(uint32_t pc, uint8_t subop, OpState& s) {
    int ilen = f7c_decode(pc, subop, 2, 11, s, true);

    uint32_t mask = ((1u << s.lenop1) - 1);
    s.op2 += s.bamoffset2 / 8;
    uint32_t appw = rw(s.op2);
    int boff = s.bamoffset2 & 7;

    appw &= ~(mask << boff);
    appw |= (mask & s.op1) << boff;
    ww(s.op2, appw);

    return ilen;
}

static int op_insbfl(uint32_t pc, uint8_t subop, OpState& s) {
    int ilen = f7c_decode(pc, subop, 2, 11, s, true);

    uint32_t shifted = s.op1 >> (32 - s.lenop1);
    uint32_t mask = ((1u << s.lenop1) - 1);
    s.op2 += s.bamoffset2 / 8;
    uint32_t appw = rw(s.op2);
    int boff = s.bamoffset2 & 7;

    appw &= ~(mask << boff);
    appw |= (mask & shifted) << boff;
    ww(s.op2, appw);

    return ilen;
}

// =========================================================================
// Decimal Operations (0x59)
// =========================================================================

static int op_adddc(uint32_t pc, uint8_t subop, OpState& s, uint32_t psw) {
    int ilen = f7c_decode(pc, subop, 0, 0, s);

    uint8_t appb;
    if (s.flag2)
        appb = (uint8_t)(gpr(s.op2) & 0xFF);
    else
        appb = rb(s.op2);

    uint32_t src = ((s.op1 >> 4) & 0xF) * 10 + (s.op1 & 0xF);
    uint32_t dst = ((appb >> 4) & 0xF) * 10 + (appb & 0xF);

    uint32_t result = src + dst + ((psw >> 3) & 1); // CY
    s.fcy = 0;
    if (result >= 100) { result -= 100; s.fcy = 1; }

    // Z: cleared if result non-zero or carry; unchanged otherwise
    s.fz = (psw & 1); // preserve
    if (result != 0 || s.fcy) s.fz = 0;

    appb = (uint8_t)(((result / 10) << 4) | (result % 10));

    if (s.flag2)
        add_wr(s, s.op2, setreg8(gpr(s.op2), appb));
    else
        wb(s.op2, appb);

    return ilen;
}

static int op_subdc(uint32_t pc, uint8_t subop, OpState& s, uint32_t psw) {
    int ilen = f7c_decode(pc, subop, 0, 0, s);

    int8_t appb;
    if (s.flag2)
        appb = (int8_t)(gpr(s.op2) & 0xFF);
    else
        appb = (int8_t)rb(s.op2);

    uint32_t src = ((s.op1 >> 4) & 0xF) * 10 + (s.op1 & 0xF);
    uint32_t dst = (((appb & 0xF0) >> 4) & 0xF) * 10 + (appb & 0xF);

    int32_t result = (int32_t)dst - (int32_t)src - ((psw >> 3) & 1);
    s.fcy = 0;
    if (result < 0) { result += 100; s.fcy = 1; }

    s.fz = (psw & 1);
    if (result != 0 || s.fcy) s.fz = 0;

    appb = (int8_t)(((result / 10) << 4) | (result % 10));

    if (s.flag2)
        add_wr(s, s.op2, setreg8(gpr(s.op2), (uint8_t)appb));
    else
        wb(s.op2, (uint8_t)appb);

    return ilen;
}

static int op_subrdc(uint32_t pc, uint8_t subop, OpState& s, uint32_t psw) {
    int ilen = f7c_decode(pc, subop, 0, 0, s);

    int8_t appb;
    if (s.flag2)
        appb = (int8_t)(gpr(s.op2) & 0xFF);
    else
        appb = (int8_t)rb(s.op2);

    uint32_t src = ((s.op1 >> 4) & 0xF) * 10 + (s.op1 & 0xF);
    uint32_t dst = (((appb & 0xF0) >> 4) & 0xF) * 10 + (appb & 0xF);

    int32_t result = (int32_t)src - (int32_t)dst - ((psw >> 3) & 1);
    s.fcy = 0;
    if (result < 0) { result += 100; s.fcy = 1; }

    s.fz = (psw & 1);
    if (result != 0 || s.fcy) s.fz = 0;

    appb = (int8_t)(((result / 10) << 4) | (result % 10));

    if (s.flag2)
        add_wr(s, s.op2, setreg8(gpr(s.op2), (uint8_t)appb));
    else
        wb(s.op2, (uint8_t)appb);

    return ilen;
}

static int op_cvtdpz(uint32_t pc, uint8_t subop, OpState& s) {
    int ilen = f7c_decode(pc, subop, 0, 1, s);

    uint16_t apph = (uint16_t)(((s.op1 >> 4) & 0xF) | ((s.op1 & 0xF) << 8));
    apph |= s.lenop1;
    apph |= (s.lenop1 << 8);

    s.fz = -1; // special: unchanged if src==0, cleared otherwise
    if (s.op1 != 0) s.fz = 0;

    if (s.flag2)
        add_wr(s, s.op2, setreg16(gpr(s.op2), apph));
    else
        wh(s.op2, apph);

    return ilen;
}

static int op_cvtdzp(uint32_t pc, uint8_t subop, OpState& s) {
    int ilen = f7c_decode(pc, subop, 1, 0, s);

    uint8_t appb = (uint8_t)(((s.op1 >> 8) & 0xF) | ((s.op1 & 0xF) << 4));

    s.fz = -1; // special
    if (appb != 0) s.fz = 0;

    if (s.flag2)
        add_wr(s, s.op2, setreg8(gpr(s.op2), appb));
    else
        wb(s.op2, appb);

    return ilen;
}

// =========================================================================
// Main dispatch — called from RTL via DPI-C
// =========================================================================

extern "C" void v60_string_init() {
    scope_top = svGetScopeFromName("TOP.tb_v60_top");
    scope_mem = svGetScopeFromName("TOP.tb_v60_top.u_mem");
    if (!scope_top) {
        scope_top = svGetScopeFromName("TOP.u_tb_v60_top");
        scope_mem = svGetScopeFromName("TOP.u_mem");
    }
}

// Sync shadow memory from SV memory (call after loading binary)
extern "C" void v60_string_sync_mem() {
    svSetScope(scope_mem);
    for (int i = 0; i < MEM_SIZE; i++)
        shadow_mem[i] = (uint8_t)mem_read_byte(i);
    shadow_valid = true;
}

// Flush deferred memory writes to SV memory (call from C++ testbench outside eval)
// Get pending memory writes for testbench to apply
extern "C" int v60_string_get_num_mem_writes() {
    return num_mem_writes;
}

extern "C" void v60_string_get_mem_write(int idx, int* addr, int* data) {
    if (idx >= 0 && idx < num_mem_writes) {
        *addr = (int)mem_writes[idx].addr;
        *data = (int)mem_writes[idx].data;
    }
}

extern "C" void v60_string_clear_mem_writes() {
    num_mem_writes = 0;
}


extern "C" void v60_string_exec(
    int pc_in, int psw_in,
    int* inst_len_out, int* new_psw_out,
    int* num_wr_out,
    int* wr0_idx, int* wr0_val,
    int* wr1_idx, int* wr1_val,
    int* wr2_idx, int* wr2_val
) {
    uint32_t pc  = (uint32_t)pc_in;
    uint32_t psw = (uint32_t)psw_in;
    uint8_t opcode = rb(pc);
    uint8_t subop  = rb(pc + 1);
    int sub5 = subop & 0x1F;

    OpState s;
    memset(&s, 0, sizeof(s));
    s.fz = -1; s.fs = -1; s.fov = -1; s.fcy = -1; // -1 = unchanged

    int ilen = 2; // default

    switch (opcode) {
    case 0x58: // Byte string operations
        switch (sub5) {
            case 0x00: ilen = op_cmpstr_b(pc, subop, s, 0, 0); break; // CMPCB
            case 0x01: ilen = op_cmpstr_b(pc, subop, s, 1, 0); break; // CMPCFB
            case 0x02: ilen = op_cmpstr_b(pc, subop, s, 0, 1); break; // CMPCSB
            case 0x08: ilen = op_movstr_ub(pc, subop, s, 0, 0); break; // MOVCUB
            case 0x09: ilen = op_movstr_db(pc, subop, s, 0, 0); break; // MOVCDB
            case 0x0A: ilen = op_movstr_ub(pc, subop, s, 1, 0); break; // MOVCFUB
            case 0x0B: ilen = op_movstr_db(pc, subop, s, 1, 0); break; // MOVCFDB
            case 0x0C: ilen = op_movstr_ub(pc, subop, s, 0, 1); break; // MOVCSUB
            case 0x18: ilen = op_search_ub(pc, subop, s, 1); break; // SCHCUB
            case 0x19: ilen = op_search_db(pc, subop, s, 1); break; // SCHCDB
            case 0x1A: ilen = op_search_ub(pc, subop, s, 0); break; // SKPCUB
            case 0x1B: ilen = op_search_db(pc, subop, s, 0); break; // SKPCDB
            default:
                fprintf(stderr, "v60_string: unhandled 0x58 subop 0x%02x at PC=0x%08x\n", sub5, pc);
                break;
        }
        break;

    case 0x5A: // Halfword string operations
        switch (sub5) {
            case 0x00: ilen = op_cmpstr_h(pc, subop, s, 0, 0); break; // CMPCFH
            case 0x01: ilen = op_cmpstr_h(pc, subop, s, 1, 0); break; // CMPCFH
            case 0x02: ilen = op_cmpstr_h(pc, subop, s, 0, 1); break; // CMPCSPH
            case 0x08: ilen = op_movstr_uh(pc, subop, s, 0, 0); break; // MOVCUH
            case 0x09: ilen = op_movstr_dh(pc, subop, s, 0, 0); break; // MOVCDH
            case 0x0A: ilen = op_movstr_uh(pc, subop, s, 1, 0); break; // MOVCFUH
            case 0x0B: ilen = op_movstr_dh(pc, subop, s, 1, 0); break; // MOVCFDH
            case 0x0C: ilen = op_movstr_uh(pc, subop, s, 0, 1); break; // MOVCUSH
            case 0x18: ilen = op_search_uh(pc, subop, s, 1); break; // SCHCUH
            case 0x19: ilen = op_search_dh(pc, subop, s, 1); break; // SCHCDH
            case 0x1A: ilen = op_search_uh(pc, subop, s, 0); break; // SKPCUH
            case 0x1B: ilen = op_search_dh(pc, subop, s, 0); break; // SKPCDH
            default:
                fprintf(stderr, "v60_string: unhandled 0x5A subop 0x%02x at PC=0x%08x\n", sub5, pc);
                break;
        }
        break;

    case 0x5B: // Bit string operations
        switch (sub5) {
            case 0x00: ilen = op_schbs(pc, subop, s, 0); break; // SCH0BSU
            case 0x02: ilen = op_schbs(pc, subop, s, 1); break; // SCH1BSU
            case 0x08: ilen = op_movbsu(pc, subop, s); break;   // MOVBSU
            case 0x09: ilen = op_movbsd(pc, subop, s); break;   // MOVBSD
            default:
                fprintf(stderr, "v60_string: unhandled 0x5B subop 0x%02x at PC=0x%08x\n", sub5, pc);
                break;
        }
        break;

    case 0x5D: // Bitfield operations
        switch (sub5) {
            case 0x08: ilen = op_extbfs(pc, subop, s); break; // EXTBFS
            case 0x09: ilen = op_extbfz(pc, subop, s); break; // EXTBFZ
            case 0x0A: ilen = op_extbfl(pc, subop, s); break; // EXTBFL
            case 0x18: ilen = op_insbfr(pc, subop, s); break; // INSBFR
            case 0x19: ilen = op_insbfl(pc, subop, s); break; // INSBFL
            default:
                fprintf(stderr, "v60_string: unhandled 0x5D subop 0x%02x at PC=0x%08x\n", sub5, pc);
                break;
        }
        break;

    case 0x59: // Decimal operations
        switch (sub5) {
            case 0x00: ilen = op_adddc(pc, subop, s, psw); break;  // ADDDC
            case 0x01: ilen = op_subdc(pc, subop, s, psw); break;  // SUBDC
            case 0x02: ilen = op_subrdc(pc, subop, s, psw); break; // SUBRDC
            case 0x10: ilen = op_cvtdpz(pc, subop, s); break;      // CVTDPZ
            case 0x18: ilen = op_cvtdzp(pc, subop, s); break;      // CVTDZP
            default:
                fprintf(stderr, "v60_string: unhandled 0x59 subop 0x%02x at PC=0x%08x\n", sub5, pc);
                break;
        }
        break;

    default:
        fprintf(stderr, "v60_string: unknown opcode 0x%02x at PC=0x%08x\n", opcode, pc);
        break;
    }

    // Build output PSW (merge changed flags into existing PSW)
    uint32_t new_psw = psw;
    if (s.fz >= 0) new_psw = (new_psw & ~(1u << 0)) | ((s.fz & 1) << 0);
    if (s.fs >= 0) new_psw = (new_psw & ~(1u << 1)) | ((s.fs & 1) << 1);
    if (s.fov >= 0) new_psw = (new_psw & ~(1u << 2)) | ((s.fov & 1) << 2);
    if (s.fcy >= 0) new_psw = (new_psw & ~(1u << 3)) | ((s.fcy & 1) << 3);

    *inst_len_out = ilen;
    *new_psw_out  = (int)new_psw;
    *num_wr_out   = s.num_wr;
    *wr0_idx = (s.num_wr > 0) ? s.wr_idx[0] : 0;
    *wr0_val = (s.num_wr > 0) ? (int)s.wr_val[0] : 0;
    *wr1_idx = (s.num_wr > 1) ? s.wr_idx[1] : 0;
    *wr1_val = (s.num_wr > 1) ? (int)s.wr_val[1] : 0;
    *wr2_idx = (s.num_wr > 2) ? s.wr_idx[2] : 0;
    *wr2_val = (s.num_wr > 2) ? (int)s.wr_val[2] : 0;
}
