# gcd_u32_asm: binary GCD, hand-written RV32I.
#
# uint32_t gcd_u32_asm(uint32_t a, uint32_t b)   a in a0, b in a1, result in a0
#
# RV32I and Zicsr only: no mul, div, rem, no floating point, no compressed
# instructions. Tests: tests/tgcd.c.
#
# The algorithm is that of gcd.c: count the shared power of two k, make both
# operands odd, then subtract the smaller from the larger and strip the factors
# of two of the difference until the two are equal.
#
# rv32emu retires one instruction per cycle and has no branch penalty, so the
# code minimizes the instructions executed, not the branches taken, and stays
# small: no table, no stack frame, 140 bytes in all.
#   - two blocks replace the swap: .Lx runs while b >= a and .Ly while a > b,
#     each ending in the compare that picks the next block;
#   - the factors of two come off one bit per pass, three instructions each;
#     a difference of two odd numbers is even, so a pass shifts before it
#     tests, and half of all differences stop after the first bit;
#   - an even operand at entry jumps into the same strip loop, so there is no
#     separate path for it.
#
# Registers: a0 = a, a1 = b, t1 = scratch. On the rare path where both
# operands are even, also t0 = scratch, a2 = k and a3 = return address.

    .text

    .globl  gcd_u32_asm
    .type   gcd_u32_asm, @function
    .align  2
gcd_u32_asm:
    beqz    a0, .Lret_b             # gcd(0, b) = b
    beqz    a1, .Lret               # gcd(a, 0) = a
.Lnot_both_even:                    # a, b nonzero; reentered with k > 0
    andi    t1, a0, 1
    beqz    t1, .La_even
    andi    t1, a1, 1
    beqz    t1, .Lstrip_b           # a odd, b even: no shared two
    bltu    a1, a0, .Ly

.Lx:                                # b >= a, both odd
    sub     a1, a1, a0              # odd - odd: even, or zero when equal
    beqz    a1, .Lret               # b == a: a is the odd part of the gcd
.Lstrip_b:                          # b is even and nonzero: shift, then test
    srli    a1, a1, 1
    andi    t1, a1, 1
    beqz    t1, .Lstrip_b
    bgeu    a1, a0, .Lx
.Ly:                                # a > b, both odd, so a - b > 0
    sub     a0, a0, a1
.Lstrip_a:                          # a is even and nonzero: shift, then test
    srli    a0, a0, 1
    andi    t1, a0, 1
    beqz    t1, .Lstrip_a
    bltu    a1, a0, .Ly
    j       .Lx

.Lret:
    ret
.Lret_b:
    mv      a0, a1
    ret

.La_even:
    andi    t1, a1, 1
    bnez    t1, .Lstrip_a           # a even, b odd: no shared two

# Both even (one call in four at random, and then k is small): count
# k = ctz(a | b) one bit per pass while shifting both, run the odd part as a
# local call that returns here, and shift the result back. After the shift
# one operand is odd, so the call never comes back to this path.
    li      a2, 0
1:
    srli    a0, a0, 1
    srli    a1, a1, 1
    addi    a2, a2, 1
    or      t0, a0, a1
    andi    t0, t0, 1
    beqz    t0, 1b
    mv      a3, ra
    jal     .Lnot_both_even         # a0 = gcd(a >> k, b >> k)
    sll     a0, a0, a2
    jr      a3
    .size   gcd_u32_asm, .-gcd_u32_asm
