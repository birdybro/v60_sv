// emu.h — MAME framework stubs for standalone V60 harness
// Provides enough of the MAME infrastructure for v60.cpp to compile unmodified.

#ifndef EMU_H
#define EMU_H

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdarg>
#include <cmath>
#include <cassert>
#include <functional>
#include <memory>
#include <string>
#include <vector>
#include <map>
#include <utility>
#include <ostream>

// =========================================================================
// MAME type aliases
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

// =========================================================================
// Constants
// =========================================================================
#define CLEAR_LINE      0
#define ASSERT_LINE     1
#define INPUT_LINE_NMI  0x20

#define AS_PROGRAM      0
#define AS_IO           1

#define ENDIANNESS_LITTLE 0

#define STATE_GENPC     0x1000
#define STATE_GENPCBASE 0x1001
#define STATE_GENFLAGS  0x1002

#define ATTR_COLD

// =========================================================================
// Utility
// =========================================================================
#define BIT(val, bit) (((val) >> (bit)) & 1)

[[noreturn]] inline void fatalerror_impl(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
    exit(1);
}
#define fatalerror(...) fatalerror_impl(__VA_ARGS__)

template<typename... Args>
std::string string_format(const char* fmt, Args... args) {
    char buf[256];
    snprintf(buf, sizeof(buf), fmt, args...);
    return std::string(buf);
}

// Endian swap helpers
inline u16 swapendian_int16(u16 val) {
    return (val >> 8) | (val << 8);
}
inline u32 swapendian_int32(u32 val) {
    return ((val >> 24) & 0xFF) | ((val >> 8) & 0xFF00) |
           ((val << 8) & 0xFF0000) | ((val << 24) & 0xFF000000);
}

// Float ↔ uint32_t conversion (bit-preserving)
inline float u2f(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
inline uint32_t f2u(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }

// 64÷32 division with remainder (signed)
inline int32_t div_64x32_rem(int64_t a, int32_t b, int32_t &remainder) {
    remainder = (int32_t)(a % b);
    return (int32_t)(a / b);
}

// 64÷32 division with remainder (unsigned)
inline uint32_t divu_64x32_rem(uint64_t a, uint32_t b, uint32_t &remainder) {
    remainder = (uint32_t)(a % b);
    return (uint32_t)(a / b);
}

// 32×32 multiply → 64-bit result
inline int64_t  mul_32x32(int32_t a, int32_t b)   { return (int64_t)a * b; }
inline uint64_t mulu_32x32(uint32_t a, uint32_t b) { return (uint64_t)a * b; }

// bitswap<N>(val, b0, b1, ..., bN-1) — permute bits
template<int N, typename T, typename... B>
T bitswap(T val, B... bits) {
    int indices[] = { static_cast<int>(bits)... };
    T result = 0;
    for (int i = 0; i < N; i++) {
        if (val & ((T)1 << indices[i]))
            result |= (T)1 << (N - 1 - i);
    }
    return result;
}

// =========================================================================
// Save state (no-op)
// =========================================================================
#define NAME(x) x

// =========================================================================
// address_space_config
// =========================================================================
class address_space_config {
public:
    int m_data_width;
    int m_addr_width;

    address_space_config()
        : m_data_width(0), m_addr_width(0) {}
    address_space_config(const char*, int, int databits, int addrbits, int)
        : m_data_width(databits), m_addr_width(addrbits) {}

    int data_width() const { return m_data_width; }
};

// =========================================================================
// address_space — flat byte array
// =========================================================================
class address_space {
public:
    static constexpr int MEM_SIZE = 16 * 1024 * 1024; // 16MB
    uint8_t* mem;
    int m_data_width;

    address_space(int data_width = 16) : m_data_width(data_width) {
        mem = new uint8_t[MEM_SIZE];
        memset(mem, 0xCD, MEM_SIZE); // Fill with NOP
    }
    ~address_space() { delete[] mem; }

    int data_width() const { return m_data_width; }

    // Cache support — any cache type with m_space pointer
    template<typename T>
    void cache(T& c) { c.m_space = this; }

    // Read
    u8 read_byte(offs_t addr) {
        return mem[addr & (MEM_SIZE - 1)];
    }
    u16 read_word(offs_t addr) {
        u16 val = mem[addr & (MEM_SIZE - 1)];
        val |= (u16)mem[(addr + 1) & (MEM_SIZE - 1)] << 8;
        return val;
    }
    u16 read_word_unaligned(offs_t addr) { return read_word(addr); }
    u32 read_dword(offs_t addr) {
        u32 val = mem[addr & (MEM_SIZE - 1)];
        val |= (u32)mem[(addr + 1) & (MEM_SIZE - 1)] << 8;
        val |= (u32)mem[(addr + 2) & (MEM_SIZE - 1)] << 16;
        val |= (u32)mem[(addr + 3) & (MEM_SIZE - 1)] << 24;
        return val;
    }
    u32 read_dword_unaligned(offs_t addr) { return read_dword(addr); }
    u64 read_qword(offs_t addr) {
        u64 val = (u64)read_dword(addr);
        val |= (u64)read_dword(addr + 4) << 32;
        return val;
    }
    u64 read_qword_unaligned(offs_t addr) { return read_qword(addr); }

    // Write
    void write_byte(offs_t addr, u8 data) {
        mem[addr & (MEM_SIZE - 1)] = data;
    }
    void write_word(offs_t addr, u16 data) {
        mem[addr & (MEM_SIZE - 1)] = data & 0xFF;
        mem[(addr + 1) & (MEM_SIZE - 1)] = (data >> 8) & 0xFF;
    }
    void write_word_unaligned(offs_t addr, u16 data) { write_word(addr, data); }
    void write_dword(offs_t addr, u32 data) {
        mem[addr & (MEM_SIZE - 1)] = data & 0xFF;
        mem[(addr + 1) & (MEM_SIZE - 1)] = (data >> 8) & 0xFF;
        mem[(addr + 2) & (MEM_SIZE - 1)] = (data >> 16) & 0xFF;
        mem[(addr + 3) & (MEM_SIZE - 1)] = (data >> 24) & 0xFF;
    }
    void write_dword_unaligned(offs_t addr, u32 data) { write_dword(addr, data); }
    void write_qword(offs_t addr, u64 data) {
        write_dword(addr, (u32)data);
        write_dword(addr + 4, (u32)(data >> 32));
    }
    void write_qword_unaligned(offs_t addr, u64 data) { write_qword(addr, data); }
};

// =========================================================================
// memory_access template — cache delegates to address_space
// =========================================================================
template <int AddrWidth, int DataWidth, int AddrShift, int Endian>
struct memory_access {
    struct cache {
        address_space* m_space = nullptr;
        u8  read_byte(offs_t a)           { return m_space->read_byte(a); }
        u16 read_word_unaligned(offs_t a) { return m_space->read_word_unaligned(a); }
        u32 read_dword_unaligned(offs_t a){ return m_space->read_dword_unaligned(a); }
    };
};

// =========================================================================
// device_state_entry — chainable dummy
// =========================================================================
class device_state_entry {
public:
    int m_index;
    device_state_entry(int index = 0) : m_index(index) {}
    int index() const { return m_index; }
    device_state_entry& formatstr(const char*) { return *this; }
    device_state_entry& callimport() { return *this; }
    device_state_entry& callexport() { return *this; }
    device_state_entry& noshow() { return *this; }
};

// =========================================================================
// Device type machinery
// =========================================================================
using device_type = int;
using device_t = void;
struct machine_config {};

// Macro must produce a complete declaration (no trailing ; in MAME source)
#define DECLARE_DEVICE_TYPE(Type, Class) \
    inline constexpr device_type Type = __LINE__;

#define DEFINE_DEVICE_TYPE(Type, Class, ShortName, FullName) \
    /* device type already declared in header */

// =========================================================================
// space_config_vector and device_memory_interface
// =========================================================================
using space_config_vector = std::vector<std::pair<int, const address_space_config*>>;

// v60.cpp uses fully-qualified device_memory_interface::space_config_vector
struct device_memory_interface {
    using space_config_vector = ::space_config_vector;
};

// =========================================================================
// Disassembler interface stub
// =========================================================================
namespace util {
    class disasm_interface {
    public:
        struct data_buffer {};
        virtual ~disasm_interface() = default;
        virtual u32 opcode_alignment() const = 0;
        virtual offs_t disassemble(std::ostream&, offs_t,
                                   const data_buffer&, const data_buffer&) = 0;
    };
}
using data_buffer = util::disasm_interface::data_buffer;

// =========================================================================
// cpu_device — base class for v60_device
// =========================================================================
class cpu_device {
protected:
    std::map<int, address_space*> m_spaces;
    std::map<int, uint32_t*> m_state_refs;
    device_state_entry m_dummy_state;
    int* m_icountptr = nullptr;

    // --- Virtual methods overridden by v60_device ---
    virtual void device_start() {}
    virtual void device_reset() {}
    virtual uint32_t execute_min_cycles() const noexcept { return 1; }
    virtual uint32_t execute_max_cycles() const noexcept { return 1; }
    virtual bool execute_input_edge_triggered(int) const noexcept { return false; }
    virtual void execute_run() {}
    virtual void execute_set_input(int, int) {}
    virtual space_config_vector memory_space_config() const { return {}; }
    virtual void state_import(const device_state_entry&) {}
    virtual void state_export(const device_state_entry&) {}
    virtual void state_string_export(const device_state_entry&, std::string&) const {}
    virtual std::unique_ptr<util::disasm_interface> create_disassembler() { return nullptr; }

    // --- Save state (no-op) ---
    template<typename T> void save_item(T&&) {}

    // --- State registration ---
    device_state_entry& state_add(int index, const char*, uint32_t& ref) {
        m_state_refs[index] = &ref;
        m_dummy_state = device_state_entry(index);
        return m_dummy_state;
    }

    // --- Icount ---
    void set_icountptr(int& icount) { m_icountptr = &icount; }

    // --- Debugger hooks (no-op) ---
    void debugger_instruction_hook(uint32_t) {}
    void debugger_exception_hook(int) {}

    // --- IRQ callback ---
    int standard_irq_callback(int, uint32_t) { return 0; }

    // --- Logging (member function, called from .hxx code) ---
    void logerror(const char* fmt, ...) const {
        va_list args;
        va_start(args, fmt);
        vfprintf(stderr, fmt, args);
        va_end(args);
    }

public:
    cpu_device(const machine_config&, device_type, const char*, device_t*, uint32_t) {}
    virtual ~cpu_device() {
        for (auto& [id, sp] : m_spaces) delete sp;
    }

    // --- Create address spaces from memory_space_config() ---
    void resolve_spaces() {
        auto configs = memory_space_config();
        for (auto& [id, cfg] : configs) {
            m_spaces[id] = new address_space(cfg->data_width());
        }
    }

    // --- Public space accessor ---
    address_space& space(int id) { return *m_spaces.at(id); }

    // --- Public state accessors ---
    uint32_t state_value(int index) {
        device_state_entry entry(index);
        state_export(entry); // triggers v60ReadPSW for PSW, etc.
        auto it = m_state_refs.find(index);
        if (it != m_state_refs.end()) return *it->second;
        return 0;
    }

    void set_state_value(int index, uint32_t value) {
        auto it = m_state_refs.find(index);
        if (it != m_state_refs.end()) {
            *it->second = value;
            device_state_entry entry(index);
            state_import(entry); // triggers v60WritePSW for PSW, etc.
        }
    }

    // --- Icount pointer (for single-stepping) ---
    int* icountptr() const { return m_icountptr; }

    // --- Public wrappers for protected virtual methods ---
    void do_start() { device_start(); }
    void do_reset() { device_reset(); }
    void do_run()   { execute_run(); }
};

#endif // EMU_H
