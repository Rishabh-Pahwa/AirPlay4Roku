' X25519 (RFC 7748) and Ed25519 signing (RFC 8032) on top of fe25519.brs.
'
' Not constant-time: the Roku is a single-user appliance and the keys here are
' ephemeral AirPlay pairing keys, so timing side channels are out of scope.
' Ed25519 signatures use a random nonce (r) instead of the deterministic
' RFC 8032 one so that R = r*B can be computed ahead of time, off the
' latency-critical pair-verify path. Verifiers can't tell the difference.

' ---------------------------------------------------------------- helpers

function bytes_copy(b as object, off as integer, n as integer) as object
    o = CreateObject("roByteArray")
    for i = 0 to n - 1
        o.push(b[off + i])
    end for
    return o
end function

function bytes_concat(a as object, b as object) as object
    o = CreateObject("roByteArray")
    o.Append(a)
    o.Append(b)
    return o
end function

function sha512_bytes(b as object) as object
    d = CreateObject("roEVPDigest")
    d.Setup("sha512")
    o = CreateObject("roByteArray")
    o.FromHexString(d.Process(b))
    return o
end function

' 32+ bytes of OS randomness (UUID v4s hashed together with the clock)
function random_bytes(n as integer) as object
    di = CreateObject("roDeviceInfo")
    s = ""
    for i = 0 to 5
        s = s + di.GetRandomUUID()
    end for
    dt = CreateObject("roDateTime")
    ts = CreateObject("roTimespan")
    s = s + dt.AsSeconds().toStr() + ts.TotalMilliseconds().toStr() + Rnd(1000000).toStr()
    b = CreateObject("roByteArray")
    b.FromAsciiString(s)
    h = sha512_bytes(b)
    out = CreateObject("roByteArray")
    while out.Count() < n
        for i = 0 to 63
            if out.Count() < n then out.push(h[i])
        end for
        h = sha512_bytes(h)
    end while
    return out
end function

' ---------------------------------------------------------------- X25519

function x25519(scalar as object, u as object) as object
    k = bytes_copy(scalar, 0, 32)
    k[0] = k[0] and 248
    k[31] = (k[31] and 127) or 64
    x1 = fe_frombytes(u, 0)
    x2 = fe_one()
    z2 = fe_new()
    x3 = fe_copy(x1)
    z3 = fe_one()
    A = fe_new() : AA = fe_new() : B = fe_new() : BB = fe_new() : E = fe_new()
    C = fe_new() : D = fe_new() : DA = fe_new() : CB = fe_new()
    swap = 0
    for t = 254 to 0 step -1
        kt = (k[t >> 3] >> (t and 7)) and 1
        if swap <> kt then
            tmp = x2 : x2 = x3 : x3 = tmp
            tmp = z2 : z2 = z3 : z3 = tmp
        end if
        swap = kt
        fe_add(A, x2, z2)
        fe_sq(AA, A)
        fe_sub(B, x2, z2)
        fe_sq(BB, B)
        fe_sub(E, AA, BB)
        fe_add(C, x3, z3)
        fe_sub(D, x3, z3)
        fe_mul(DA, D, A)
        fe_mul(CB, C, B)
        fe_add(x3, DA, CB)
        fe_sq(x3, x3)
        fe_sub(z3, DA, CB)
        fe_sq(z3, z3)
        fe_mul(z3, z3, x1)
        fe_mul(x2, AA, BB)
        fe_mulsmall(z2, E, 121665)
        fe_add(z2, z2, AA)
        fe_mul(z2, z2, E)
    end for
    if swap = 1 then
        tmp = x2 : x2 = x3 : x3 = tmp
        tmp = z2 : z2 = z3 : z3 = tmp
    end if
    r = fe_new()
    fe_mul(r, x2, fe_invert(z2))
    return fe_tobytes(r)
end function

' Public key for an X25519 private scalar, via the Ed25519 fixed-base table
' (u = (1+y)/(1-y) = (Z+Y)/(Z-Y)), which is ~2x faster than the ladder.
function x25519_public(scalar as object) as object
    k = bytes_copy(scalar, 0, 32)
    k[0] = k[0] and 248
    k[31] = (k[31] and 127) or 64
    p = ge_scalarmult_base(k)
    num = fe_new() : den = fe_new()
    fe_add(num, p.Z, p.Y)
    fe_sub(den, p.Z, p.Y)
    r = fe_new()
    fe_mul(r, num, fe_invert(den))
    return fe_tobytes(r)
end function

' ---------------------------------------------------------------- Ed25519 group

function ge_table() as object
    g = GetGlobalAA()
    if g.ed25519_tab = invalid then
        raw = CreateObject("roByteArray")
        raw.ReadFile("pkg:/assets/ed25519_base.bin")
        btab = []
        for i = 0 to 254
            o = i * 96
            btab.push({ypx: fe_frombytes(raw, o), ymx: fe_frombytes(raw, o + 32), xy2d: fe_frombytes(raw, o + 64)})
        end for
        g.ed25519_tab = btab
    end if
    return g.ed25519_tab
end function

' scalar: 32-byte little-endian, any value < 2^255
function ge_scalarmult_base(s as object) as object
    btab = ge_table()
    X = fe_new() : Y = fe_one() : Z = fe_one() : T = fe_new()
    ypx = fe_new() : ymx = fe_new() : a = fe_new() : b = fe_new() : c = fe_new() : d = fe_new()
    e = fe_new() : f = fe_new() : gg = fe_new() : h = fe_new()
    for i = 0 to 254
        if ((s[i >> 3] >> (i and 7)) and 1) = 1 then
            q = btab[i]
            fe_add(ypx, Y, X)
            fe_sub(ymx, Y, X)
            fe_mul(a, ypx, q.ypx)
            fe_mul(b, ymx, q.ymx)
            fe_mul(c, q.xy2d, T)
            fe_add(d, Z, Z)
            fe_sub(e, a, b)
            fe_add(h, a, b)
            fe_add(gg, d, c)
            fe_sub(f, d, c)
            fe_mul(X, e, f)
            fe_mul(Y, h, gg)
            fe_mul(Z, gg, f)
            fe_mul(T, e, h)
        end if
    end for
    return {X: X, Y: Y, Z: Z, T: T}
end function

function ge_encode(p as object) as object
    zi = fe_invert(p.Z)
    x = fe_new() : y = fe_new()
    fe_mul(x, p.X, zi)
    fe_mul(y, p.Y, zi)
    out = fe_tobytes(y)
    if fe_isodd(x) = 1 then out[31] = out[31] or 128
    return out
end function

' ---------------------------------------------------------------- scalars mod L

' floor(v / 256) for possibly-negative LongInteger (device ">>" is logical)
function sc_asr8(v as longinteger) as longinteger
    if v >= 0 then return v >> 8
    return -(((-v) + 255&) >> 8)
end function

' x: array of 64 LongInteger limbs (radix 2^8, may be signed); returns 32 bytes = x mod L
function sc_modL(x as object) as object
    Lc = [&HED, &HD3, &HF5, &H5C, &H1A, &H63, &H12, &H58, &HD6, &H9C, &HF7, &HA2, &HDE, &HF9, &HDE, &H14, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, &H10]
    for i = 63 to 32 step -1
        carry& = 0&
        j = i - 32
        while j < i - 12
            x[j] = x[j] + carry& - 16& * x[i] * Lc[j - (i - 32)]
            carry& = sc_asr8(x[j] + 128&)
            x[j] = x[j] - carry& * 256&
            j = j + 1
        end while
        x[j] = x[j] + carry&
        x[i] = 0&
    end for
    carry& = 0&
    for j = 0 to 31
        x[j] = x[j] + carry& - sc_div16(x[31]) * Lc[j]
        carry& = sc_asr8(x[j])
        x[j] = x[j] and 255&
    end for
    for j = 0 to 31
        x[j] = x[j] - carry& * Lc[j]
    end for
    out = CreateObject("roByteArray")
    for i = 0 to 31
        x[i + 1] = x[i + 1] + sc_asr8(x[i])
        out.push(x[i] and 255&)
    end for
    return out
end function

' floor(v / 16)
function sc_div16(v as longinteger) as longinteger
    if v >= 0 then return v >> 4
    return -(((-v) + 15&) >> 4)
end function

' 64-byte little-endian value mod L
function sc_reduce64(b as object) as object
    x = []
    for i = 0 to 63
        x.push(b[i] + 0&)
    end for
    x.push(0&)
    return sc_modL(x)
end function

' (k * a + r) mod L for 32-byte scalars
function sc_muladd(k as object, a as object, r as object) as object
    x = []
    for i = 0 to 64
        x.push(0&)
    end for
    for i = 0 to 31
        x[i] = r[i] + 0&
    end for
    for i = 0 to 31
        ki = k[i]
        for j = 0 to 31
            x[i + j] = x[i + j] + ki * a[j]
        end for
    end for
    return sc_modL(x)
end function

' ---------------------------------------------------------------- Ed25519 keys/sign

' seed: 32 random bytes -> {seed, a (clamped scalar), pub (32 bytes)}
function ed25519_keypair(seed as object) as object
    h = sha512_bytes(seed)
    a = bytes_copy(h, 0, 32)
    a[0] = a[0] and 248
    a[31] = (a[31] and 63) or 64
    pub = ge_encode(ge_scalarmult_base(a))
    return {seed: seed, a: a, pub: pub}
end function

' Precompute a signing nonce: {r (32 bytes, reduced), R (encoded point)}
function ed25519_nonce() as object
    r = sc_reduce64(random_bytes(64))
    return {r: r, R: ge_encode(ge_scalarmult_base(r))}
end function

' Sign msg with key using a precomputed nonce (each nonce must be used once)
function ed25519_sign(key as object, nonce as object, msg as object) as object
    hin = CreateObject("roByteArray")
    hin.Append(nonce.R)
    hin.Append(key.pub)
    hin.Append(msg)
    k = sc_reduce64(sha512_bytes(hin))
    S = sc_muladd(k, key.a, nonce.r)
    sig = CreateObject("roByteArray")
    sig.Append(nonce.R)
    sig.Append(S)
    return sig
end function
