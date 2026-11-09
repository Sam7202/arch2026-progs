#include "bf16.h"
#include <stdbool.h>

#define BF16_EXP_BIAS 127U
#define BF16_INF 0x7F80u
#define BF16_NAN 0x7FC0u

/* bf16 is the top half of binary32: same sign bit, same 8-bit exponent, 7 of
 * the 23 fraction bits. Narrowing drops the low 16 bits after rounding them.
 * Half of the dropped range is 0x8000; adding 0x7FFF plus the lowest kept bit
 * carries into the kept half above the tie, and at the tie only when the kept
 * half is odd, which rounds ties to even. Inf and NaN skip the rounding, which
 * could carry out of the exponent.
 */
uint16_t bf16_from_f32(uint32_t f32bits)
{
    if (((f32bits >> 23) & 0xFFu) == 0xFFu)
        return (uint16_t) (f32bits >> 16);
    f32bits += ((f32bits >> 16) & 1u) + 0x7FFFu;
    return (uint16_t) (f32bits >> 16);
}

/* Shift a denormal significand up until its leading one reaches bit 7, the
 * place of the hidden one, and lower the exponent by one per shift.
 */
static uint32_t normalize(uint32_t mant, int32_t *exp_adjust)
{
    while ((mant & 0x80u) == 0) {
        mant <<= 1;
        (*exp_adjust)--;
    }
    return mant;
}

/* (2^ea m_a)(2^eb m_b) = 2^(ea + eb) (m_a m_b): the sign is the XOR of the
 * signs, the biased exponents add with one bias taken back out, and the
 * significands, each 1.f scaled by 128, multiply. Their product lies in [1, 4)
 * scaled by 2^14, so it is renormalized by one bit when it reaches bit 15. The
 * fraction is truncated. Specials are checked first, a before b.
 *
 * NOTE: the fields are taken from unsigned copies, so no bit operation touches
 * a signed value; only the exponent sum, which can go negative, is signed.
 */
uint16_t bf16_mul(uint16_t a, uint16_t b)
{
    uint32_t ua = a, ub = b;
    uint32_t sign = (ua ^ ub) & 0x8000u;
    uint32_t exp_a = (ua >> 7) & 0xFFu, exp_b = (ub >> 7) & 0xFFu;
    uint32_t mant_a = ua & 0x7Fu, mant_b = ub & 0x7Fu;
    bool a_zero = (ua & 0x7FFFu) == 0, b_zero = (ub & 0x7FFFu) == 0;

    if (exp_a == 0xFFu) {
        if (mant_a)
            return a;
        if (b_zero)
            return BF16_NAN;
        return (uint16_t) (sign | BF16_INF);
    }
    if (exp_b == 0xFFu) {
        if (mant_b)
            return b;
        if (a_zero)
            return BF16_NAN;
        return (uint16_t) (sign | BF16_INF);
    }
    if (a_zero || b_zero)
        return (uint16_t) sign;

    int32_t exp_adjust = 0;
    if (exp_a != 0) {
        mant_a |= 0x80u;
    } else {
        mant_a = normalize(mant_a, &exp_adjust);
        exp_a = 1;
    }
    if (exp_b != 0) {
        mant_b |= 0x80u;
    } else {
        mant_b = normalize(mant_b, &exp_adjust);
        exp_b = 1;
    }

    uint32_t result_mant = mant_a * mant_b;
    int32_t result_exp =
        (int32_t) (exp_a + exp_b) - (int32_t) BF16_EXP_BIAS + exp_adjust;
    if (result_mant & 0x8000u) {
        result_mant = (result_mant >> 8) & 0x7Fu;
        result_exp++;
    } else {
        result_mant = (result_mant >> 7) & 0x7Fu;
    }

    if (result_exp >= 0xFF)
        return (uint16_t) (sign | BF16_INF);
    if (result_exp <= 0) {
        /* The contract shifts the 7-bit fraction, without the hidden one. */
        if (result_exp < -6)
            return (uint16_t) sign;
        result_mant >>= 1 - result_exp;
        result_exp = 0;
    }
    return (uint16_t) (sign | ((uint32_t) result_exp << 7) | result_mant);
}

/* sqrt(2^e m) = 2^(e/2) sqrt(m). An odd e lends one factor of two to m, so the
 * exponent halves exactly. With m scaled by 128 the root r, also scaled by 128,
 * satisfies r^2 / 128 = m: a binary search over [90, 256] keeps the largest
 * mid with (mid * mid) / 128 <= m, truncating.
 *
 * NOTE: e = exp - 127 is negative below 1.0, and a right shift of a negative
 * signed value is implementation-defined. The work stays on the positive
 * field instead: e is odd exactly when exp is even, and the new exponent,
 * floor(e / 2) + 127, equals floor((exp + 127) / 2).
 */
uint16_t bf16_sqrt(uint16_t a)
{
    uint32_t ua = a;
    uint32_t sign = ua >> 15, exp = (ua >> 7) & 0xFFu, mant = ua & 0x7Fu;

    if (exp == 0xFFu) {
        if (mant)
            return a; /* NaN */
        if (sign)
            return BF16_NAN; /* sqrt(-Inf) */
        return a;            /* sqrt(+Inf) */
    }
    if ((ua & 0x7FFFu) == 0)
        return 0; /* sqrt(+0) and sqrt(-0) are +0 */
    if (sign)
        return BF16_NAN;
    if (exp == 0)
        return 0; /* denormals flush to +0 */

    uint32_t m = 0x80u | mant; /* [128, 256) stands for [1, 2) */
    if ((exp & 1u) == 0)
        m <<= 1; /* e odd */
    uint32_t new_exp = (exp + BF16_EXP_BIAS) >> 1;

    uint32_t low = 90, high = 256, result = 128;
    while (low <= high) {
        uint32_t mid = (low + high) >> 1;
        uint32_t sq = (mid * mid) / 128;
        if (sq <= m) {
            result = mid;
            low = mid + 1;
        } else {
            high = mid - 1;
        }
    }

    if (result >= 256) {
        result >>= 1;
        new_exp++;
    } else {
        while ((result < 128) && (new_exp > 1)) {
            result <<= 1;
            new_exp--;
        }
    }
    if (new_exp >= 0xFFu)
        return BF16_INF;
    if (new_exp == 0)
        return 0;
    return (uint16_t) ((new_exp << 7) | (result & 0x7Fu));
}
