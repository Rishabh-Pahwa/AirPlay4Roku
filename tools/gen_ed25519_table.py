#!/usr/bin/env python3
"""Generate app/assets/ed25519_base.bin: 2^i * B (i = 0..254) in "niels" form.

Each entry is 96 bytes: (y+x, y-x, 2*d*x*y) as three 32-byte little-endian
canonical field elements. Fixed-base scalar multiplication then needs one
mixed addition per set scalar bit and no doublings, which matters on a CPU
where one field multiplication costs ~0.7 ms.
"""
import os

P = 2**255 - 19
D = (-121665 * pow(121666, P - 2, P)) % P
Q = pow(2, (P - 1) // 4, P)  # sqrt(-1)


def xrecover(y):
    xx = (y * y - 1) * pow(D * y * y + 1, P - 2, P)
    x = pow(xx, (P + 3) // 8, P)
    if (x * x - xx) % P != 0:
        x = (x * Q) % P
    if x % 2 != 0:
        x = P - x
    return x


BY = 4 * pow(5, P - 2, P) % P
BX = xrecover(BY)


def add(p1, p2):
    (x1, y1), (x2, y2) = p1, p2
    t = D * x1 * x2 * y1 * y2
    x3 = (x1 * y2 + x2 * y1) * pow(1 + t, P - 2, P)
    y3 = (y1 * y2 + x1 * x2) * pow(1 - t, P - 2, P)
    return (x3 % P, y3 % P)


def le(v):
    return (v % P).to_bytes(32, "little")


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "app", "assets", "ed25519_base.bin")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    pt = (BX, BY)
    buf = bytearray()
    for i in range(255):
        x, y = pt
        buf += le(y + x) + le(y - x) + le(2 * D * x * y)
        pt = add(pt, pt)
    open(out, "wb").write(buf)
    print("wrote", out, len(buf), "bytes")


if __name__ == "__main__":
    main()
