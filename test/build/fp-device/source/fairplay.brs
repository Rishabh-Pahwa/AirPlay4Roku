' fairplay.brs -- FairPlay (AirPlay fp-setup) for the Roku receiver.
' Port of RPiPlay lib/fairplay_playfair.c + lib/playfair/* ("playfair"), verified
' byte-identical against the C original by test/fairplay/run.sh.
'
'   FairPlay_SetupReply(req16)        fp-setup phase 1 -> 142-byte canned reply
'   FairPlay_HandshakeReply(req164)   fp-setup phase 2 -> 32-byte reply (keep req164!)
'   FairPlay_Decrypt(req164, ekey72)  playfair_decrypt -> 16-byte AES session key
'
' Tables: pkg:/assets/fairplay/<name>.bin, one file per C array, produced by
' tools/gen_fairplay_tables.py from the C sources. Byte arrays are raw bytes in C
' initializer order (multi-dimensional arrays flattened row-major); the uint32
' tables (table_s5..s9, md5_k) are 4 bytes per entry, LITTLE-endian. They are
' loaded once per thread and cached in GetGlobalAA().fp_tables (~185 KB).
'
' Integer arithmetic: every value is kept so that no Integer addition, subtraction
' or multiplication leaves the signed 32-bit range, so results are identical on the
' device (wrapping Integer) and the brs emulator (non-wrapping). uint32 words live in
' Integers as their two's-complement bit pattern; uint32 adds are done in 16-bit
' halves (fp_add32); xor is (a or b) - (a and b), which can never overflow.
' Right shifts of possibly-negative values are always masked, so the code is correct
' whether `>>` is logical (device, emulator) or arithmetic.
'
' Cost of one FairPlay_Decrypt (op = one Integer arithmetic/bitwise op or array read):
'   decryptMessage (8 blocks x 9 rounds)        ~18k ops  (~4.6k array reads)
'   5x modified_md5 (320 steps)                  ~16k ops
'   5x sap_hash: 4,200 scramble steps ~105k, 1,280 mix steps ~27k, garble+fold ~20k
'   key schedule + cycle                          ~4k ops
'   total ~200k ops, ~50k statements, ~1.1k function calls
' => estimated 0.3-0.6 s on a Roku 2 XS 3100X (1 us/op, 3 us/array read, 6 us/call).
' First call also loads the tables: 28 ReadFiles (~185 KB) + ~40k ops, once per thread.
' brs emulator (Node 22, x86-64): ~135-160 ms per decrypt, ~150 ms table load.

function FairPlay_SetupReply(req as object) as object
    if req = invalid then return invalid
    if req.Count() < 16 then return invalid
    if req[4] <> 3 then return invalid
    mode = req[14]
    if mode > 3 then return invalid   ' C indexes reply_message[mode] out of bounds
    t = fp_tables()
    if t = invalid then return invalid
    src = t.fp_reply_message
    res = CreateObject("roByteArray")
    o = mode * 142
    for i = 0 to 141
        res.push(src[o + i])
    end for
    return res
end function

' The caller must keep req (message3) for FairPlay_Decrypt.
function FairPlay_HandshakeReply(req as object) as object
    if req = invalid then return invalid
    if req.Count() < 164 then return invalid
    if req[4] <> 3 then return invalid
    t = fp_tables()
    if t = invalid then return invalid
    res = CreateObject("roByteArray")
    res.Append(t.fp_header)
    for i = 144 to 163
        res.push(req[i])
    end for
    return res
end function

' message3: the 164-byte fp-setup phase-2 request; ekey: 72-byte "ekey" from SETUP.
function FairPlay_Decrypt(message3 as object, ekey as object) as object
    if message3 = invalid or ekey = invalid then return invalid
    if message3.Count() < 164 then return invalid
    if ekey.Count() < 72 then return invalid
    if message3[12] > 3 then return invalid   ' C indexes message_key[mode] out of bounds
    t = fp_tables()
    if t = invalid then return invalid
    sapKey = fp_session_key(t, message3)
    ks = fp_key_schedule(t, sapKey)
    z = t.z_key
    x = t.x_key
    blk = CreateObject("roArray", 16, false)
    for i = 0 to 15
        a = ekey[56 + i]
        b = z[i]
        blk.push((a or b) - (a and b))
    end for
    fp_cycle(t, blk, ks)
    out = CreateObject("roByteArray")
    for i = 0 to 15
        a = fp_x(fp_x(blk[i], ekey[16 + i]), fp_x(x[i], z[i]))
        out.push(a)
    end for
    return out
end function

' ------------------------------------------------------------------ tables

function fp_tables() as object
    g = GetGlobalAA()
    if g.fp_tables <> invalid then return g.fp_tables
    dir = "pkg:/assets/fairplay/"
    t = {}
    for each n in ["message_key", "message_iv", "z_key", "x_key", "t_key", "table_s1", "table_s2", "table_s3", "table_s4", "table_s10", "index_mangle", "initial_session_key", "static_source_1", "static_source_2", "default_sap", "md5_shift", "sap_buffer0", "sap_buffer2", "sap_buffer4", "sap_i0_index", "fp_reply_message", "fp_header"]
        b = CreateObject("roByteArray")
        if not b.ReadFile(dir + n + ".bin") then
            print "fairplay: cannot read "; dir; n; ".bin"
            return invalid
        end if
        t[n] = b
    end for
    ' uint32 little-endian tables -> roArray of Integer (two's-complement bit pattern)
    for each n in ["table_s5", "table_s6", "table_s7", "table_s8", "table_s9", "md5_k"]
        b = CreateObject("roByteArray")
        if not b.ReadFile(dir + n + ".bin") then
            print "fairplay: cannot read "; dir; n; ".bin"
            return invalid
        end if
        cnt = b.Count() \ 4
        w = CreateObject("roArray", cnt, false)
        o = 0
        for i = 0 to cnt - 1
            w.push(b[o] or (b[o + 1] << 8) or (b[o + 2] << 16) or (b[o + 3] << 24))
            o = o + 4
        end for
        t[n] = w
    end for
    ' derived index tables
    s2off = CreateObject("roArray", 144, false)   ' message_table_index(i)
    s4off = CreateObject("roArray", 144, false)   ' permute_table_2(i)
    for i = 0 to 143
        s2off.push(((97 * i) mod 144) * 256)
        s4off.push(((71 * i) mod 144) * 256)
    end for
    t.s2off = s2off
    t.s4off = s4off
    s1off = CreateObject("roArray", 44, false)    ' table_index(i)
    for i = 0 to 43
        s1off.push(((31 * i) mod 40) * 256)
    end for
    t.s1off = s1off
    ' sap_hash scramble, step i (0..839) reads buffer1 at x/y/z = ((i - k) & 0xffffffff) % 210
    ' for k = 155, 57, 13 (for i < k: (2^32 + i - k) mod 210 = (46 + i - k) mod 210) and
    ' writes w = i % 210. Split the 840 steps into runs where none of the four indices
    ' wraps: [w_first, w_last, x - w, y - w, z - w].
    idx = []
    for each k in [155, 57, 13]
        a = CreateObject("roArray", 841, false)
        for i = 0 to 840   ' entry 840 is a sentinel: the run test below need not short-circuit
            v = i - k
            if v < 0 then v = v + 46 + 210
            a.push(v mod 210)
        end for
        idx.push(a)
    end for
    segs = []
    i = 0
    while i < 840
        n = 1
        while i + n < 840 and (i + n) mod 210 <> 0 and idx[0][i + n] = idx[0][i] + n and idx[1][i + n] = idx[1][i] + n and idx[2][i + n] = idx[2][i] + n
            n = n + 1
        end while
        w = i mod 210
        segs.push([w, w + n - 1, idx[0][i] - w, idx[1][i] - w, idx[2][i] - w])
        i = i + n
    end while
    t.scr_segs = segs
    ' md5 rotate: mask for the right-shifted part (does not rely on >> being logical)
    rm = CreateObject("roArray", 64, false)
    for i = 0 to 63
        rm.push((1 << t.md5_shift[i]) - 1)
    end for
    t.md5_rmask = rm
    g.fp_tables = t
    return t
end function

' ------------------------------------------------------------------ helpers

function fp_x(a as integer, b as integer) as integer
    return (a or b) - (a and b)
end function

' uint32 addition on two's-complement bit patterns, without Integer overflow
function fp_add32(a as integer, b as integer) as integer
    lo = (a and 65535) + (b and 65535)
    hi = (a >> 16) + (b >> 16) + (lo >> 16)
    return ((hi and 65535) << 16) or (lo and 65535)
end function

function fp_rol8(x as integer, n as integer) as integer
    x = x and 255
    return ((x << n) and 255) or (x >> (8 - n))
end function

function fp_rol8x(x as integer, n as integer) as integer
    x = x and 255
    return (x << n) or (x >> (8 - n))
end function

function fp_wror8(x as integer, n as integer) as integer
    if n = 0 then return 0
    x = x and 255
    return ((x >> n) and 255) or (x << (8 - n))
end function

function fp_wrol8(x as integer, n as integer) as integer
    if n = 0 then return 0
    x = x and 255
    return ((x << n) and 255) or (x >> (8 - n))
end function

function fp_wrol32(x as integer, n as integer) as integer
    if n = 0 then return 0
    x = x and 255
    return fp_x(x << n, x >> (8 - n))
end function

function fp_zeros(n as integer) as object
    a = CreateObject("roArray", n, false)
    for i = 1 to n
        a.push(0)
    end for
    return a
end function

' ------------------------------------------------------------------ session key

' generate_session_key(default_sap, message3) -> 16 bytes (roArray)
function fp_session_key(t as object, msg as object) as object
    dm = fp_decrypt_message(t, msg)
    sap = CreateObject("roArray", 320, false)
    s = t.static_source_1
    for i = 0 to 16
        sap.push(s[i])
    end for
    for i = 0 to 127
        sap.push(dm[i])
    end for
    s = t.default_sap
    for i = 128 to 255
        sap.push(s[i])
    end for
    s = t.static_source_2
    for i = 0 to 46
        sap.push(s[i])
    end for
    s = t.initial_session_key
    kw = []
    for i = 0 to 12 step 4
        kw.push(s[i] or (s[i + 1] << 8) or (s[i + 2] << 16) or (s[i + 3] << 24))
    end for
    for r = 0 to 4
        md = fp_md5(t, sap, r * 64, kw)
        h = fp_sap_hash(t, sap, r * 64)
        for i = 0 to 3
            o = i * 4
            w = h[o] or (h[o + 1] << 8) or (h[o + 2] << 16) or (h[o + 3] << 24)
            kw[i] = fp_add32(w, md[i])
        end for
    end for
    ' bytes of each little-endian word, reversed (= big-endian), xor 121
    key = CreateObject("roArray", 16, false)
    for i = 0 to 3
        w = kw[i]
        key.push(fp_x((w >> 24) and 255, 121))
        key.push(fp_x((w >> 16) and 255, 121))
        key.push(fp_x((w >> 8) and 255, 121))
        key.push(fp_x(w and 255, 121))
    end for
    return key
end function

' decryptMessage(message3) -> 128 bytes (roArray)
function fp_decrypt_message(t as object, msg as object) as object
    mode = msg[12]
    s2 = t.table_s2
    so = t.s2off
    mk = t.message_key
    s9 = t.table_s9
    s10 = t.table_s10
    mo = mode * 144
    out = fp_zeros(128)
    n = fp_zeros(16)
    for i = 0 to 7
        if mode = 3 then src = 128 - 16 * i else src = 16 * (i + 1)
        b0 = msg[src] : b1 = msg[src + 1] : b2 = msg[src + 2] : b3 = msg[src + 3]
        b4 = msg[src + 4] : b5 = msg[src + 5] : b6 = msg[src + 6] : b7 = msg[src + 7]
        b8 = msg[src + 8] : b9 = msg[src + 9] : b10 = msg[src + 10] : b11 = msg[src + 11]
        b12 = msg[src + 12] : b13 = msg[src + 13] : b14 = msg[src + 14] : b15 = msg[src + 15]
        base = 128
        for j = 0 to 8
            k = mo + base
            ' buffer[p] = message_table_index(base+p)[buffer[src(p)]] ^ message_key[mode][base+p]
            x = s2[so[base] + b0] : y = mk[k] : n0 = (x or y) - (x and y)
            x = s2[so[base + 1] + b13] : y = mk[k + 1] : n1 = (x or y) - (x and y)
            x = s2[so[base + 2] + b10] : y = mk[k + 2] : n2 = (x or y) - (x and y)
            x = s2[so[base + 3] + b7] : y = mk[k + 3] : n3 = (x or y) - (x and y)
            x = s2[so[base + 4] + b4] : y = mk[k + 4] : n4 = (x or y) - (x and y)
            x = s2[so[base + 5] + b1] : y = mk[k + 5] : n5 = (x or y) - (x and y)
            x = s2[so[base + 6] + b14] : y = mk[k + 6] : n6 = (x or y) - (x and y)
            x = s2[so[base + 7] + b11] : y = mk[k + 7] : n7 = (x or y) - (x and y)
            x = s2[so[base + 8] + b8] : y = mk[k + 8] : n8 = (x or y) - (x and y)
            x = s2[so[base + 9] + b5] : y = mk[k + 9] : n9 = (x or y) - (x and y)
            x = s2[so[base + 10] + b2] : y = mk[k + 10] : n10 = (x or y) - (x and y)
            x = s2[so[base + 11] + b15] : y = mk[k + 11] : n11 = (x or y) - (x and y)
            x = s2[so[base + 12] + b12] : y = mk[k + 12] : n12 = (x or y) - (x and y)
            x = s2[so[base + 13] + b9] : y = mk[k + 13] : n13 = (x or y) - (x and y)
            x = s2[so[base + 14] + b6] : y = mk[k + 14] : n14 = (x or y) - (x and y)
            x = s2[so[base + 15] + b3] : y = mk[k + 15] : n15 = (x or y) - (x and y)
            ' block[w] = s9[b[4w]] ^ s9[0x100+b[4w+1]] ^ s9[0x200+b[4w+2]] ^ s9[0x300+b[4w+3]]
            x = s9[n0] : y = s9[256 + n1] : x = (x or y) - (x and y)
            y = s9[512 + n2] : x = (x or y) - (x and y) : y = s9[768 + n3] : x = (x or y) - (x and y)
            b0 = x and 255 : b1 = (x >> 8) and 255 : b2 = (x >> 16) and 255 : b3 = (x >> 24) and 255
            x = s9[n4] : y = s9[256 + n5] : x = (x or y) - (x and y)
            y = s9[512 + n6] : x = (x or y) - (x and y) : y = s9[768 + n7] : x = (x or y) - (x and y)
            b4 = x and 255 : b5 = (x >> 8) and 255 : b6 = (x >> 16) and 255 : b7 = (x >> 24) and 255
            x = s9[n8] : y = s9[256 + n9] : x = (x or y) - (x and y)
            y = s9[512 + n10] : x = (x or y) - (x and y) : y = s9[768 + n11] : x = (x or y) - (x and y)
            b8 = x and 255 : b9 = (x >> 8) and 255 : b10 = (x >> 16) and 255 : b11 = (x >> 24) and 255
            x = s9[n12] : y = s9[256 + n13] : x = (x or y) - (x and y)
            y = s9[512 + n14] : x = (x or y) - (x and y) : y = s9[768 + n15] : x = (x or y) - (x and y)
            b12 = x and 255 : b13 = (x >> 8) and 255 : b14 = (x >> 16) and 255 : b15 = (x >> 24) and 255
            base = base - 16
        end for
        ' permute through table_s10
        n[0] = s10[b0] : n[4] = s10[1024 + b4] : n[8] = s10[2048 + b8] : n[12] = s10[3072 + b12]
        n[13] = s10[3328 + b9] : n[9] = s10[2304 + b5] : n[5] = s10[1280 + b1] : n[1] = s10[256 + b13]
        n[2] = s10[512 + b10] : n[10] = s10[2560 + b2] : n[6] = s10[1536 + b14] : n[14] = s10[3584 + b6]
        n[3] = s10[768 + b7] : n[7] = s10[1792 + b11] : n[11] = s10[2816 + b15] : n[15] = s10[3840 + b3]
        ' CBC-style chaining
        if mode = 3 then
            dst = 112 - 16 * i
            if i < 7 then
                c = msg : co = dst
            else
                c = t.message_iv : co = mode * 16
            end if
        else
            dst = 16 * i
            if i > 0 then
                c = msg : co = dst
            else
                c = t.message_iv : co = mode * 16
            end if
        end if
        for p = 0 to 15
            x = n[p] : y = c[co + p]
            out[dst + p] = (x or y) - (x and y)
        end for
    end for
    return out
end function

' modified_md5(block, key) -> 4 little-endian words. kw: 4 words (Integer bit patterns)
function fp_md5(t as object, blk as object, off as integer, kw as object) as object
    kt = t.md5_k
    sh = t.md5_shift
    rm = t.md5_rmask
    bw = CreateObject("roArray", 16, false)
    for j = 0 to 15
        o = off + 4 * j
        bw.push((blk[o] << 24) or (blk[o + 1] << 16) or (blk[o + 2] << 8) or blk[o + 3])
    end for
    a = kw[0] : b = kw[1] : c = kw[2] : d = kw[3]
    for i = 0 to 63
        if i < 16 then
            j = i
            f = (b and c) or ((not b) and d)
        else if i < 32 then
            j = (5 * i + 1) and 15
            f = (b and d) or (c and (not d))
        else if i < 48 then
            j = (3 * i + 5) and 15
            f = (b or c) - (b and c)
            f = (f or d) - (f and d)
        else
            j = (7 * i) and 15
            x = b or (not d)
            f = (c or x) - (c and x)
        end if
        x = bw[j]
        y = kt[i]
        ' z = rol(a + input + K[i] + f, shift[i]) + b   (mod 2^32)
        lo = (a and 65535) + (x and 65535) + (y and 65535) + (f and 65535)
        hi = (a >> 16) + (x >> 16) + (y >> 16) + (f >> 16) + (lo >> 16)
        z = ((hi and 65535) << 16) or (lo and 65535)
        s = sh[i]
        z = (z << s) or ((z >> (32 - s)) and rm[i])
        lo = (z and 65535) + (b and 65535)
        hi = (z >> 16) + (b >> 16) + (lo >> 16)
        z = ((hi and 65535) << 16) or (lo and 65535)
        a = d : d = c : c = b : b = z
        if i = 31 then
            fp_swap(bw, a and 15, b and 15)
            fp_swap(bw, c and 15, d and 15)
            fp_swap(bw, (a >> 4) and 15, (b >> 4) and 15)
            fp_swap(bw, (a >> 8) and 15, (b >> 8) and 15)
            fp_swap(bw, (a >> 12) and 15, (b >> 12) and 15)
        end if
    end for
    return [fp_add32(kw[0], a), fp_add32(kw[1], b), fp_add32(kw[2], c), fp_add32(kw[3], d)]
end function

sub fp_swap(a as object, i as integer, j as integer)
    x = a[i]
    a[i] = a[j]
    a[j] = x
end sub

' sap_hash(block) -> 16 bytes (roArray)
function fp_sap_hash(t as object, blk as object, off as integer) as object
    b1 = CreateObject("roArray", 210, false)
    for i = 0 to 209
        m = i mod 64
        b1.push(blk[off + (m and 60) + 3 - (m and 3)])   ' byte-swapped 32-bit words
    end for
    ' b1[w] = (rol8(b1[y], 5) + (rol8(b1[z], 3) ^ b1[w]) - rol8(b1[x], 7)) & 0xff
    ' (rol8 parts have disjoint bits, so "or" = "+")
    for each sg in t.scr_segs
        cx = sg[2] : cy = sg[3] : cz = sg[4]
        for iw = sg[0] to sg[1]
            x = b1[iw + cx] : y = b1[iw + cy] : z = b1[iw + cz] : w = b1[iw]
            z = ((z << 3) and 255) or (z >> 5)
            b1[iw] = (((y << 5) and 255) + (y >> 3) + ((z or w) - (z and w)) - ((x << 7) and 255) - (x >> 1)) and 255
        end for
    end for
    b0 = fp_bytes_to_array(t.sap_buffer0)
    b2 = fp_bytes_to_array(t.sap_buffer2)
    b3 = fp_zeros(132)
    fp_garble(b0, b1, b2, b3, t.sap_buffer4)

    k = CreateObject("roArray", 16, false)
    for i = 0 to 15
        k.push(&HE1)
    end for
    i0 = t.sap_i0_index
    for i = 0 to 10
        if i = 3 then k[i] = &H3D else k[i] = (k[i] + b3[i0[i] * 4]) and 255
    end for
    for i = 0 to 19
        x = k[i and 15] : y = b0[i]
        k[i and 15] = (x or y) - (x and y)
    end for
    for i = 0 to 34
        x = k[i and 15] : y = b2[i]
        k[i and 15] = (x or y) - (x and y)
    end for
    for i = 0 to 209
        x = k[i and 15] : y = b1[i]
        k[i and 15] = (x or y) - (x and y)
    end for
    ' reverse scramble: k[i] = rol8(k[i-7],1) ^ k[i] ^ rol8(k[i-37],6) ^ rol8(k[i-177],5) (mod 16)
    k0 = k[0] : k1 = k[1] : k2 = k[2] : k3 = k[3] : k4 = k[4] : k5 = k[5] : k6 = k[6] : k7 = k[7]
    k8 = k[8] : k9 = k[9] : k10 = k[10] : k11 = k[11] : k12 = k[12] : k13 = k[13] : k14 = k[14] : k15 = k[15]
    for j = 0 to 15
        x = ((k9 << 1) and 255) + (k9 >> 7) : z = ((k11 << 6) and 255) + (k11 >> 2) : w = ((k15 << 5) and 255) + (k15 >> 3)
        x = (x or k0) - (x and k0) : x = (x or z) - (x and z) : k0 = (x or w) - (x and w)
        x = ((k10 << 1) and 255) + (k10 >> 7) : z = ((k12 << 6) and 255) + (k12 >> 2) : w = ((k0 << 5) and 255) + (k0 >> 3)
        x = (x or k1) - (x and k1) : x = (x or z) - (x and z) : k1 = (x or w) - (x and w)
        x = ((k11 << 1) and 255) + (k11 >> 7) : z = ((k13 << 6) and 255) + (k13 >> 2) : w = ((k1 << 5) and 255) + (k1 >> 3)
        x = (x or k2) - (x and k2) : x = (x or z) - (x and z) : k2 = (x or w) - (x and w)
        x = ((k12 << 1) and 255) + (k12 >> 7) : z = ((k14 << 6) and 255) + (k14 >> 2) : w = ((k2 << 5) and 255) + (k2 >> 3)
        x = (x or k3) - (x and k3) : x = (x or z) - (x and z) : k3 = (x or w) - (x and w)
        x = ((k13 << 1) and 255) + (k13 >> 7) : z = ((k15 << 6) and 255) + (k15 >> 2) : w = ((k3 << 5) and 255) + (k3 >> 3)
        x = (x or k4) - (x and k4) : x = (x or z) - (x and z) : k4 = (x or w) - (x and w)
        x = ((k14 << 1) and 255) + (k14 >> 7) : z = ((k0 << 6) and 255) + (k0 >> 2) : w = ((k4 << 5) and 255) + (k4 >> 3)
        x = (x or k5) - (x and k5) : x = (x or z) - (x and z) : k5 = (x or w) - (x and w)
        x = ((k15 << 1) and 255) + (k15 >> 7) : z = ((k1 << 6) and 255) + (k1 >> 2) : w = ((k5 << 5) and 255) + (k5 >> 3)
        x = (x or k6) - (x and k6) : x = (x or z) - (x and z) : k6 = (x or w) - (x and w)
        x = ((k0 << 1) and 255) + (k0 >> 7) : z = ((k2 << 6) and 255) + (k2 >> 2) : w = ((k6 << 5) and 255) + (k6 >> 3)
        x = (x or k7) - (x and k7) : x = (x or z) - (x and z) : k7 = (x or w) - (x and w)
        x = ((k1 << 1) and 255) + (k1 >> 7) : z = ((k3 << 6) and 255) + (k3 >> 2) : w = ((k7 << 5) and 255) + (k7 >> 3)
        x = (x or k8) - (x and k8) : x = (x or z) - (x and z) : k8 = (x or w) - (x and w)
        x = ((k2 << 1) and 255) + (k2 >> 7) : z = ((k4 << 6) and 255) + (k4 >> 2) : w = ((k8 << 5) and 255) + (k8 >> 3)
        x = (x or k9) - (x and k9) : x = (x or z) - (x and z) : k9 = (x or w) - (x and w)
        x = ((k3 << 1) and 255) + (k3 >> 7) : z = ((k5 << 6) and 255) + (k5 >> 2) : w = ((k9 << 5) and 255) + (k9 >> 3)
        x = (x or k10) - (x and k10) : x = (x or z) - (x and z) : k10 = (x or w) - (x and w)
        x = ((k4 << 1) and 255) + (k4 >> 7) : z = ((k6 << 6) and 255) + (k6 >> 2) : w = ((k10 << 5) and 255) + (k10 >> 3)
        x = (x or k11) - (x and k11) : x = (x or z) - (x and z) : k11 = (x or w) - (x and w)
        x = ((k5 << 1) and 255) + (k5 >> 7) : z = ((k7 << 6) and 255) + (k7 >> 2) : w = ((k11 << 5) and 255) + (k11 >> 3)
        x = (x or k12) - (x and k12) : x = (x or z) - (x and z) : k12 = (x or w) - (x and w)
        x = ((k6 << 1) and 255) + (k6 >> 7) : z = ((k8 << 6) and 255) + (k8 >> 2) : w = ((k12 << 5) and 255) + (k12 >> 3)
        x = (x or k13) - (x and k13) : x = (x or z) - (x and z) : k13 = (x or w) - (x and w)
        x = ((k7 << 1) and 255) + (k7 >> 7) : z = ((k9 << 6) and 255) + (k9 >> 2) : w = ((k13 << 5) and 255) + (k13 >> 3)
        x = (x or k14) - (x and k14) : x = (x or z) - (x and z) : k14 = (x or w) - (x and w)
        x = ((k8 << 1) and 255) + (k8 >> 7) : z = ((k10 << 6) and 255) + (k10 >> 2) : w = ((k14 << 5) and 255) + (k14 >> 3)
        x = (x or k15) - (x and k15) : x = (x or z) - (x and z) : k15 = (x or w) - (x and w)
    end for
    return [k0, k1, k2, k3, k4, k5, k6, k7, k8, k9, k10, k11, k12, k13, k14, k15]
end function

function fp_bytes_to_array(b as object) as object
    a = CreateObject("roArray", b.Count(), false)
    for each v in b
        a.push(v)
    end for
    return a
end function

' hand_garble.c garble(), statement by statement. All buffers hold bytes 0..255.
' C promotes to int / unsigned int; only the low 8 bits of each stored result matter,
' and the few places where a C intermediate leaves the 32-bit signed range are
' reduced mod 256 first (marked "low byte").
sub fp_garble(b0 as object, b1 as object, b2 as object, b3 as object, b4 as object)
    b2[12] = (&H14 + (((b1[64] and 92) or ((b1[99] \ 3) and 35)) and b4[fp_rol8x(b4[b1[206] mod 21], 4) mod 21])) and 255
    b1[4] = ((b1[99] \ 5) * (b1[99] \ 5) * 2) and 255
    b2[34] = &HB8
    x1 = b2[b1[203] mod 35]
    b1[153] = fp_x(b1[153], x1 * x1 * b1[190]) and 255
    b0[3] = (b0[3] - (((b4[b1[205] mod 21] >> 1) and 80) or &HE6440)) and 255
    b0[16] = &H93
    b0[13] = &H62
    b1[33] = (b1[33] - (b4[b1[36] mod 21] and &HF6)) and 255
    tmp2 = b2[b1[67] mod 35]
    b2[12] = 7
    tmp = b0[b1[181] mod 20]
    b1[2] = (b1[2] - 3136) and 255
    b0[19] = b4[b1[58] mod 21]
    b3[0] = (92 - b2[b1[32] mod 35]) and 255
    b3[4] = (b2[b1[15] mod 35] + &H9E) and 255
    b1[34] = (b1[34] + (b4[((b2[b1[15] mod 35] + &H9E) and 255) mod 21] \ 5)) and 255
    b0[19] = (b0[19] + &HFFFFFEE6 - ((b0[b3[4] mod 20] >> 1) and 102)) and 255

    x1 = b4[b1[190] mod 21]
    x2 = fp_x(b1[72] >> (x1 and 7), b1[72] << ((7 - (x1 - 1)) and 7))
    b1[15] = fp_x(3 * (x2 - 3 * b4[b1[126] mod 21]), b1[15]) and 255

    x1 = b2[b1[181] mod 35]
    b0[15] = fp_x(b0[15], x1 * x1 * x1) and 255
    b2[4] = fp_x(b2[4], b1[202] \ 3) and 255

    vA = 92 - b0[b3[0] mod 20]
    vE = ((vA and &HC6) or ((not b1[105]) and &HC6) or (vA and (not b1[105]))) and 255   ' low byte
    b2[1] = (b2[1] + vE * vE * vE) and 255

    b0[19] = fp_x(b0[19], ((224 or (b4[b1[92] mod 21] and 27)) * b2[b1[41] mod 35]) \ 3) and 255
    b1[140] = (b1[140] + fp_wror8(92, b1[5] and 7)) and 255

    x1 = fp_x((not b1[4]), b2[b1[12] mod 35])
    b2[12] = (b2[12] + (((x1 or b1[182]) and 192) or (x1 and b1[182]))) and 255

    b1[36] = (b1[36] + 125) and 255

    x1 = (74 and b1[138]) or ((74 or b1[138]) and b0[15])
    x2 = b0[b1[43] mod 20]
    b1[124] = fp_rol8x(((x1 and x2) or ((x1 or x2) and 95)) and 255, 4) and 255

    b3[8] = fp_x(((b0[b3[4] mod 20] and 95) and ((b4[b1[68] mod 21] and 46) << 1)) or 16, 92)

    vA = b1[177] + b4[b1[79] mod 21]
    x1 = (3 * b1[148]) \ 5
    vD = (((vA >> 1) or x1) and b2[1]) or ((vA >> 1) and x1)
    b3[12] = (-34 - vD) and 255

    vA = 8 - (b2[22] and 7)
    vB = b1[33] >> (vA and 7)
    vC = b1[33] << (b2[22] and 7)
    b2[16] = (b2[16] + (((b2[b3[0] mod 35] and 159) or b0[b3[4] mod 20] or 8) - (fp_x(vB, vC) or 128))) and 255

    b0[14] = fp_x(b0[14], b2[b3[12] mod 35])

    vA = fp_wrol8(b4[b0[b1[201] mod 20] mod 21], (b2[b1[112] mod 35] << 1) and 7)
    vD = (b0[b1[208] mod 20] and 131) or (b0[b1[164] mod 20] and 124)
    b1[19] = (b1[19] + ((vA and (vD \ 5)) or ((vA or (vD \ 5)) and 37))) and 255

    x1 = b4[b1[45] mod 21] + 92
    b2[8] = fp_wror8(140, (x1 * x1) and 7) and 255
    b1[190] = 56
    b2[8] = fp_x(b2[8], b3[0])
    b1[53] = (not ((b0[b1[83] mod 20] or 204) \ 5)) and 255
    b0[13] = (b0[13] + b0[b1[41] mod 20]) and 255

    x1 = b2[b3[0] mod 35]
    b0[10] = ((x1 and b1[2]) or ((x1 or b1[2]) and b3[12])) \ 15

    x1 = b4[b1[2] mod 21] and 68
    x2 = b2[b3[8] mod 35]
    vA = (((56 or x1) or x2) and 42) or ((x1 or 56) and x2)
    b3[16] = (vA * vA + 110) and 255
    b3[20] = (202 - b3[16]) and 255
    b3[24] = b1[151]
    b2[13] = fp_x(b2[13], b4[b3[0] mod 21])

    x1 = b2[b1[179] mod 35] - 38
    vB = (x1 and 177) or (b3[12] and 177)
    vC = x1 and b3[12]
    b3[28] = (30 + (vB or vC) * (vB or vC)) and 255
    b3[32] = (b3[28] + 62) and 255

    x1 = b3[20] + (b3[0] and 74)
    x2 = not b4[b3[0] mod 21]
    vA = (x1 or x2) and 121
    vB = x1 and x2
    tmp3 = vA or vB
    x1 = fp_x(tmp3, &HFFFFFFA6)
    vC = ((x1 or b3[0]) and 4) or (x1 and b3[0])
    b1[47] = fp_x(b2[b1[89] mod 35] + vC, b1[47]) and 255

    b3[36] = (((fp_rol8((tmp and 179) + 68, 2) and b0[3]) or (tmp2 and (not b0[3]))) - 15) and 255
    b1[123] = fp_x(b1[123], 221)

    vA = (b4[b3[0] mod 21] \ 3) - b2[b3[4] mod 35]
    vC = (((b3[0] and 163) + 92) and 246) or (b3[0] and 92)
    vE = ((vC or b3[24]) and 54) or (vC and b3[24])
    b3[40] = (vA - vE) and 255
    b3[44] = fp_x(fp_x(tmp3, 81), ((b3[0] >> 1) and 101) + 26) and 255
    b3[48] = b2[b3[4] mod 35] and 27
    b3[52] = 27
    b3[56] = 199

    x1 = ((b3[40] or b3[24]) and 177) or (b3[40] and b3[24])
    x2 = ((b4[b3[0] mod 20] and 177) or 176) or (b4[b3[0] mod 21] and (not 3))
    x3 = (x1 and 199) or ((((b4[b3[0] mod 21] and 1) + 176) or (b4[b3[0] mod 21] and (not 3))) and b3[56])
    b3[64] = (b3[4] + ((((x1 and x2) or x3) and (not b3[52])) or b3[48])) and 255

    b2[33] = fp_x(b2[33], b1[26])
    b1[106] = fp_x(fp_x(b1[106], b3[20]), 133)
    b2[30] = fp_x((b3[64] \ 3) - (275 or (b3[0] and 247)), b0[b1[122] mod 20]) and 255
    b1[22] = (b2[b1[90] mod 35] and 95) or 68

    vA = (b4[b3[36] mod 21] and 184) or (b2[b3[44] mod 35] and (not 184))
    b2[18] = (b2[18] + ((vA * vA * vA) >> 1)) and 255
    b2[5] = (b2[5] - b4[b1[92] mod 21]) and 255

    vA = (((b1[41] and (not 24)) or (b2[b1[183] mod 35] and 24)) and (b3[16] + 53)) or (b3[20] and b2[b3[20] mod 35])
    vB = (b1[17] and (not b3[44])) or (b0[b1[59] mod 20] and b3[44])
    b2[18] = fp_x(b2[18], vA * vB) and 255

    vA = fp_wror8(b1[11], b2[b1[28] mod 35] and 7) and 7
    vB = (((b0[b1[93] mod 20] and (not b0[14])) or (b0[14] and 150)) and (not 28)) or (b1[7] and 28)
    x1 = fp_wrol8(b2[b3[0] mod 35], vA)
    b2[22] = ((((vB or x1) and b2[33]) or (vB and x1)) + 74) and 255

    vA = b4[fp_x(b0[b1[39] mod 20], 217) mod 21]
    x1 = ((b3[20] or b3[0]) and 214) or (b3[20] and b3[0])
    b0[15] = (b0[15] - ((x1 and vA) or ((x1 or vA) and b3[32]))) and 255

    x1 = b2[b1[57] mod 35]
    x2 = b0[b3[64] mod 20]
    vB = ((x1 and x2) or ((x2 or x1) and 95) or (b3[64] and 45) or 82) and 32
    vC = ((x1 and x2) or ((x1 or x2) and 95)) and ((b3[64] and 45) or 82)
    vD = fp_x(fp_x((b3[0] \ 3) - (b3[64] or b1[22]), b3[28] + 62), vB or vC)
    vT = b0[(vD and 255) mod 20]

    x1 = b0[b1[99] mod 20]
    x1 = (x1 * x1) and 255                       ' low byte of x^4
    b3[68] = ((x1 * x1) or b2[b3[64] mod 35]) and 255

    vU = b0[b1[50] mod 20]
    vW = b2[b1[138] mod 35]
    vX = b4[b1[39] mod 21]
    vY = b0[b1[4] mod 20]
    vZ = b4[b1[202] mod 21]
    vV = b0[b1[151] mod 20]
    vS = b2[b1[14] mod 35]
    vR = b0[b1[145] mod 20]

    x1 = b2[b3[68] mod 35]
    x2 = b0[b1[209] mod 20]
    vA = (x1 and x2) or ((x1 or x2) and 24)
    vB = fp_wrol8(b4[b1[127] mod 21], x1 and 7)
    vC = (vA and b0[10]) or (vB and (not b0[10]))
    vD = fp_x(7, b4[b2[b3[36] mod 35] mod 21] << 1)
    b3[72] = ((vC and 71) or (vD and (not 71))) and 255

    b2[2] = (b2[2] + ((((b0[b3[20] mod 20] << 1) and 159) or (b4[b1[190] mod 21] and (not 159))) and ((((b4[b3[64] mod 21] and 110) or (b0[b1[25] mod 20] and (not 110))) and (not 150)) or (b1[25] and 150)))) and 255
    b2[14] = (b2[14] - (((b2[b3[20] mod 35] and fp_x(b3[72], b2[b1[100] mod 35])) and (not 34)) or (b1[97] and 34))) and 255
    b0[17] = 115

    x1 = b4[b1[17] mod 21]
    x2 = b0[b3[20] mod 20]
    x3 = ((x1 or x2) and b3[72]) or (x1 and x2)
    x1 = b1[50] \ 3
    b1[23] = fp_x(b1[23], ((x3 and x1) or ((x3 or x1) and 246)) << 1) and 255

    x1 = b0[b3[40] mod 20]
    b0[13] = (((((x1 or b1[10]) and 82) or (x1 and b1[10])) and 209) or ((b0[b1[39] mod 20] << 1) and 46)) >> 1

    b2[33] = (b2[33] - (b1[113] and 9)) and 255
    b2[28] = (b2[28] - ((((2 or (b1[110] and 222)) >> 1) and (not 223)) or (b3[20] and 223))) and 255

    vJ = fp_wrol8(vV or vZ, vU and 7)
    vA = (b2[16] and vT) or (vW and (not b2[16]))
    vB = (b1[33] and 17) or (vX and (not 17))
    x1 = (vA + vB) \ 5
    vE = ((vY or x1) and 147) or (vY and x1)
    x2 = b4[((b3[8] + vJ + vE) and 255) mod 21]
    vM = (b3[40] and x2) or ((b3[40] or x2) and b2[23])

    x1 = b4[b3[20] mod 21] - 48
    b0[15] = (((x1 and (not b1[184])) or (x1 and 189) or (189 and (not b1[184]))) and (vM * vM * vM)) and 255
    b2[22] = (b2[22] + b1[183]) and 255
    b3[76] = fp_x(3 * b4[b1[1] mod 21], b3[0]) and 255

    vA = b2[((b3[8] + (vJ + vE)) and 255) mod 35]
    x1 = b4[b1[178] mod 21]
    vF = (((x1 and vA) or ((x1 or vA) and 209)) * b0[b1[13] mod 20]) * (b4[b1[26] mod 21] >> 1)
    x1 = (vF + &HF9) and 255                     ' low byte of F + 0x733ffff9
    vG = x1 * 198 - ((x1 * 396 + 212) and 212) + 85   ' low byte of G is exact
    b3[80] = (b3[36] + fp_x(vG, 148) + (fp_x(vG, 107) << 1) - 127) and 255

    b3[84] = (b2[b3[64] mod 35] and 245) or (b2[b3[20] mod 35] and 10)

    vA = b0[b3[68] mod 20] or 81
    b2[18] = (b2[18] - (((vA * vA * vA) and (not b0[15])) or ((b3[80] \ 15) and b0[15]))) and 255

    x1 = b3[8] + vJ + vE
    b3[88] = (x1 - b0[b1[160] mod 20] + (b4[b0[(x1 and 255) mod 20] mod 21] \ 3)) and 255

    vB = (fp_x(vR, b3[72]) and (not 198)) or ((vS * vS) and 198)
    x1 = b4[b1[69] mod 21]
    vF = (x1 and b1[172]) or ((x1 or b1[172]) and ((b3[12] - vB) + 77))
    b0[16] = (147 - ((b3[72] and ((vF and 251) or 1)) or (((vF and 250) or b3[72]) and 198))) and 255

    x1 = b4[b1[168] mod 21]
    x2 = b0[b1[29] mod 20]
    vC = (x1 and x2 and 7) or ((x1 or x2) and 6)
    x1 = b4[b1[155] mod 21]
    vF = (x1 and b1[105]) or ((x1 or b1[105]) and 141)
    b0[3] = (b0[3] - b4[fp_wrol32(vF, vC) mod 21]) and 255

    ' ((~b) & 0xffffffff) / 5 = 858993459 - ceil(b / 5); 858993459 = 0x33333333
    x1 = (51 - (b2[b3[84] mod 35] + 4) \ 5) and 255   ' low byte
    b1[5] = fp_x(fp_wror8(b0[12], (b0[b1[61] mod 20] \ 5) and 7), x1) and 255

    b1[198] = (b1[198] + b1[3]) and 255
    vA = 162 or b2[b3[64] mod 35]
    b1[164] = (b1[164] + (vA * vA) \ 5) and 255

    vG = fp_wror8(139, b3[80] and 7)
    x1 = b4[b3[64] mod 21]
    vC = ((x1 * x1 * x1) and 95) or (b0[b3[40] mod 20] and (not 95))
    x2 = b0[b3[20] mod 20]
    b3[92] = ((vG and 12) or (x2 and 12) or (vG and x2) or vC) and 255
    b2[12] = (b2[12] + ((b1[103] and 32) or (b3[92] and (b1[103] or 60)) or 16) \ 3) and 255
    b3[96] = b1[143]
    b3[100] = 27
    x1 = ((b3[40] and (not b2[8])) or (b1[35] and b2[8])) and b3[64]
    b3[104] = fp_x(x1, 119)
    b3[108] = 238 and (x1 << 1)
    x2 = (not b3[64]) and (b3[84] \ 3)
    b3[112] = fp_x(x2, 49)
    b3[116] = 98 and (x2 << 1)

    vA = (b1[35] and b2[8]) or (b3[40] and (not b2[8]))
    vB = (vA and b3[64]) or ((b3[84] \ 3) and (not b3[64]))
    b1[143] = (b3[96] - ((vB and (86 + ((b1[172] and 64) >> 1))) or ((fp_x((b1[172] and 65) >> 1, 86) or (x2 or x1)) and b3[100]))) and 255
    b2[29] = 162

    vA = ((b4[b3[88] mod 21] and 160) or (b0[b1[125] mod 20] and 95)) >> 1
    vB = fp_x(b2[b1[149] mod 35], b1[43] * b1[43])
    b0[15] = (b0[15] + ((vB and vA) or ((vA or vB) and 115))) and 255
    b3[120] = (b3[64] - b0[b3[40] mod 20]) and 255
    b1[95] = b4[b3[20] mod 21]

    x1 = b2[b1[17] mod 35]
    vA = fp_wror8(b2[b3[80] mod 35], (x1 * x1 * x1) and 7) and 255   ' low byte
    b0[7] = (b0[7] - vA * vA) and 255

    x1 = b4[b1[202] mod 21]
    b2[8] = (b2[8] - b1[184] + x1 * x1 * x1) and 255
    b0[16] = (b2[b1[102] mod 35] << 1) and 132
    b3[124] = fp_x(b4[b3[40] mod 21] >> 1, b3[68])
    b0[7] = (b0[7] - (b0[b1[191] mod 20] - (((b4[b1[80] mod 21] << 1) and (not 177)) or (b4[b4[b3[88] mod 21] mod 21] and 177)))) and 255
    b0[6] = b0[b1[119] mod 20]

    vA = (b4[b1[190] mod 21] and (not 209)) or (b1[118] and 209)
    x1 = b0[b3[120] mod 20]
    vB = x1 * x1
    b0[12] = (fp_x(b0[b3[84] mod 20], b2[b1[71] mod 35] + b2[b1[15] mod 35]) and ((vA and vB) or ((vA or vB) and 27))) and 255

    x1 = b2[b3[88] mod 35]
    vB = (b1[32] and x1) or ((b1[32] or x1) and 23)
    vD = ((b4[b1[57] mod 21] * 231) and 169) or (vB and 86)
    vF = (((b0[b1[82] mod 20] and (not 29)) or (b4[b3[124] mod 21] and 29)) and 190) or (b4[(vD \ 5) mod 21] and (not 190))
    x1 = b0[b3[40] mod 20]
    vH = x1 * x1 * x1
    vK = (vH and b1[82]) or (vH and 92) or (b1[82] and 92)
    b3[128] = fp_x((vF and vK) or ((vF or vK) and 192), vD \ 5) and 255

    x1 = fp_wrol8(b3[76], b4[b3[124] mod 21] and 7) and (b3[20] + 110)
    b2[25] = fp_x(b2[25], ((b0[b3[120] mod 20] << 1) * b1[5]) - x1) and 255
end sub

' ------------------------------------------------------------------ AES-like core

' generate_key_schedule(key16) -> 176 bytes (11 rounds x 16), byte view of the words
function fp_key_schedule(t as object, km as object) as object
    s1 = t.table_s1
    so = t.s1off
    tk = t.t_key
    im = t.index_mangle
    b = CreateObject("roArray", 16, false)
    for i = 0 to 15
        b.push(fp_x(km[i], tk[i]))
    end for
    ks = fp_zeros(176)
    ti = 0
    for r = 0 to 10
        o = r * 16
        for i = 0 to 3
            ks[o + i] = b[i]
        end for
        b[0] = fp_x(fp_x(b[0], s1[so[ti] + b[13]]), im[r])
        b[1] = fp_x(b[1], s1[so[ti + 1] + b[14]])
        b[2] = fp_x(b[2], s1[so[ti + 2] + b[15]])
        b[3] = fp_x(b[3], s1[so[ti + 3] + b[12]])
        ti = ti + 4
        for i = 4 to 15
            ks[o + i] = b[i]
            b[i] = fp_x(b[i], b[i - 4])
        end for
    end for
    return ks
end function

' cycle(block, key_schedule); block: roArray of 16 bytes, modified in place
sub fp_cycle(t as object, blk as object, ks as object)
    s3 = t.table_s3
    s4 = t.table_s4
    s4o = t.s4off
    s5 = t.table_s5
    s6 = t.table_s6
    s7 = t.table_s7
    s8 = t.table_s8
    srcp = [0, 13, 10, 7, 4, 1, 14, 11, 8, 5, 2, 15, 12, 9, 6, 3]
    n = fp_zeros(16)
    for i = 0 to 15
        blk[i] = fp_x(blk[i], ks[160 + i])
    end for
    ' permute_block_1: unlike the other permutations, the table_s3 slice used for
    ' destination p is (5 * p) mod 16 (block[13] = table_s3[0x100 + block[9]], ...)
    for p = 0 to 15
        n[p] = s3[((5 * p) and 15) * 256 + blk[srcp[p]]]
    end for
    for r = 0 to 8
        ko = (9 - r) * 16
        for w = 0 to 12 step 4
            v = fp_x(fp_x(s5[fp_x(n[w + 3], ks[ko + w + 3])], s6[fp_x(n[w + 2], ks[ko + w + 2])]), fp_x(s7[fp_x(n[w + 1], ks[ko + w + 1])], s8[fp_x(n[w], ks[ko + w])]))
            blk[w] = v and 255
            blk[w + 1] = (v >> 8) and 255
            blk[w + 2] = (v >> 16) and 255
            blk[w + 3] = (v >> 24) and 255
        end for
        ro = (8 - r) * 16
        for p = 0 to 15
            n[p] = s4[s4o[ro + p] + blk[srcp[p]]]
        end for
    end for
    for i = 0 to 15
        blk[i] = fp_x(n[i], ks[i])
    end for
end sub
