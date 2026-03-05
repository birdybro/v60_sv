// v60_fp.cpp — DPI-C floating point implementation for V60 FPU
// Matches MAME op2.hxx float arithmetic exactly

#include <cstdint>
#include <cstring>
#include <cmath>

static float u2f(uint32_t u) {
    float f;
    memcpy(&f, &u, sizeof(f));
    return f;
}

static uint32_t f2u(float f) {
    uint32_t u;
    memcpy(&u, &f, sizeof(u));
    return u;
}

// FP operation codes (must match fp_op_t in v60_pkg.sv)
enum {
    FP_NONE  = 0,
    FP_CMPF  = 1,
    FP_MOVF  = 2,
    FP_NEGF  = 3,
    FP_ABSF  = 4,
    FP_SCLF  = 5,
    FP_ADDF  = 6,
    FP_SUBF  = 7,
    FP_MULF  = 8,
    FP_DIVF  = 9,
    FP_CVTWS = 10,
    FP_CVTSW = 11,
};

extern "C" void v60_fp_exec(
    int op,           // fp_op_t
    int a,            // operand 1 (AM1 value)
    int b,            // operand 2 (AM2 value, for R-M-W ops)
    int rounding,     // TKCW & 7 rounding mode (for CVT.SW)
    int* result,
    unsigned char* fz,
    unsigned char* fs,
    unsigned char* fov,
    unsigned char* fcy
) {
    uint32_t ua = (uint32_t)a;
    uint32_t ub = (uint32_t)b;
    uint32_t res = 0;
    float appf;
    uint32_t appw;

    *fz = 0; *fs = 0; *fov = 0; *fcy = 0;

    switch (op) {
    case FP_CMPF:
        // op2 - op1
        appf = u2f(ub) - u2f(ua);
        *fz = (appf == 0.0f);
        *fs = (appf < 0.0f);
        *fov = 0;
        *fcy = 0;
        res = 0; // no result written
        break;

    case FP_MOVF:
        res = ua;
        // no flags
        break;

    case FP_NEGF:
        appf = -u2f(ua);
        res = f2u(appf);
        *fov = 0;
        *fcy = (appf < 0.0f);
        *fs = ((res & 0x80000000u) != 0);
        *fz = (appf == 0.0f);
        break;

    case FP_ABSF:
        appf = u2f(ua);
        if (appf < 0) appf = -appf;
        res = f2u(appf);
        *fov = 0;
        *fcy = 0;
        *fs = ((res & 0x80000000u) != 0);
        *fz = (appf == 0.0f);
        break;

    case FP_SCLF: {
        // a = scale count (int16), b = float to scale
        appf = u2f(ub);
        int16_t count = (int16_t)(ua & 0xFFFF);
        if (count < 0)
            appf /= (float)(1 << (-count));
        else
            appf *= (float)(1 << count);
        appw = f2u(appf);
        *fov = 0;
        *fcy = 0;
        *fs = ((appw & 0x80000000u) != 0);
        *fz = (appw == 0);
        res = appw;
        break;
    }

    case FP_ADDF:
        appf = u2f(ub) + u2f(ua);
        appw = f2u(appf);
        *fov = 0;
        *fcy = 0;
        *fs = ((appw & 0x80000000u) != 0);
        *fz = (appw == 0);
        res = appw;
        break;

    case FP_SUBF:
        // op2 - op1
        appf = u2f(ub) - u2f(ua);
        appw = f2u(appf);
        *fov = 0;
        *fcy = 0;
        *fs = ((appw & 0x80000000u) != 0);
        *fz = (appw == 0);
        res = appw;
        break;

    case FP_MULF:
        appf = u2f(ub) * u2f(ua);
        appw = f2u(appf);
        *fov = 0;
        *fcy = 0;
        *fs = ((appw & 0x80000000u) != 0);
        *fz = (appw == 0);
        res = appw;
        break;

    case FP_DIVF:
        appf = u2f(ub) / u2f(ua);
        appw = f2u(appf);
        *fov = 0;
        *fcy = 0;
        *fs = ((appw & 0x80000000u) != 0);
        *fz = (appw == 0);
        res = appw;
        break;

    case FP_CVTWS: {
        // int32 -> float32
        float val = (float)(int32_t)ua;
        res = f2u(val);
        *fov = 0;
        *fcy = (val < 0.0f);
        *fs = ((res & 0x80000000u) != 0);
        *fz = (val == 0.0f);
        break;
    }

    case FP_CVTSW: {
        // float32 -> int32
        float val = u2f(ua);
        switch (rounding & 7) {
        case 0: val = roundf(val); break;
        case 1: val = floorf(val); break;
        case 2: val = ceilf(val); break;
        default: val = truncf(val); break;
        }
        res = (uint32_t)(int64_t)val;
        *fs = ((res & 0x80000000u) != 0);
        *fov = (*fs && val >= 0.0f) || (!*fs && val <= -1.0f);
        *fz = (res == 0);
        break;
    }

    default:
        res = 0;
        break;
    }

    *result = (int)res;
}
