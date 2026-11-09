# op1, op2, op3 and q_mul: hand-written RV32I.
#
# uint32_t op1_asm(uint32_t a, uint32_t b, int *n)   a0, a1, a2 -> a0
# uint32_t op2_asm(uint32_t a, uint32_t b)           a0, a1 -> a0
# uint32_t op3_asm(uint32_t a, uint32_t b)           a0, a1 -> a0
# int32_t  q_mul_asm(int32_t a, int32_t b)           a0, a1 -> a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. q_mul forms a 64-bit product in a register pair. Tests:
# tests/tfixed.c.
#
# rv32emu retires one instruction per cycle and has no branch penalty, so the
# code minimizes the instructions executed. All four are leaf functions that
# use only caller-saved registers, so none needs a stack frame.

    .text

# op1: the bitwise adder. A pass is sum = a ^ b, carry = (a & b) << 1, until
# the carry is zero: five instructions, the counter and the loop branch
# included. Unrolling by two would save one instruction every two passes for
# 28 more bytes, and the benchmark averages fewer than three passes.
#
# Registers: a0 = sum, a1 = carry, a2 = n, a3 = passes, t0 = scratch.
    .globl  op1_asm
    .type   op1_asm, @function
    .align  2
op1_asm:
    li      a3, 0                   # a3 = passes
    beqz    a1, .Lop1_store
.Lop1_pass:
    and     t0, a0, a1
    xor     a0, a0, a1
    slli    a1, t0, 1
    addi    a3, a3, 1
    bnez    a1, .Lop1_pass
.Lop1_store:
    sw      a3, 0(a2)
    ret
    .size   op1_asm, .-op1_asm

# op2: a - b. The bitwise model op1(a, op1(~b, 1)) is what sub does in one.
#
# Registers: a0 = a, then the result, a1 = b.
    .globl  op2_asm
    .type   op2_asm, @function
    .align  2
op2_asm:
    sub     a0, a0, a1
    ret
    .size   op2_asm, .-op2_asm

# op3: floor((a + b) / 2) = (a & b) + ((a ^ b) >> 1), with no 33-bit sum.
#
# Registers: a0 = a, then the result, a1 = b, t0 = a & b.
    .globl  op3_asm
    .type   op3_asm, @function
    .align  2
op3_asm:
    and     t0, a0, a1
    xor     a0, a0, a1
    srli    a0, a0, 1
    add     a0, a0, t0
    ret
    .size   op3_asm, .-op3_asm

# q_mul: Q11.20 product, rounded half up, wrapping.
#
# The magnitudes are multiplied as unsigned numbers, the 64-bit product is
# negated when the signs differ, and the result is bits 20..51 plus bit 19:
# adding 2^19 carries into bit 20 exactly when bit 19 is set.
#
# The multiply is shift and add over the bits of the smaller magnitude m, from
# the top down: each set bit i adds M << i to the product. The loop ends when
# the bits left in m are zero, so trailing zeros cost nothing (1.0 is 2^20 in
# Q11.20), and a binary search skips the leading zeros first. The top bit is
# tested by its sign, and M << i is built only for a set bit: the low word is
# M << i and the high word (M >> 1) >> (31 - i), which is zero for i = 0.
#
# Registers: a0 = M, the larger magnitude, a1 = m, a2:a3 = product (lo:hi),
# a4 = i, a5 = sign of the product (bit 31), t2 = M >> 1, t0, t1 = scratch.
    .globl  q_mul_asm
    .type   q_mul_asm, @function
    .align  2
q_mul_asm:
    xor     a5, a0, a1              # bit 31: the signs differ
    srai    t0, a0, 31
    xor     a0, a0, t0
    sub     a0, a0, t0              # |a|, 2^31 for INT32_MIN as unsigned
    srai    t0, a1, 31
    xor     a1, a1, t0
    sub     a1, a1, t0              # |b|
    bgeu    a0, a1, 1f              # make m the smaller one
    mv      t0, a0
    mv      a0, a1
    mv      a1, t0
1:
    beqz    a1, .Lq_zero
    li      a2, 0
    li      a3, 0
    li      a4, 31                  # bit 31 of m has weight 2^i
    srli    t2, a0, 1
    srli    t0, a1, 16              # skip leading zeros: 16, 8, 4, 2
    bnez    t0, 2f
    slli    a1, a1, 16
    addi    a4, a4, -16
2:
    srli    t0, a1, 24
    bnez    t0, 3f
    slli    a1, a1, 8
    addi    a4, a4, -8
3:
    srli    t0, a1, 28
    bnez    t0, 4f
    slli    a1, a1, 4
    addi    a4, a4, -4
4:
    srli    t0, a1, 30
    bnez    t0, .Lq_bit
    slli    a1, a1, 2
    addi    a4, a4, -2
.Lq_bit:
    bgez    a1, 5f                  # bit i of m clear
    sll     t0, a0, a4              # low word of M << i
    add     a2, a2, t0
    sltu    t0, a2, t0              # carry out of the low word
    add     a3, a3, t0
    xori    t1, a4, -1              # 31 - i as a shift amount
    srl     t1, t2, t1              # high word of M << i
    add     a3, a3, t1
5:
    slli    a1, a1, 1
    addi    a4, a4, -1
    bnez    a1, .Lq_bit
    bgez    a5, 6f                  # signs differ: negate the product
    neg     a2, a2
    seqz    t0, a2                  # ~hi + 1 carries only when lo is 0
    not     a3, a3
    add     a3, a3, t0
6:
    srli    t0, a2, 20              # bits 20..51
    slli    t1, a3, 12
    or      a0, t0, t1
    srli    t0, a2, 19              # plus bit 19, the rounding
    andi    t0, t0, 1
    add     a0, a0, t0
    ret
.Lq_zero:                           # m = 0: the product is 0
    li      a0, 0
    ret
    .size   q_mul_asm, .-q_mul_asm
