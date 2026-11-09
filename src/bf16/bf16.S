# BFloat16 routines: hand-written RV32I.
#
# uint16_t bf16_from_f32_asm(uint32_t f32bits)   a0 -> a0
# uint16_t bf16_mul_asm(uint16_t a, uint16_t b)  a0, a1 -> a0
# uint16_t bf16_sqrt_asm(uint16_t a)             a0 -> a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tbf16.c.
#
# rv32emu retires one instruction per cycle and has no branch penalty, so the
# code minimizes the instructions executed. All three are leaf functions that
# use only caller-saved registers, so none needs a stack frame. The uint16_t
# arguments arrive zero-extended, and every result is below 2^16.

    .text

# from_f32: add 0x7FFF plus bit 16, the lowest kept bit, and keep the top
# half: round to nearest, ties to even. An exponent field of 0xFF (Inf, NaN)
# skips the rounding, which could carry out of the exponent.
#
# Registers: a0 = f32bits, then the result, t0, t1 = scratch.
    .globl  bf16_from_f32_asm
    .type   bf16_from_f32_asm, @function
    .align  2
bf16_from_f32_asm:
    slli    t0, a0, 1               # drop the sign: exponent at bits 31..24
    lui     t1, 0xFF000
    bgeu    t0, t1, .Lf_special
    srli    t0, a0, 16
    andi    t0, t0, 1               # bit 16: 1 when the kept half is odd
    add     a0, a0, t0
    lui     t1, 8
    addi    t1, t1, -1              # 0x7FFF
    add     a0, a0, t1
    srli    a0, a0, 16
    ret
.Lf_special:
    srli    a0, a0, 16
    ret
    .size   bf16_from_f32_asm, .-bf16_from_f32_asm

# mul: the sign is the XOR of the signs, the exponent is ea + eb - 127, and
# the significands, 1.f scaled by 128, multiply to [2^14, 2^16). A product that
# reaches bit 15 is shifted one more bit and raises the exponent. The fraction
# is truncated.
#
# The common case, both exponent fields in [1, 254], is tested first. The
# multiply is shift and add over the 7 fraction bits of mb, from the top down,
# on top of ma << 7 for the hidden one; the loop ends when the bits left are
# zero, so a short fraction (1.0, 1.5, 3.0) costs only its set bits.
#
# The result is ((E - 1) << 7) + p, where p in [128, 256) is the significand:
# its hidden one adds the missing 1 to the exponent, so no mask is needed.
#
# Registers: t0 = exponent of a, then E - 1, t1 = exponent of b, a2 = ma,
# a3 = fraction bits of mb left to use (at the top), a4 = product,
# a5 = sign of the result (bit 15), t3 = 254.
    .globl  bf16_mul_asm
    .type   bf16_mul_asm, @function
    .align  2
bf16_mul_asm:
    xor     a5, a0, a1
    srli    a5, a5, 15
    slli    a5, a5, 15              # sign of the product
    srli    t0, a0, 7
    andi    t0, t0, 0xFF            # ea
    srli    t1, a1, 7
    andi    t1, t1, 0xFF            # eb
    li      t3, 254
    addi    t2, t0, -1
    bgeu    t2, t3, .Lm_edge        # ea is 0 or 0xFF
    addi    t2, t1, -1
    bgeu    t2, t3, .Lm_edge        # eb is 0 or 0xFF
    andi    a2, a0, 0x7F
    ori     a2, a2, 0x80            # ma, hidden one included
    slli    a3, a1, 25              # fraction of b at bits 31..25
.Lm_mul:
    add     t0, t0, t1
    addi    t0, t0, -128            # E - 1, before the renormalization
    slli    a4, a2, 7               # the hidden one of mb
    beqz    a3, 2f
    slli    a2, a2, 6               # ma << i for the bit at the top, i = 6
1:
    bgez    a3, 3f                  # bit i clear
    add     a4, a4, a2
3:
    srli    a2, a2, 1
    slli    a3, a3, 1
    bnez    a3, 1b
2:
    srli    t1, a4, 15              # 1 when the product reached bit 15
    add     t0, t0, t1
    addi    t1, t1, 7
    srl     a4, a4, t1              # p in [128, 256)
    bgeu    t0, t3, .Lm_range       # E - 1 outside [0, 253]
    slli    t0, t0, 7
    add     a0, t0, a4
    or      a0, a0, a5
    ret

.Lm_range:
    bgez    t0, .Lm_inf             # E >= 255
    li      t1, -7
    blt     t0, t1, .Lm_zero        # E < -6
    andi    a4, a4, 0x7F            # the contract shifts the bare fraction
    neg     t0, t0                  # 1 - E
    srl     a4, a4, t0
    or      a0, a4, a5
    ret

# An exponent field is 0 or 0xFF. In the contract's order: a NaN or Inf a,
# then a NaN or Inf b, then a zero, then denormals, which are normalized and
# rejoin the multiply. A denormal with its leading one at bit 7 - n has the
# exponent 1 - n.
.Lm_edge:
    andi    a2, a0, 0x7F            # fraction of a
    andi    a3, a1, 0x7F            # fraction of b
    li      t4, 0xFF
    bne     t0, t4, 1f
    bnez    a2, .Lm_ret             # NaN a, unchanged
    slli    t2, a1, 17              # b without its sign
    bnez    t2, .Lm_inf
    j       .Lm_nan                 # Inf times zero
1:
    bne     t1, t4, 2f
    bnez    a3, .Lm_ret_b           # NaN b, unchanged
    slli    t2, a0, 17
    bnez    t2, .Lm_inf
.Lm_nan:
    li      a0, 0x7FC0
    ret
2:
    slli    t2, a0, 17
    beqz    t2, .Lm_zero
    slli    t2, a1, 17
    beqz    t2, .Lm_zero
    beqz    t0, 3f
    ori     a2, a2, 0x80            # a normal
    j       4f
3:
    li      t0, 1                   # a denormal
    slli    a2, a2, 24
5:
    slli    a2, a2, 1
    addi    t0, t0, -1
    bgez    a2, 5b
    srli    a2, a2, 24
4:
    beqz    t1, 6f
    slli    a3, a3, 25              # b normal
    j       .Lm_mul
6:
    li      t1, 1                   # b denormal
    slli    a3, a3, 24
7:
    slli    a3, a3, 1
    addi    t1, t1, -1
    bgez    a3, 7b
    slli    a3, a3, 1               # drop the leading one
    j       .Lm_mul

.Lm_inf:
    li      a0, 0x7F80
    or      a0, a0, a5
    ret
.Lm_zero:
    mv      a0, a5
.Lm_ret:
    ret
.Lm_ret_b:
    mv      a0, a1
    ret
    .size   bf16_mul_asm, .-bf16_mul_asm

# sqrt: for a positive normal with exponent field x, sqrt(2^e m) with
# e = x - 127 is 2^(e/2) sqrt(m), doubling m when e is odd (x even). The
# contract's root is the largest r with r * r / 128 <= m, truncating, which is
# r * r < 128 (m + 1), so r = isqrt(N) with N = 128 m + 127.
#
# N lies in [16511, 65535], so r lies in [128, 255]: the renormalization and
# the Inf and zero checks of the C version can never fire. The new exponent
# field is (x + 127) / 2, rounded down, and the result is (that - 1) << 7 plus
# r, whose top bit restores the 1.
#
# isqrt is the digit-by-digit method: bit runs over powers of four, res
# collects the root scaled by bit, and N keeps the remainder. N >= 2^14
# settles the first digit, which leaves 7.
#
# Registers: t0 = exponent field, t1 = N, then the remainder, a4 = res,
# a5 = bit, t2, t3 = scratch.
    .globl  bf16_sqrt_asm
    .type   bf16_sqrt_asm, @function
    .align  2
bf16_sqrt_asm:
    srli    t0, a0, 7               # sign and exponent
    addi    t1, t0, -1
    li      t2, 254
    bgeu    t1, t2, .Ls_edge        # not a positive normal
    andi    t1, a0, 0x7F
    ori     t1, t1, 0x80            # m in [128, 256)
    andi    t2, t0, 1               # x odd: e even, m stays
    slli    t1, t1, 8
    srl     t1, t1, t2
    ori     t1, t1, 0x7F            # N = 128 m + 127
    lui     a4, 4                   # first digit: res = 2^14
    sub     t1, t1, a4
    lui     a5, 1                   # bit = 2^12
1:
    add     t3, a4, a5
    srli    a4, a4, 1
    bltu    t1, t3, 2f
    sub     t1, t1, t3
    add     a4, a4, a5
2:
    srli    a5, a5, 2
    bnez    a5, 1b
    addi    t0, t0, 125
    srli    t0, t0, 1               # new exponent field - 1
    slli    t0, t0, 7
    add     a0, t0, a4
    ret

# Not a positive normal: +0 and positive denormals give +0, +Inf and +NaN are
# returned unchanged; with the sign set, -0 gives +0, a NaN is returned
# unchanged and everything else, -Inf included, gives the quiet NaN.
.Ls_edge:
    beqz    t0, .Ls_zero
    li      t2, 0xFF
    beq     t0, t2, .Ls_ret
    slli    t1, a0, 17              # without the sign
    beqz    t1, .Ls_zero
    lui     t2, 0xFF000
    bgtu    t1, t2, .Ls_ret         # NaN
    li      a0, 0x7FC0
    ret
.Ls_zero:
    li      a0, 0
.Ls_ret:
    ret
    .size   bf16_sqrt_asm, .-bf16_sqrt_asm
