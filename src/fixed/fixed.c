#include "fixed.h"

/* Addition from logic. a ^ b is the sum without carries and (a & b) << 1 the
 * carries, so a + b = (a ^ b) + ((a & b) << 1). Repeat until no carry is left.
 * The lowest carry moves up at least one bit per pass, so 32 passes suffice.
 */
uint32_t op1(uint32_t a, uint32_t b, int *n)
{
    int passes = 0;
    while (b) {
        uint32_t carry = (a & b) << 1;
        a ^= b;
        b = carry;
        passes++;
    }
    *n = passes;
    return a;
}

/* a - b. The bitwise model is op1(a, op1(~b, 1)): negate in two's complement,
 * then add. The sub instruction does both at once.
 */
uint32_t op2(uint32_t a, uint32_t b)
{
    return a - b;
}

/* floor((a + b) / 2) without the 33-bit sum. Since a + b = 2 (a & b) + (a ^ b),
 * half of it is (a & b) + ((a ^ b) >> 1), and the bit shifted out is the half
 * that floor drops.
 */
uint32_t op3(uint32_t a, uint32_t b)
{
    return (a & b) + ((a ^ b) >> 1);
}

/* Q11.20: a stored value A stands for A / 2^20, so the product A B / 2^20 is
 * the 64-bit product shifted right by 20, after adding half a unit, 2^19.
 *
 * RV32I has no multiply and the harness has no __muldi3, so the 64-bit product
 * comes from four 32-bit multiplies (__mulsi3) of 16-bit halves of the
 * unsigned words. As a signed number a word with the top bit set is w - 2^32,
 * which takes 2^32 times the other word off the product: the high word alone
 * is corrected for the signs.
 *
 * Adding 2^19 carries into bit 20 exactly when bit 19 is set, so the rounded
 * result is bits 20..51 of the product plus bit 19.
 */
int32_t q_mul(int32_t a, int32_t b)
{
    uint32_t ua = (uint32_t) a, ub = (uint32_t) b;
    uint32_t al = ua & 0xFFFF, ah = ua >> 16;
    uint32_t bl = ub & 0xFFFF, bh = ub >> 16;

    uint32_t low = al * bl, cross1 = al * bh, cross2 = ah * bl;
    uint32_t mid = cross1 + cross2; /* weight 2^16, may carry out */
    uint32_t mid_carry = mid < cross1;
    uint32_t lo = low + (mid << 16);
    uint32_t hi = ah * bh + (mid >> 16) + (mid_carry << 16) + (lo < low);

    if (a < 0)
        hi -= ub;
    if (b < 0)
        hi -= ua;
    return (int32_t) (((hi << 12) | (lo >> 20)) + ((lo >> 19) & 1));
}
