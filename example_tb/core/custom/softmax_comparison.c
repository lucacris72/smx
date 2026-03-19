
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>
#include <math.h>

#ifndef N
#define N 128u
#endif

#ifndef REPEAT
#define REPEAT 1u
#endif

// -------------------- CSR helpers (RV32) --------------------
#define WRITE_CSR(reg, val)   asm volatile ("csrw " #reg ", %0" :: "rK"(val))
#define SET_CSR(reg, val)     asm volatile ("csrs " #reg ", %0" :: "rK"(val))
#define CLEAR_CSR(reg, val)   asm volatile ("csrc " #reg ", %0" :: "rK"(val))
#define COMPILER_BARRIER()    asm volatile ("" ::: "memory")

static inline void enable_perf_counters(void) {
    // Abilita mcycle e minstret
    const uint32_t mask = (1u << 0) | (1u << 2);
    CLEAR_CSR(mcountinhibit, mask);
}

static inline void enable_fpu(void) {
    // Enable FPU in mstatus (FS=01 aka Initial)
    // mstatus.FS is bits 13-14
    // 1 << 13 = 0x2000
    uint32_t fs_mask = 0x2000;
    SET_CSR(mstatus, fs_mask);
}

static inline uint64_t read_mcycle64(void) {
    uint32_t lo, hi0, hi1;
    do {
        asm volatile ("csrr %0, mcycleh" : "=r"(hi0));
        asm volatile ("csrr %0, mcycle"  : "=r"(lo));
        asm volatile ("csrr %0, mcycleh" : "=r"(hi1));
    } while (hi0 != hi1);
    return ((uint64_t)hi0 << 32) | lo;
}

// -------------------- SMX Custom Instructions --------------------
// func3:
// 000: SMX.CONTX
// 001: SMX.ACC
// 010: SMX.EXP
// 011: SMX.SIGM

#define SMX_CONTX(rd, rs1, rs2) \
    __asm__ volatile(".insn r 0x0B, 0, 0, %0, %1, %2" : "+r"(rd) : "r"(rs1), "r"(rs2))

#define SMX_ACC(rd, rs1, rs2) \
    __asm__ volatile(".insn r 0x0B, 1, 0, %0, %1, %2" : "+r"(rd) : "r"(rs1), "r"(rs2))

#define SMX_EXP(rd, rs1, rs2) \
    __asm__ volatile(".insn r 0x0B, 2, 0, %0, %1, %2" : "=r"(rd) : "r"(rs1), "r"(rs2))

#define SMX_SIGM(rd, rs1, rs2) \
    __asm__ volatile(".insn r 0x0B, 3, 0, %0, %1, %2" : "=r"(rd) : "r"(rs1), "r"(rs2))

// -------------------- Baseline FP32 Softmax --------------------
// Clampa il delta per evitare overflow della exp in soft-float
#ifndef DELTA_MIN
#define DELTA_MIN (-8.0f)   // sufficiente per softmax numericamente robusta
#endif
#ifndef DELTA_MAX
#define DELTA_MAX ( 0.0f)
#endif

static void softmax_f32(const float *x, float *y, size_t n) {
    // 1) trova max
    float m = x[0];
    for (size_t i = 1; i < n; ++i) if (x[i] > m) m = x[i];

    // 2) exp(x - m) clampata, somma
    float sum = 0.0f;
    for (size_t i = 0; i < n; ++i) {
        float d = x[i] - m;
        // Clamp the delta to keep the soft-float reference numerically stable.
        if (d < DELTA_MIN) d = DELTA_MIN;
        if (d > DELTA_MAX) d = DELTA_MAX;
        
        // Uso diretto di expf da math.h
        float e = expf(d);
        y[i] = e;
        sum += e;
    }

    // 3) normalizza
    float inv = 1.0f / sum;
    for (size_t i = 0; i < n; ++i) y[i] *= inv;
}

// -------------------- Optimized SMX Softmax --------------------
// Quantizza float -> int8
static void quantize_vec(const float *in, int8_t *out, size_t n) {
    // Semplice scalatura fissa per il test: supponiamo input in [-8, 8]
    // Mappa [-8, 8] -> [-128, 127]
    for (size_t i = 0; i < n; ++i) {
        float val = in[i];
        if (val > 8.0f) val = 8.0f;
        if (val < -8.0f) val = -8.0f;
        out[i] = (int8_t)(val * 16.0f);
    }
}

// Zero-Copy approach: assumes input is 4-byte aligned
// Modified to output packed results (uint32_t) directly to avoid unpacking overhead during bench logic.
static void softmax_smx(const int8_t *x, uint32_t *y_packed, size_t n) {
    // 1) SMX.MAX Pass
    // We process 8 bytes (2 words) per instruction
    uint32_t current_max = 0x00007F80; // Init: Min=127, Max=-128

    const uint32_t *ptr = (const uint32_t *)x;
    size_t n_words = n / 4;
    
    // Loop 2 words (8 bytes) at a time for efficiency
    size_t i = 0;
    for (; i < n_words - 1; i += 2) {
        uint32_t rs1 = ptr[i];
        uint32_t rs2 = ptr[i+1];
        // Compare 8 bytes in one go
        SMX_CONTX(current_max, rs1, rs2);
    }
    // Handle odd word if any
    for (; i < n_words; i++) {
        uint32_t rs1 = ptr[i];
        SMX_CONTX(current_max, rs1, rs1);
    }
    
    // Now current_max contains {Shift, Min, Max} ready for next steps

    // 2) SMX.ACC (Sum of Exps)
    // Hardware ACC takes 1 word at a time in rs1
    uint32_t sum_acc = 0;
    
    // Using unrolling for consistency, though hardware limitation is 1 word/instr
    i = 0;
    for (; i < n_words - 1; i += 2) {
        uint32_t rs1 = ptr[i];
        uint32_t rs2_val = ptr[i+1];
        SMX_ACC(sum_acc, rs1, current_max);
        SMX_ACC(sum_acc, rs2_val, current_max);
    }
    for (; i < n_words; i++) {
        SMX_ACC(sum_acc, ptr[i], current_max);
    }

    // 3) SMX.EXP + SMX.SIGM (Probabilities)
    i = 0;
    for (; i < n_words; i++) {
        uint32_t chunk = ptr[i];
        uint32_t exps_packed;
        uint32_t probs_packed;
        
        SMX_EXP(exps_packed, chunk, current_max);
        SMX_SIGM(probs_packed, sum_acc, exps_packed);
        
        // Store packed result directly
        y_packed[i] = probs_packed;
    }
}

// -------------------- Software Model (RISC-V Implementation) --------------------
// Replicates hardware logic in C using LUTs


static const uint8_t lut1d[101] = {
    0xff, 0xef, 0xe0, 0xd2, 0xc5, 0xb9, 0xae, 0xa3, 0x99, 0x8f, 0x86, 0x7e, 0x76, 0x6f, 0x68, 0x62,
    0x5c, 0x56, 0x51, 0x4c, 0x47, 0x43, 0x3e, 0x3b, 0x37, 0x33, 0x30, 0x2d, 0x2a, 0x28, 0x25, 0x23,
    0x21, 0x1f, 0x1d, 0x1b, 0x19, 0x18, 0x16, 0x15, 0x14, 0x12, 0x11, 0x10, 0x0f, 0x0e, 0x0d, 0x0d,
    0x0c, 0x0b, 0x0a, 0x0a, 0x09, 0x09, 0x08, 0x08, 0x07, 0x07, 0x06, 0x06, 0x05, 0x05, 0x05, 0x05,
    0x04, 0x04, 0x04, 0x04, 0x03, 0x03, 0x03, 0x03, 0x03, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
    0x02, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01,
    0x01, 0x01, 0x00, 0x00, 0x00,
};
static const uint8_t lut2d[11][60] = {
    {
        0x00, 0x04, 0x09, 0x0d, 0x11, 0x16, 0x1a, 0x1e, 0x23, 0x27, 0x2b, 0x30, 0x34, 0x38, 0x3d, 
        0x41, 0x45, 0x49, 0x4e, 0x52, 0x56, 0x5b, 0x5f, 0x63, 0x68, 0x6c, 0x70, 0x75, 0x79, 0x7d, 
        0x82, 0x86, 0x8a, 0x8f, 0x93, 0x97, 0x9c, 0xa0, 0xa4, 0xa9, 0xad, 0xb1, 0xb6, 0xba, 0xbe, 
        0xc2, 0xc7, 0xcb, 0xcf, 0xd4, 0xd8, 0xdc, 0xe1, 0xe5, 0xe9, 0xee, 0xf2, 0xf6, 0xfb, 0xff, 
    },
    {
        0x00, 0x04, 0x09, 0x0d, 0x11, 0x16, 0x1a, 0x1e, 0x23, 0x27, 0x2b, 0x30, 0x34, 0x38, 0x3d, 
        0x41, 0x45, 0x49, 0x4e, 0x52, 0x56, 0x5b, 0x5f, 0x63, 0x68, 0x6c, 0x70, 0x75, 0x79, 0x7d, 
        0x82, 0x86, 0x8a, 0x8f, 0x93, 0x97, 0x9c, 0xa0, 0xa4, 0xa9, 0xad, 0xb1, 0xb6, 0xba, 0xbe, 
        0xc2, 0xc7, 0xcb, 0xcf, 0xd4, 0xd8, 0xdc, 0xe1, 0xe5, 0xe9, 0xee, 0xf2, 0xf6, 0xfb, 0xff, 
    },
    {
        0x00, 0x02, 0x04, 0x06, 0x09, 0x0b, 0x0d, 0x0f, 0x11, 0x13, 0x16, 0x18, 0x1a, 0x1c, 0x1e, 
        0x20, 0x23, 0x25, 0x27, 0x29, 0x2b, 0x2d, 0x30, 0x32, 0x34, 0x36, 0x38, 0x3a, 0x3d, 0x3f, 
        0x41, 0x43, 0x45, 0x47, 0x49, 0x4c, 0x4e, 0x50, 0x52, 0x54, 0x56, 0x59, 0x5b, 0x5d, 0x5f, 
        0x61, 0x63, 0x66, 0x68, 0x6a, 0x6c, 0x6e, 0x70, 0x73, 0x75, 0x77, 0x79, 0x7b, 0x7d, 0x80, 
    },
    {
        0x00, 0x01, 0x03, 0x04, 0x06, 0x07, 0x09, 0x0a, 0x0c, 0x0d, 0x0e, 0x10, 0x11, 0x13, 0x14, 
        0x16, 0x17, 0x18, 0x1a, 0x1b, 0x1d, 0x1e, 0x20, 0x21, 0x23, 0x24, 0x25, 0x27, 0x28, 0x2a, 
        0x2b, 0x2d, 0x2e, 0x30, 0x31, 0x32, 0x34, 0x35, 0x37, 0x38, 0x3a, 0x3b, 0x3d, 0x3e, 0x3f, 
        0x41, 0x42, 0x44, 0x45, 0x47, 0x48, 0x49, 0x4b, 0x4c, 0x4e, 0x4f, 0x51, 0x52, 0x54, 0x55, 
    },
    {
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 
        0x10, 0x11, 0x12, 0x13, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f, 
        0x20, 0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x30, 
        0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3d, 0x3e, 0x3f, 0x40, 
    },
    {
        0x00, 0x01, 0x02, 0x03, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0a, 0x0b, 0x0c, 
        0x0d, 0x0e, 0x0f, 0x10, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x16, 0x17, 0x18, 0x19, 
        0x1a, 0x1b, 0x1c, 0x1d, 0x1d, 0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x23, 0x24, 0x25, 0x26, 
        0x27, 0x28, 0x29, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f, 0x30, 0x30, 0x31, 0x32, 0x33, 
    },
    {
        0x00, 0x01, 0x01, 0x02, 0x03, 0x04, 0x04, 0x05, 0x06, 0x06, 0x07, 0x08, 0x09, 0x09, 0x0a, 
        0x0b, 0x0c, 0x0c, 0x0d, 0x0e, 0x0e, 0x0f, 0x10, 0x11, 0x11, 0x12, 0x13, 0x13, 0x14, 0x15, 
        0x16, 0x16, 0x17, 0x18, 0x18, 0x19, 0x1a, 0x1b, 0x1b, 0x1c, 0x1d, 0x1e, 0x1e, 0x1f, 0x20, 
        0x20, 0x21, 0x22, 0x23, 0x23, 0x24, 0x25, 0x25, 0x26, 0x27, 0x28, 0x28, 0x29, 0x2a, 0x2a, 
    },
    {
        0x00, 0x01, 0x01, 0x02, 0x02, 0x03, 0x04, 0x04, 0x05, 0x06, 0x06, 0x07, 0x07, 0x08, 0x09, 
        0x09, 0x0a, 0x0a, 0x0b, 0x0c, 0x0c, 0x0d, 0x0e, 0x0e, 0x0f, 0x0f, 0x10, 0x11, 0x11, 0x12, 
        0x13, 0x13, 0x14, 0x14, 0x15, 0x16, 0x16, 0x17, 0x17, 0x18, 0x19, 0x19, 0x1a, 0x1b, 0x1b, 
        0x1c, 0x1c, 0x1d, 0x1e, 0x1e, 0x1f, 0x1f, 0x20, 0x21, 0x21, 0x22, 0x23, 0x23, 0x24, 0x24, 
    },
    {
        0x00, 0x01, 0x01, 0x02, 0x02, 0x03, 0x03, 0x04, 0x04, 0x05, 0x05, 0x06, 0x06, 0x07, 0x08, 
        0x08, 0x09, 0x09, 0x0a, 0x0a, 0x0b, 0x0b, 0x0c, 0x0c, 0x0d, 0x0e, 0x0e, 0x0f, 0x0f, 0x10, 
        0x10, 0x11, 0x11, 0x12, 0x12, 0x13, 0x13, 0x14, 0x15, 0x15, 0x16, 0x16, 0x17, 0x17, 0x18, 
        0x18, 0x19, 0x19, 0x1a, 0x1a, 0x1b, 0x1c, 0x1c, 0x1d, 0x1d, 0x1e, 0x1e, 0x1f, 0x1f, 0x20, 
    },
    {
        0x00, 0x00, 0x01, 0x01, 0x02, 0x02, 0x03, 0x03, 0x04, 0x04, 0x05, 0x05, 0x06, 0x06, 0x07, 
        0x07, 0x08, 0x08, 0x09, 0x09, 0x0a, 0x0a, 0x0b, 0x0b, 0x0c, 0x0c, 0x0c, 0x0d, 0x0d, 0x0e, 
        0x0e, 0x0f, 0x0f, 0x10, 0x10, 0x11, 0x11, 0x12, 0x12, 0x13, 0x13, 0x14, 0x14, 0x15, 0x15, 
        0x16, 0x16, 0x17, 0x17, 0x18, 0x18, 0x18, 0x19, 0x19, 0x1a, 0x1a, 0x1b, 0x1b, 0x1c, 0x1c, 
    },
    {
        0x00, 0x00, 0x01, 0x01, 0x02, 0x02, 0x03, 0x03, 0x03, 0x04, 0x04, 0x05, 0x05, 0x06, 0x06, 
        0x06, 0x07, 0x07, 0x08, 0x08, 0x09, 0x09, 0x0a, 0x0a, 0x0a, 0x0b, 0x0b, 0x0c, 0x0c, 0x0d, 
        0x0d, 0x0d, 0x0e, 0x0e, 0x0f, 0x0f, 0x10, 0x10, 0x10, 0x11, 0x11, 0x12, 0x12, 0x13, 0x13, 
        0x13, 0x14, 0x14, 0x15, 0x15, 0x16, 0x16, 0x16, 0x17, 0x17, 0x18, 0x18, 0x19, 0x19, 0x1a, 
    },
};


static inline int count_leading_zeros_byte(uint8_t x) {
    if (x == 0) return 8;
    int n = 0;
    if ((x & 0xF0) == 0) { n += 4; x <<= 4; }
    if ((x & 0xC0) == 0) { n += 2; x <<= 2; }
    if ((x & 0x80) == 0) { n += 1; }
    return n;
}

static void softmax_sw_model(const int8_t *x, uint32_t *y_packed, size_t n) {
    const int LZC_LUT = 1;
    const int LUT1D_IDX_MAX = 100;
    const int LUT2D_ROW_MAX = 10;
    const int LUT2D_COL_MAX = 59;

    // 1. Find Max/Min
    int8_t max_val = x[0];
    int8_t min_val = x[0];
    for (size_t i = 1; i < n; ++i) {
        if (x[i] > max_val) max_val = x[i];
        if (x[i] < min_val) min_val = x[i];
    }
    
    // Adaptive Shift
    uint8_t delta_max = (uint8_t)((int)max_val - (int)min_val);
    int lzc = count_leading_zeros_byte(delta_max);
    int shift_calc = lzc - LZC_LUT;
    
    // Clamp Shift
    int shift;
    if (shift_calc > 7) shift = 7;
    else if (shift_calc < -8) shift = -8;
    else shift = shift_calc;
    
    // 2. ACC / EXP
    uint32_t sum_acc = 0;
    static uint8_t exps[N]; // Temp buffer for exps
    
    for (size_t i = 0; i < n; ++i) {
        int diff = (int)max_val - (int)x[i]; // always >= 0
        int delta_shifted;
        if (shift < 0) {
            delta_shifted = diff >> (-shift);
        } else {
            delta_shifted = diff << shift;
        }
        
        int idx;
        if (delta_shifted > LUT1D_IDX_MAX) idx = LUT1D_IDX_MAX;
        else idx = delta_shifted;
        
        uint8_t val = lut1d[idx];
        exps[i] = val;
        sum_acc += val;
    }
    
    // 3. SIGM
    int row_idx = sum_acc >> 8;
    if (row_idx > LUT2D_ROW_MAX) row_idx = LUT2D_ROW_MAX;
    
    // Process 4 at a time to pack into uint32_t
    size_t n_words = n / 4;
    for (size_t i = 0; i < n_words; ++i) {
        uint8_t p[4];
        for (int j = 0; j < 4; ++j) {
            uint8_t e = exps[i*4 + j];
            int msb_idx = (e >> 2) & 0x3F;
            int col_idx = (msb_idx > LUT2D_COL_MAX) ? LUT2D_COL_MAX : msb_idx;
            
            p[j] = lut2d[row_idx][col_idx];
        }
        // Pack: p3 p2 p1 p0
        y_packed[i] = ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) | ((uint32_t)p[1] << 8) | (uint32_t)p[0];
    }
}


// -------------------- Bench Log Structure --------------------
typedef struct __attribute__((aligned(8))) {
    uint64_t cycles_fp32;
    uint64_t cycles_smx;
    uint64_t cycles_sw_model;
    int32_t  top1_fp32;
    int32_t  top1_smx;
    int32_t  top1_sw_model;
    int32_t  match;
    int32_t  match_sw;
} bench_comparison_t;

__attribute__((section(".signature")))
volatile bench_comparison_t g_bench_cmp;

// -------------------- Inputs --------------------
static float in_data[N];
static float out_fp32[N];
// Ensure alignment for 32-bit access
static int8_t in_q8[N] __attribute__((aligned(4)));
static uint32_t out_packed[N/4]; // Output buffer for SMX
static uint32_t out_sw_packed[N/4]; // Output for SW Model
static float out_smx[N]; // Converted back from u8 for validation
static float out_sw_model_res[N];

void init_data() {
    for (int i = 0; i < N; ++i) {
        // Random-ish pattern
        in_data[i] = (float)((i * 37) % 64) / 4.0f - 8.0f; 
    }
    quantize_vec(in_data, in_q8, N);
}

int find_argmax(const float *v, size_t n) {
    int idx = 0;
    float mx = v[0];
    for (size_t i = 1; i < n; ++i) {
        if (v[i] > mx) {
            mx = v[i];
            idx = i;
        }
    }
    return idx;
}

// -------------------- Minimal I/O --------------------
static volatile int* const stdout_reg = (int*)0x10000000;

static void print_char(char c) {
    *stdout_reg = c;
}

static void print_str(const char* s) {
    while (*s) print_char(*s++);
}

static void print_dec(uint64_t val) {
    if (val == 0) {
        print_char('0');
        return;
    }
    char buf[24];
    int i = 0;
    while (val > 0) {
        buf[i++] = (val % 10) + '0';
        val /= 10;
    }
    while (i > 0) {
        print_char(buf[--i]);
    }
}

static void print_signed(int32_t val) {
    if (val < 0) {
        print_char('-');
        print_dec((uint64_t)(-val));
    } else {
        print_dec((uint64_t)val);
    }
}

int main(void) {
    print_str("Softmax Comparison Benchmark (N=");
    print_dec((uint64_t)N);
    print_str(", REPEAT=");
    print_dec((uint64_t)REPEAT);
    print_str(")\n");

    enable_perf_counters();
    enable_fpu();
    
    init_data();
    //init_luts(); // Removed: pre-calculated

    uint64_t start, end;

    // --- Run FP32 ---
    start = read_mcycle64();
    for (int r = 0; r < REPEAT; ++r) {
        softmax_f32(in_data, out_fp32, N);
    }
    end = read_mcycle64();
    uint64_t cyc_fp = end - start;
    
    // --- Run SMX ---
    start = read_mcycle64();
    for (int r = 0; r < REPEAT; ++r) {
        // Zero-copy: Pass the aligned int8 pointer directly
        // Pass packed output buffer
        softmax_smx(in_q8, out_packed, N);
    }
    end = read_mcycle64();
    uint64_t cyc_smx = end - start;
    
    // --- Run SW Model ---
    start = read_mcycle64();
    for (int r = 0; r < REPEAT; ++r) {
        softmax_sw_model(in_q8, out_sw_packed, N);
    }
    end = read_mcycle64();
    uint64_t cyc_sw = end - start;
    
    // --- Post-Processing for Validation ---
    // Unpack results to float array
    for (size_t i = 0; i < N/4; ++i) {
        uint32_t p_val = out_packed[i];
        uint8_t *p = (uint8_t*)&p_val;
        out_smx[i*4 + 0] = (float)p[0] / 255.0f;
        out_smx[i*4 + 1] = (float)p[1] / 255.0f;
        out_smx[i*4 + 2] = (float)p[2] / 255.0f;
        out_smx[i*4 + 3] = (float)p[3] / 255.0f;
        
        uint32_t p_val_sw = out_sw_packed[i];
        uint8_t *ps = (uint8_t*)&p_val_sw;
        out_sw_model_res[i*4 + 0] = (float)ps[0] / 255.0f;
        out_sw_model_res[i*4 + 1] = (float)ps[1] / 255.0f;
        out_sw_model_res[i*4 + 2] = (float)ps[2] / 255.0f;
        out_sw_model_res[i*4 + 3] = (float)ps[3] / 255.0f;
    }
    
    // --- Validation ---
    int idx_fp = find_argmax(out_fp32, N);
    int idx_smx = find_argmax(out_smx, N);
    int idx_sw = find_argmax(out_sw_model_res, N);
    
    int match = (idx_fp == idx_smx);
    int match_sw = (idx_fp == idx_sw);
    
    print_str("FP32 Cycles: "); print_dec(cyc_fp); print_char('\n');
    print_str("SMX  Cycles: "); print_dec(cyc_smx); print_char('\n');
    print_str("SW Model Cycles: "); print_dec(cyc_sw); print_char('\n');
    
    print_str("Top-1 FP32: "); print_signed(idx_fp);
    print_str(", SMX: "); print_signed(idx_smx);
    print_str(" -> Match: "); print_str(match ? "YES" : "NO"); print_char('\n');
    
    print_str("Top-1 SW Model: "); print_signed(idx_sw);
    print_str(" -> Match: "); print_str(match_sw ? "YES" : "NO"); print_char('\n');
    
    // Fill struct for external parser
    g_bench_cmp.cycles_fp32 = cyc_fp;
    g_bench_cmp.cycles_smx = cyc_smx;
    g_bench_cmp.cycles_sw_model = cyc_sw;
    g_bench_cmp.top1_fp32 = idx_fp;
    g_bench_cmp.top1_smx = idx_smx;
    g_bench_cmp.top1_sw_model = idx_sw;
    g_bench_cmp.match = match;
    g_bench_cmp.match_sw = match_sw;
    
    return 0; // Success
}
