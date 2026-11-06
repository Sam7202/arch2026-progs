#include "gcd.h"

/* Count the trailing zeros of a nonzero x. RV32I has no ctz instruction, and a
 * de Bruijn table needs a multiply, so search the bit position in halves:
 * five tests cover 32 bits.
 */
static int ctz32(uint32_t x)
{
    int n = 0;
    if (!(x & 0xFFFFu)) {
        n += 16;
        x >>= 16;
    }
    if (!(x & 0xFFu)) {
        n += 8;
        x >>= 8;
    }
    if (!(x & 0xFu)) {
        n += 4;
        x >>= 4;
    }
    if (!(x & 0x3u)) {
        n += 2;
        x >>= 2;
    }
    if (!(x & 0x1u))
        n += 1;
    return n;
}

/* Binary GCD (Stein's algorithm), from three identities:
 *   gcd(2u, 2v) = 2 gcd(u, v)
 *   gcd(2u, v)  = gcd(u, v)        for odd v
 *   gcd(u, v)   = gcd(u, v - u)    for odd u <= v, and v - u is even
 * The common power of two is counted once, then both operands stay odd: each
 * pass subtracts the smaller from the larger and strips the factors of two the
 * difference gains. A pass removes at least one bit, so it ends in at most 64.
 */
uint32_t gcd_u32(uint32_t a, uint32_t b)
{
    if (a == 0)
        return b;
    if (b == 0)
        return a;

    int shift = ctz32(a | b);
    a >>= ctz32(a);
    do {
        b >>= ctz32(b);
        if (a > b) {
            uint32_t t = a;
            a = b;
            b = t;
        }
        b -= a;
    } while (b);
    return a << shift;
}
