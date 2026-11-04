' Binary property list (bplist00) reader and writer.
'
' Reader returns BrightScript values: roAssociativeArray (dict, keys looked up
' case-insensitively), roArray, String, roByteArray (data), Integer or
' LongInteger, Double, Boolean, invalid (null/unknown).
'
' Writer takes an ordered value model built with the pl_* constructors, so key
' case and order are preserved exactly:
'   d = pl_dict() : pl_set(d, "deviceID", "AA:BB:...") : pl_set(d, "vv", 2)
'   values: String, Integer, LongInteger, Boolean, roByteArray, pl_dict(),
'   pl_array([...]), pl_real_hex("3F91111111111111") (IEEE754 big-endian).

' ------------------------------------------------------------------ reader

function plist_parse(b as object) as dynamic
    n = b.Count()
    if n < 40 then return invalid
    if b[0] <> &H62 or b[1] <> &H70 or b[2] <> &H6C then return invalid
    t = n - 32
    offSize = b[t + 6]
    refSize = b[t + 7]
    numObj = pl_readint(b, t + 8, 8)
    top = pl_readint(b, t + 16, 8)
    otOff = pl_readint(b, t + 24, 8)
    ctx = {b: b, offSize: offSize, refSize: refSize, numObj: numObj, otOff: otOff, depth: 0}
    return pl_obj(ctx, top)
end function

function pl_readint(b as object, off as integer, size as integer) as dynamic
    if size <= 3 then
        v = 0
        for i = 0 to size - 1
            v = (v << 8) or b[off + i]
        end for
        return v
    end if
    v& = 0&
    for i = 0 to size - 1
        v& = v& * 256& + b[off + i]
    end for
    if v& >= 0& and v& <= 2147483647& then
        r% = v&
        return r%
    end if
    return v&
end function

function pl_offset(ctx as object, idx as integer) as integer
    return pl_readint(ctx.b, ctx.otOff + idx * ctx.offSize, ctx.offSize)
end function

' returns {len, start} for objects with the 4-bit length nibble
function pl_len(ctx as object, off as integer) as object
    b = ctx.b
    l = b[off] and 15
    if l <> 15 then return {len: l, start: off + 1}
    m = b[off + 1]
    sz = 1 << (m and 15)
    return {len: pl_readint(b, off + 2, sz), start: off + 2 + sz}
end function

function pl_obj(ctx as object, idx as integer) as dynamic
    if idx < 0 or idx >= ctx.numObj or ctx.depth > 32 then return invalid
    b = ctx.b
    off = pl_offset(ctx, idx)
    marker = b[off]
    hi = marker >> 4
    if marker = &H08 then return false
    if marker = &H09 then return true
    if marker = &H00 then return invalid
    if hi = 1 then
        size = 1 << (marker and 15)
        if size = 8 then
            return pl_readint(b, off + 1, 8)
        else if size = 16 then
            return pl_readint(b, off + 9, 8)
        end if
        return pl_readint(b, off + 1, size)
    else if hi = 2 then
        return pl_real(b, off + 1, 1 << (marker and 15))
    else if hi = 3 then
        return pl_real(b, off + 1, 8)
    else if hi = 4 then
        L = pl_len(ctx, off)
        return ba_slice(b, L.start, L.len)
    else if hi = 5 then
        L = pl_len(ctx, off)
        return ba_slice(b, L.start, L.len).ToAsciiString()
    else if hi = 6 then
        L = pl_len(ctx, off)
        s = ""
        for i = 0 to L.len - 1
            c = (b[L.start + i * 2] << 8) or b[L.start + i * 2 + 1]
            if c < 128 then
                s = s + Chr(c)
            else
                s = s + "?"
            end if
        end for
        return s
    else if hi = 8 then
        return pl_readint(b, off + 1, (marker and 15) + 1)
    else if hi = 10 then
        L = pl_len(ctx, off)
        arr = []
        ctx.depth = ctx.depth + 1
        for i = 0 to L.len - 1
            arr.push(pl_obj(ctx, pl_readint(b, L.start + i * ctx.refSize, ctx.refSize)))
        end for
        ctx.depth = ctx.depth - 1
        return arr
    else if hi = 13 then
        L = pl_len(ctx, off)
        d = {}
        ctx.depth = ctx.depth + 1
        for i = 0 to L.len - 1
            k = pl_obj(ctx, pl_readint(b, L.start + i * ctx.refSize, ctx.refSize))
            v = pl_obj(ctx, pl_readint(b, L.start + (L.len + i) * ctx.refSize, ctx.refSize))
            if k <> invalid then d[lstr(k)] = v
        end for
        ctx.depth = ctx.depth - 1
        return d
    end if
    return invalid
end function

' IEEE754 big-endian float/double -> Double
function pl_real(b as object, off as integer, size as integer) as double
    if size = 4 then
        sign = b[off] >> 7
        ex = ((b[off] and 127) << 1) or (b[off + 1] >> 7)
        mant# = ((b[off + 1] and 127) * 65536# + b[off + 2] * 256# + b[off + 3]) / 8388608#
        bias = 127
    else
        sign = b[off] >> 7
        ex = ((b[off] and 127) << 4) or (b[off + 1] >> 4)
        mant# = (b[off + 1] and 15) * 1#
        for i = 2 to 7
            mant# = mant# * 256# + b[off + i]
        end for
        mant# = mant# / 4503599627370496#
        bias = 1023
    end if
    if ex = 0 and mant# = 0# then return 0#
    v# = (1# + mant#) * (2# ^ (ex - bias))
    if sign = 1 then v# = -v#
    return v#
end function

' ------------------------------------------------------------------ writer

function pl_dict() as object
    return {pltype: "dict", keys: [], vals: []}
end function

sub pl_set(d as object, k as string, v as dynamic)
    d.keys.push(k)
    d.vals.push(v)
end sub

function pl_array(items as object) as object
    return {pltype: "array", items: items}
end function

function pl_real_hex(h as string) as object
    return {pltype: "real", hex: h}
end function

function plist_build(root as dynamic) as object
    w = {objs: []}
    pl_flatten(w, root)
    count = w.objs.Count()
    refSize = 1
    if count > 255 then refSize = 2
    body = CreateObject("roByteArray")
    body.FromAsciiString("bplist00")
    offsets = []
    for i = 0 to count - 1
        offsets.push(body.Count())
        pl_encode(body, w.objs[i], refSize)
    end for
    otOff = body.Count()
    offSize = 1
    if otOff > 255 then offSize = 2
    if otOff > 65535 then offSize = 4
    for each o in offsets
        pl_putint(body, o, offSize)
    end for
    for i = 1 to 6
        body.push(0)
    end for
    body.push(offSize)
    body.push(refSize)
    pl_putint(body, count, 8)
    pl_putint(body, 0, 8)
    pl_putint(body, otOff, 8)
    return body
end function

sub pl_putint(b as object, v as dynamic, size as integer)
    v& = v + 0&
    tmp = []
    for i = 1 to size
        lo& = v& and 255&
        tmp.unshift(lo&)
        v& = (v& - lo&) \ 256&
    end for
    for each x in tmp
        b.push(x)
    end for
end sub

' Flattens the value tree into w.objs (index 0 = root); containers get ref lists.
function pl_flatten(w as object, v as dynamic) as integer
    idx = w.objs.Count()
    t = type(v)
    if t = "roAssociativeArray" and v.pltype = "dict" then
        node = {kind: "dict", refs: []}
        w.objs.push(node)
        krefs = []
        vrefs = []
        for i = 0 to v.keys.Count() - 1
            krefs.push(pl_flatten(w, v.keys[i]))
        end for
        for i = 0 to v.vals.Count() - 1
            vrefs.push(pl_flatten(w, v.vals[i]))
        end for
        node.krefs = krefs
        node.vrefs = vrefs
    else if t = "roAssociativeArray" and v.pltype = "array" then
        node = {kind: "array", refs: []}
        w.objs.push(node)
        for each it in v.items
            node.refs.push(pl_flatten(w, it))
        end for
    else
        w.objs.push({kind: "leaf", v: v})
    end if
    return idx
end function

sub pl_lenmarker(b as object, hi as integer, n as integer)
    if n < 15 then
        b.push((hi << 4) or n)
    else
        b.push((hi << 4) or 15)
        if n < 256 then
            b.push(&H10)
            b.push(n)
        else
            b.push(&H11)
            ba_push_u16be(b, n)
        end if
    end if
end sub

sub pl_encode(b as object, o as object, refSize as integer)
    if o.kind = "dict" then
        n = o.krefs.Count()
        pl_lenmarker(b, 13, n)
        for each r in o.krefs
            pl_putint(b, r, refSize)
        end for
        for each r in o.vrefs
            pl_putint(b, r, refSize)
        end for
        return
    else if o.kind = "array" then
        pl_lenmarker(b, 10, o.refs.Count())
        for each r in o.refs
            pl_putint(b, r, refSize)
        end for
        return
    end if
    v = o.v
    t = type(v)
    if t = "roBoolean" or t = "Boolean" then
        if v then b.push(&H09) else b.push(&H08)
    else if t = "roInt" or t = "Integer" or t = "roInteger" or t = "LongInteger" or t = "roLongInteger" then
        v& = v + 0&
        if v& < 0& then
            b.push(&H13) : pl_putint(b, v&, 8)
        else if v& < 256& then
            b.push(&H10) : pl_putint(b, v&, 1)
        else if v& < 65536& then
            b.push(&H11) : pl_putint(b, v&, 2)
        else if v& < 4294967296& then
            b.push(&H12) : pl_putint(b, v&, 4)
        else
            b.push(&H13) : pl_putint(b, v&, 8)
        end if
    else if t = "roString" or t = "String" then
        bytes = ba_ascii(v)
        pl_lenmarker(b, 5, bytes.Count())
        b.Append(bytes)
    else if t = "roByteArray" then
        pl_lenmarker(b, 4, v.Count())
        b.Append(v)
    else if t = "roAssociativeArray" and v.pltype = "real" then
        b.push(&H23)
        b.Append(ba_hex(v.hex))
    else
        b.push(&H00)
    end if
end sub
