#!/usr/bin/env python3
"""Generate app/source/fe25519.brs: GF(2^255-19) arithmetic for BrightScript.

Representation: 20 limbs of radix 2^13 (260 bits) held in plain 32-bit
Integers. BrightScript LongInteger/Double are ~20x slower than Integer on the
Roku 2 XS, so everything is arranged so that no intermediate ever exceeds
2^31-1 or goes negative (">>" is a logical shift on the device):

  * "carried" limbs are < LIMB_MAX (=10362, i.e. 20*LIMB_MAX^2 < 2^31)
  * products are accumulated into 39 column sums (each < 2^31), carried into
    13-bit digits, then the top 20 digits are folded down with
    2^260 = 32*2^255 = 32*19 = 608 (mod p)
  * subtraction adds a multiple of p whose limbs are all >= LIMB_MAX

Every routine writes into an output array that may alias an input.
Values are not canonical (they're < 2^260); fe_tobytes canonicalises.
"""
import os
import random

P = 2**255 - 19
R = 13
N = 20
MASK = (1 << R) - 1
FOLD = (2**(R * N)) % P  # 608
assert FOLD == 608
LIMB_MAX = 10362
assert N * LIMB_MAX * LIMB_MAX < 2**31


def subtrahend_multiple():
    """Limbs of k*p with every limb in [LIMB_MAX, 2^15]."""
    for k in range(2, 4096, 2):
        v = k * P
        d = []
        x = v
        for i in range(N - 1):
            d.append(x & MASK)
            x >>= R
        d.append(x)
        # borrow so every low limb is >= LIMB_MAX
        for i in range(N - 1):
            while d[i] < LIMB_MAX:
                d[i] += 1 << R
                d[i + 1] -= 1
        if all(LIMB_MAX <= t <= 2**15 for t in d) and sum(t << (R * i) for i, t in enumerate(d)) == v:
            return d
    raise SystemExit("no multiple found")


SUBP = subtrahend_multiple()


def emit_carry_chain(lines, names, fold_into_first=True, indent="    "):
    """Carry names[0..N-1] in place (all nonnegative), folding the top carry."""
    for i in range(N - 1):
        lines.append(f"{indent}{names[i+1]} = {names[i+1]} + ({names[i]} >> 13) : {names[i]} = {names[i]} and 8191")
    if fold_into_first:
        lines.append(f"{indent}c = {names[N-1]} >> 13 : {names[N-1]} = {names[N-1]} and 8191")
        lines.append(f"{indent}{names[0]} = {names[0]} + c * 608")
        lines.append(f"{indent}{names[1]} = {names[1]} + ({names[0]} >> 13) : {names[0]} = {names[0]} and 8191")
        lines.append(f"{indent}{names[2]} = {names[2]} + ({names[1]} >> 13) : {names[1]} = {names[1]} and 8191")


def gen_mul(name, square):
    L = []
    if square:
        L.append(f"sub {name}(o as object, a as object)")
    else:
        L.append(f"sub {name}(o as object, a as object, b as object)")
    for i in range(N):
        L.append(f"    a{i} = a[{i}]")
    if not square:
        for i in range(N):
            L.append(f"    b{i} = b[{i}]")
    else:
        for i in range(N):
            L.append(f"    d{i} = a{i} + a{i}")
    for k in range(2 * N - 1):
        terms = []
        if square:
            for i in range(N):
                j = k - i
                if 0 <= j < N and i <= j:
                    if i == j:
                        terms.append(f"a{i} * a{i}")
                    else:
                        terms.append(f"d{i} * a{j}")
        else:
            for i in range(N):
                j = k - i
                if 0 <= j < N:
                    terms.append(f"a{i} * b{j}")
        L.append(f"    t{k} = " + " + ".join(terms))
    L.append("    t39 = 0")
    # carry 39 columns into 40 13-bit digits
    for k in range(2 * N - 1):
        L.append(f"    t{k+1} = t{k+1} + (t{k} >> 13) : t{k} = t{k} and 8191")
    # fold top 20 digits
    for i in range(N):
        L.append(f"    t{i} = t{i} + t{i+N} * 608")
    emit_carry_chain(L, [f"t{i}" for i in range(N)])
    for i in range(N):
        L.append(f"    o[{i}] = t{i}")
    L.append("end sub")
    return L


def gen_simple():
    L = []
    # add
    L.append("sub fe_add(o as object, a as object, b as object)")
    for i in range(N):
        L.append(f"    t{i} = a[{i}] + b[{i}]")
    emit_carry_chain(L, [f"t{i}" for i in range(N)])
    for i in range(N):
        L.append(f"    o[{i}] = t{i}")
    L.append("end sub")
    L.append("")
    # sub
    L.append("sub fe_sub(o as object, a as object, b as object)")
    for i in range(N):
        L.append(f"    t{i} = a[{i}] + {SUBP[i]} - b[{i}]")
    emit_carry_chain(L, [f"t{i}" for i in range(N)])
    for i in range(N):
        L.append(f"    o[{i}] = t{i}")
    L.append("end sub")
    L.append("")
    # mul by small constant (<= 207000 keeps products < 2^31)
    L.append("sub fe_mulsmall(o as object, a as object, k as integer)")
    for i in range(N):
        L.append(f"    t{i} = a[{i}] * k")
    emit_carry_chain(L, [f"t{i}" for i in range(N)])
    for i in range(N):
        L.append(f"    o[{i}] = t{i}")
    L.append("end sub")
    return L


HELPERS = r"""
function fe_new() as object
    return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
end function

function fe_one() as object
    return [1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
end function

function fe_copy(a as object) as object
    o = fe_new()
    for i = 0 to 19
        o[i] = a[i]
    end for
    return o
end function

sub fe_set(o as object, a as object)
    for i = 0 to 19
        o[i] = a[i]
    end for
end sub

' little-endian 32 bytes (bit 255 ignored) from roByteArray at offset
function fe_frombytes(b as object, off as integer) as object
    o = fe_new()
    acc = 0
    bits = 0
    li = 0
    for i = 0 to 31
        v = b[off + i]
        if i = 31 then v = v and 127
        acc = acc + (v << bits)
        bits = bits + 8
        while bits >= 13 and li < 20
            o[li] = acc and 8191
            acc = acc >> 13
            bits = bits - 13
            li = li + 1
        end while
    end for
    if li < 20 then o[li] = acc
    return o
end function

' fully reduce mod p, in place; returns canonical limbs
sub fe_reduce(a as object)
    ' value < 2^260 with carried limbs; fold bits >= 255 twice
    for pass = 1 to 2
        top = a[19] >> 8
        a[19] = a[19] and 255
        a[0] = a[0] + top * 19
        for i = 0 to 18
            a[i + 1] = a[i + 1] + (a[i] >> 13)
            a[i] = a[i] and 8191
        end for
    end for
    ' now a < 2^255 + small; subtract p if a >= p  (a >= p  <=>  a + 19 >= 2^255)
    t = fe_copy(a)
    t[0] = t[0] + 19
    for i = 0 to 18
        t[i + 1] = t[i + 1] + (t[i] >> 13)
        t[i] = t[i] and 8191
    end for
    if (t[19] >> 8) <> 0 then
        t[19] = t[19] and 255
        fe_set(a, t)
    end if
end sub

function fe_tobytes(a as object) as object
    t = fe_copy(a)
    fe_reduce(t)
    out = CreateObject("roByteArray")
    acc = 0
    bits = 0
    li = 0
    for i = 0 to 31
        while bits < 8 and li < 20
            acc = acc + (t[li] << bits)
            bits = bits + 13
            li = li + 1
        end while
        out.push(acc and 255)
        acc = acc >> 8
        bits = bits - 8
    end for
    return out
end function

function fe_iszero(a as object) as boolean
    t = fe_copy(a)
    fe_reduce(t)
    for i = 0 to 19
        if t[i] <> 0 then return false
    end for
    return true
end function

' parity of canonical value (for ed25519 sign bit)
function fe_isodd(a as object) as integer
    t = fe_copy(a)
    fe_reduce(t)
    return t[0] and 1
end function

' a^(p-2) using the standard ref10 addition chain
function fe_invert(z as object) as object
    t0 = fe_new() : t1 = fe_new() : t2 = fe_new() : t3 = fe_new()
    fe_sq(t0, z)
    fe_sq(t1, t0)
    fe_sq(t1, t1)
    fe_mul(t1, z, t1)
    fe_mul(t0, t0, t1)
    fe_sq(t2, t0)
    fe_mul(t1, t1, t2)
    fe_sq(t2, t1)
    for i = 1 to 4
        fe_sq(t2, t2)
    end for
    fe_mul(t1, t2, t1)
    fe_sq(t2, t1)
    for i = 1 to 9
        fe_sq(t2, t2)
    end for
    fe_mul(t2, t2, t1)
    fe_sq(t3, t2)
    for i = 1 to 19
        fe_sq(t3, t3)
    end for
    fe_mul(t2, t3, t2)
    fe_sq(t2, t2)
    for i = 1 to 9
        fe_sq(t2, t2)
    end for
    fe_mul(t1, t2, t1)
    fe_sq(t2, t1)
    for i = 1 to 49
        fe_sq(t2, t2)
    end for
    fe_mul(t2, t2, t1)
    fe_sq(t3, t2)
    for i = 1 to 99
        fe_sq(t3, t3)
    end for
    fe_mul(t2, t3, t2)
    fe_sq(t2, t2)
    for i = 1 to 49
        fe_sq(t2, t2)
    end for
    fe_mul(t1, t2, t1)
    fe_sq(t1, t1)
    for i = 1 to 4
        fe_sq(t1, t1)
    end for
    out = fe_new()
    fe_mul(out, t1, t0)
    return out
end function

' a^((p-5)/8), used for square roots (point decompression)
function fe_pow22523(z as object) as object
    t0 = fe_new() : t1 = fe_new() : t2 = fe_new()
    fe_sq(t0, z)
    fe_sq(t1, t0)
    fe_sq(t1, t1)
    fe_mul(t1, z, t1)
    fe_mul(t0, t0, t1)
    fe_sq(t0, t0)
    fe_mul(t0, t1, t0)
    fe_sq(t1, t0)
    for i = 1 to 4
        fe_sq(t1, t1)
    end for
    fe_mul(t0, t1, t0)
    fe_sq(t1, t0)
    for i = 1 to 9
        fe_sq(t1, t1)
    end for
    fe_mul(t1, t1, t0)
    fe_sq(t2, t1)
    for i = 1 to 19
        fe_sq(t2, t2)
    end for
    fe_mul(t1, t2, t1)
    fe_sq(t1, t1)
    for i = 1 to 9
        fe_sq(t1, t1)
    end for
    fe_mul(t0, t1, t0)
    fe_sq(t1, t0)
    for i = 1 to 49
        fe_sq(t1, t1)
    end for
    fe_mul(t1, t1, t0)
    fe_sq(t2, t1)
    for i = 1 to 99
        fe_sq(t2, t2)
    end for
    fe_mul(t1, t2, t1)
    fe_sq(t1, t1)
    for i = 1 to 49
        fe_sq(t1, t1)
    end for
    fe_mul(t0, t1, t0)
    fe_sq(t0, t0)
    fe_sq(t0, t0)
    out = fe_new()
    fe_mul(out, t0, z)
    return out
end function
"""


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "app", "source", "fe25519.brs")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    L = ["' GENERATED by tools/gen_fe25519.py -- do not edit.",
         "' GF(2^255-19), 20 limbs x 13 bits in 32-bit Integers; see generator for invariants.",
         ""]
    L += gen_mul("fe_mul", False) + [""]
    L += gen_mul("fe_sq", True) + [""]
    L += gen_simple() + [""]
    L += HELPERS.strip("\n").split("\n")
    open(out, "w").write("\n".join(L) + "\n")
    print("wrote", out, "SUBP =", SUBP)
    selfcheck()


def selfcheck():
    """Simulate the generated limb algorithms in Python with bound assertions."""
    rnd = random.Random(1)

    def limbs(v):
        return [(v >> (R * i)) & MASK for i in range(N - 1)] + [v >> (R * (N - 1))]

    def val(l):
        return sum(x << (R * i) for i, x in enumerate(l))

    def chk(x):
        assert 0 <= x < 2**31, x
        return x

    def carry(t):
        for i in range(N - 1):
            t[i + 1] = chk(t[i + 1] + (t[i] >> 13)); t[i] &= MASK
        c = t[N - 1] >> 13; t[N - 1] &= MASK
        t[0] = chk(t[0] + c * 608)
        t[1] = chk(t[1] + (t[0] >> 13)); t[0] &= MASK
        t[2] = chk(t[2] + (t[1] >> 13)); t[1] &= MASK
        assert all(x < LIMB_MAX for x in t), t
        return t

    def mul(a, b):
        t = [0] * 40
        for k in range(39):
            t[k] = chk(sum(a[i] * b[k - i] for i in range(N) if 0 <= k - i < N))
        for k in range(39):
            t[k + 1] = chk(t[k + 1] + (t[k] >> 13)); t[k] &= MASK
        for i in range(N):
            t[i] = chk(t[i] + t[i + N] * 608)
        return carry(t[:N])

    def worst():
        return [LIMB_MAX - 1] * N

    for trial in range(3000):
        if trial == 0:
            a, b = worst(), worst()
        else:
            a = carry(limbs(rnd.randrange(2**260)))
            b = carry(limbs(rnd.randrange(2**260)))
        assert val(mul(a, b)) % P == (val(a) * val(b)) % P
        s = carry([chk(a[i] + b[i]) for i in range(N)])
        assert val(s) % P == (val(a) + val(b)) % P
        d = carry([chk(a[i] + SUBP[i] - b[i]) for i in range(N)])
        assert val(d) % P == (val(a) - val(b)) % P
        m = carry([chk(a[i] * 121665) for i in range(N)])
        assert val(m) % P == (val(a) * 121665) % P
    print("python model of limb arithmetic: bounds + correctness OK (3000 trials incl. worst case)")


if __name__ == "__main__":
    main()
