// mame_stubs.h — Minimal stubs replacing MAME device framework
// Provides enough of the MAME infrastructure for the V60 CPU core to compile
// as a standalone harness.

#ifndef MAME_STUBS_H
#define MAME_STUBS_H

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cassert>
#include <vector>

// =========================================================================
// Basic MAME types
// =========================================================================
typedef uint8_t  u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int8_t   s8;
typedef int16_t  s16;
typedef int32_t  s32;
typedef int64_t  s64;

typedef uint32_t offs_t;

// BIT macro
#define BIT(val, bit) (((val) >> (bit)) & 1)

// Endian helpers (V60 is little-endian)
inline u16 swapendian_int16(u16 val) {
    return (val >> 8) | (val << 8);
}

inline u32 swapendian_int32(u32 val) {
    return ((val >> 24) & 0xFF) |
           ((val >> 8)  & 0xFF00) |
           ((val << 8)  & 0xFF0000) |
           ((val << 24) & 0xFF000000);
}

// =========================================================================
// Memory space stub — flat byte array
// =========================================================================
class address_space {
public:
    static constexpr int MEM_SIZE = 16 * 1024 * 1024;  // 16MB for V60
    uint8_t* mem;

    address_space() {
        mem = new uint8_t[MEM_SIZE];
        memset(mem, 0xCD, MEM_SIZE);  // Fill with NOP
    }

    ~address_space() {
        delete[] mem;
    }

    // Read functions
    u8 read_byte(offs_t addr) {
        return mem[addr & (MEM_SIZE - 1)];
    }

    u16 read_word(offs_t addr) {
        u16 val = mem[addr & (MEM_SIZE - 1)];
        val |= (u16)mem[(addr + 1) & (MEM_SIZE - 1)] << 8;
        return val;
    }

    u16 read_word_unaligned(offs_t addr) {
        return read_word(addr);
    }

    u32 read_dword(offs_t addr) {
        u32 val = mem[addr & (MEM_SIZE - 1)];
        val |= (u32)mem[(addr + 1) & (MEM_SIZE - 1)] << 8;
        val |= (u32)mem[(addr + 2) & (MEM_SIZE - 1)] << 16;
        val |= (u32)mem[(addr + 3) & (MEM_SIZE - 1)] << 24;
        return val;
    }

    u32 read_dword_unaligned(offs_t addr) {
        return read_dword(addr);
    }

    // Write functions
    void write_byte(offs_t addr, u8 data) {
        mem[addr & (MEM_SIZE - 1)] = data;
    }

    void write_word(offs_t addr, u16 data) {
        mem[addr & (MEM_SIZE - 1)] = data & 0xFF;
        mem[(addr + 1) & (MEM_SIZE - 1)] = (data >> 8) & 0xFF;
    }

    void write_word_unaligned(offs_t addr, u16 data) {
        write_word(addr, data);
    }

    void write_dword(offs_t addr, u32 data) {
        mem[addr & (MEM_SIZE - 1)] = data & 0xFF;
        mem[(addr + 1) & (MEM_SIZE - 1)] = (data >> 8) & 0xFF;
        mem[(addr + 2) & (MEM_SIZE - 1)] = (data >> 16) & 0xFF;
        mem[(addr + 3) & (MEM_SIZE - 1)] = (data >> 24) & 0xFF;
    }

    void write_dword_unaligned(offs_t addr, u32 data) {
        write_dword(addr, data);
    }

    // Load binary file
    int load_binary(const char* filename, uint32_t base_addr) {
        FILE* f = fopen(filename, "rb");
        if (!f) return -1;
        int addr = base_addr;
        int c;
        while ((c = fgetc(f)) != EOF) {
            write_byte(addr++, (u8)c);
        }
        fclose(f);
        return addr - base_addr;
    }
};

// =========================================================================
// I/O space stub
// =========================================================================
class io_space {
public:
    u8 read_byte(offs_t addr) { return 0xFF; }
    u16 read_word(offs_t addr) { return 0xFFFF; }
    u32 read_dword(offs_t addr) { return 0xFFFFFFFF; }
    void write_byte(offs_t addr, u8 data) {}
    void write_word(offs_t addr, u16 data) {}
    void write_dword(offs_t addr, u32 data) {}
};

// =========================================================================
// Minimal device stubs
// =========================================================================

// Logging macros (no-op or stderr)
#define logerror(fmt, ...) fprintf(stderr, fmt, ##__VA_ARGS__)
#define fatalerror(fmt, ...) do { fprintf(stderr, fmt, ##__VA_ARGS__); exit(1); } while(0)

#endif // MAME_STUBS_H
