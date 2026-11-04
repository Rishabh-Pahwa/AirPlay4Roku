' H.264 "skip frame" support (port of test/h264/h264tool.py, which is
' verified with ffmpeg: every generated frame decodes to exactly the previous
' picture and real frames are unchanged).
'
' While the iPhone screen is still, iOS sends no video frames, so the Roku
' player runs dry and rebuffers. The receiver fills gaps with non-reference
' P slices in which every macroblock is P_Skip (a repeat of the last picture),
' and shifts pic_order_cnt_lsb of later real frames so display order stays
' increasing. Supported: pic_order_cnt_type 0, frame_mbs_only, one slice
' group, CABAC or CAVLC (iOS uses High profile, CABAC, POC type 0).

' ---------------------------------------------------------------- bit I/O

function h264_unescape(b as object, start as integer, n as integer) as object
    out = CreateObject("roByteArray")
    z = 0
    for i = start to start + n - 1
        x = b[i]
        if z >= 2 and x = 3 then
            z = 0
        else
            out.push(x)
            if x = 0 then z = z + 1 else z = 0
        end if
    end for
    return out
end function

function h264_escape(b as object) as object
    out = CreateObject("roByteArray")
    z = 0
    for i = 0 to b.Count() - 1
        x = b[i]
        if z >= 2 and x <= 3 then
            out.push(3)
            z = 0
        end if
        out.push(x)
        if x = 0 then z = z + 1 else z = 0
    end for
    return out
end function

function br_new(b as object) as object
    return {b: b, p: 0}
end function

function br_u(r as object, n as integer) as integer
    v = 0
    for i = 1 to n
        k = r.p
        v = (v << 1) or ((r.b[k >> 3] >> (7 - (k and 7))) and 1)
        r.p = k + 1
    end for
    return v
end function

function br_ue(r as object) as integer
    z = 0
    while br_u(r, 1) = 0 and z < 31
        z = z + 1
    end while
    return (1 << z) - 1 + br_u(r, z)
end function

function br_se(r as object) as integer
    k = br_ue(r)
    if (k and 1) = 1 then return (k + 1) \ 2
    return -(k \ 2)
end function

function bw_new() as object
    return {bits: []}
end function

sub bw_u(w as object, v as integer, n as integer)
    for i = n - 1 to 0 step -1
        w.bits.push((v >> i) and 1)
    end for
end sub

sub bw_ue(w as object, v as integer)
    v = v + 1
    n = 0
    t = v
    while t > 0
        n = n + 1
        t = t >> 1
    end while
    bw_u(w, 0, n - 1)
    bw_u(w, v, n)
end sub

sub bw_se(w as object, v as integer)
    if v > 0 then bw_ue(w, 2 * v - 1) else bw_ue(w, -2 * v)
end sub

function bw_bytes(w as object) as object
    out = CreateObject("roByteArray")
    i = 0
    n = w.bits.Count()
    while i < n
        v = 0
        for j = 0 to 7
            bit = 0
            if i + j < n then bit = w.bits[i + j]
            v = (v << 1) or bit
        end for
        out.push(v)
        i = i + 8
    end while
    return out
end function

' ---------------------------------------------------------------- params

' avcc: avcC record. Returns invalid if the stream layout isn't supported.
function h264_params(avcc as object) as object
    if avcc.Count() < 8 then return invalid
    o = 6
    spsLen = ba_u16be(avcc, o)
    sps = h264_unescape(avcc, o + 3, spsLen - 1)
    o = o + 2 + spsLen
    o = o + 1
    ppsLen = ba_u16be(avcc, o)
    ppsNalHdr = avcc[o + 2]
    pps = h264_unescape(avcc, o + 3, ppsLen - 1)

    r = br_new(sps)
    profile = br_u(r, 8)
    br_u(r, 16)
    br_ue(r)
    if profile = 100 or profile = 110 or profile = 122 or profile = 244 or profile = 44 or profile = 83 or profile = 86 or profile = 118 or profile = 128 then
        cf = br_ue(r)
        if cf = 3 then br_u(r, 1)
        br_ue(r)
        br_ue(r)
        br_u(r, 1)
        if br_u(r, 1) = 1 then return invalid
    end if
    p = {}
    p.log2fn = br_ue(r) + 4
    p.pocType = br_ue(r)
    if p.pocType <> 0 then return invalid
    p.log2poc = br_ue(r) + 4
    br_ue(r)
    br_u(r, 1)
    wmbs = br_ue(r) + 1
    hmbs = br_ue(r) + 1
    if br_u(r, 1) <> 1 then return invalid
    p.mbs = wmbs * hmbs

    r = br_new(pps)
    p.ppsId = br_ue(r)
    br_ue(r)
    p.cabac = br_u(r, 1)
    if br_u(r, 1) <> 0 then return invalid
    if br_ue(r) <> 0 then return invalid
    br_ue(r)
    br_ue(r)
    if br_u(r, 1) <> 0 then return invalid
    br_u(r, 2)
    p.qp = 26 + br_se(r)
    br_se(r)
    br_se(r)
    p.dbk = br_u(r, 1)
    br_u(r, 1)
    if br_u(r, 1) <> 0 then return invalid

    if p.cabac = 1 then p.data = h264_skip_cabac(p.mbs, p.qp) else p.data = invalid
    p.maxFn = 1 << p.log2fn
    p.maxPoc = 1 << p.log2poc
    return p
end function

' ---------------------------------------------------------------- CABAC

function h264_range_lps() as object
    return [[128,176,208,240],[128,167,197,227],[128,158,187,216],[123,150,178,205],[116,142,169,195],[111,135,160,185],[105,128,152,175],[100,122,144,166],[95,116,137,158],[90,110,130,150],[85,104,123,142],[81,99,117,135],[77,94,111,128],[73,89,105,122],[69,85,100,116],[66,80,95,110],[62,76,90,104],[59,72,86,99],[56,69,81,94],[53,65,77,89],[51,62,73,85],[48,59,69,80],[46,56,66,76],[43,53,63,72],[41,50,59,69],[39,48,56,65],[37,45,54,62],[35,43,51,59],[33,41,48,56],[32,39,46,53],[30,37,43,50],[29,35,41,48],[27,33,39,45],[26,31,37,43],[24,30,35,41],[23,28,33,39],[22,27,32,37],[21,26,30,35],[20,24,29,33],[19,23,27,31],[18,22,26,30],[17,21,25,28],[16,20,23,27],[15,19,22,25],[14,18,21,24],[14,17,20,23],[13,16,19,22],[12,15,18,21],[12,14,17,20],[11,14,16,19],[11,13,15,18],[10,12,15,17],[10,12,14,16],[9,11,13,15],[9,11,12,14],[8,10,12,14],[8,9,11,13],[7,9,11,12],[7,9,10,12],[7,8,10,11],[6,8,9,11],[6,7,9,10],[6,7,8,9],[2,2,2,2]]
end function

' slice_data of an all-P_Skip slice (CABAC, cabac_init_idc 0), including
' the rbsp trailing bits, starting byte-aligned after the slice header.
function h264_skip_cabac(numMbs as integer, qp as integer) as object
    lps = h264_range_lps()
    q = qp
    if q < 0 then q = 0
    if q > 51 then q = 51
    pre = ((23 * q) >> 4) + 33
    if pre > 126 then pre = 126
    if pre < 64 then return invalid
    st = {state: pre - 64, low: 0, rng: 510, out: 0, first: true, bits: []}
    for i = 0 to numMbs - 1
        st.rng = st.rng - lps[st.state][(st.rng >> 6) and 3]
        if st.state < 62 then st.state = st.state + 1
        cab_renorm(st)
        st.rng = st.rng - 2
        if i = numMbs - 1 then
            st.low = st.low + st.rng
            st.rng = 2
            cab_renorm(st)
            cab_put(st, (st.low >> 9) and 1)
            st.bits.push((st.low >> 8) and 1)
            st.bits.push(1)
        else
            cab_renorm(st)
        end if
    end for
    while (st.bits.Count() mod 8) <> 0
        st.bits.push(0)
    end while
    return bw_bytes(st)
end function

sub cab_put(st as object, b as integer)
    if st.first then
        st.first = false
    else
        st.bits.push(b)
    end if
    while st.out > 0
        st.bits.push(1 - b)
        st.out = st.out - 1
    end while
end sub

sub cab_renorm(st as object)
    while st.rng < 256
        if st.low < 256 then
            cab_put(st, 0)
        else if st.low >= 512 then
            st.low = st.low - 512
            cab_put(st, 1)
        else
            st.low = st.low - 256
            st.out = st.out + 1
        end if
        st.rng = st.rng << 1
        st.low = st.low << 1
    end while
end sub

' ---------------------------------------------------------------- frames

' Complete non-reference all-skip P slice NAL (without length prefix)
function h264_skip_nal(p as object, frameNum as integer, pocLsb as integer) as object
    w = bw_new()
    bw_ue(w, 0)
    bw_ue(w, 5)
    bw_ue(w, p.ppsId)
    bw_u(w, frameNum, p.log2fn)
    bw_u(w, pocLsb, p.log2poc)
    bw_u(w, 0, 1)
    bw_u(w, 0, 1)
    if p.cabac = 1 then
        bw_ue(w, 0)
        bw_se(w, 0)
        if p.dbk = 1 then bw_ue(w, 1)
        while (w.bits.Count() mod 8) <> 0
            w.bits.push(1)
        end while
        body = bw_bytes(w)
        body.Append(p.data)
    else
        bw_se(w, 0)
        if p.dbk = 1 then bw_ue(w, 1)
        bw_ue(w, p.mbs)
        w.bits.push(1)
        while (w.bits.Count() mod 8) <> 0
            w.bits.push(0)
        end while
        body = bw_bytes(w)
    end if
    nal = CreateObject("roByteArray")
    nal.push(1)
    nal.Append(h264_escape(body))
    return nal
end function

' AVCC frame (4-byte length + NAL) for a skip picture
function h264_skip_frame(p as object, frameNum as integer, pocLsb as integer) as object
    nal = h264_skip_nal(p, frameNum, pocLsb)
    out = CreateObject("roByteArray")
    ba_push_u32be(out, nal.Count() + 0&)
    out.Append(nal)
    return out
end function

' Inspect (and if shift <> 0, rewrite) the slices of one AVCC access unit.
' Returns {data, isRef, frameNum, poc, idr} where poc is after shifting.
function h264_process_frame(p as object, d as object, shift as integer) as object
    res = {data: d, isRef: false, frameNum: -1, poc: -1, idr: false, changed: false}
    n = d.Count()
    off = 0
    parts = []
    b64 = invalid
    guard = 0
    while off + 5 <= n and guard < 64
        guard = guard + 1
        l& = ba_u32be(d, off)
        l% = l&
        nalStart = off + 4
        if l% <= 0 or nalStart + l% > n then exit while
        hdr = d[nalStart]
        t = hdr and 31
        if t = 1 or t = 5 then
            region = l% - 1
            if region > 16 then region = 16
            ' The rewritten region is re-escaped on its own, so it must not end
            ' on a zero byte or on an emulation-prevention 03 (the bytes after
            ' it are copied untouched).
            while region < l% - 1
                lb = d[nalStart + region]
                epb = (lb = 3 and region >= 3 and d[nalStart + region - 1] = 0 and d[nalStart + region - 2] = 0)
                if lb <> 0 and not epb then exit while
                region = region + 1
            end while
            rb = h264_unescape(d, nalStart + 1, region)
            r = br_new(rb)
            br_ue(r)
            br_ue(r)
            br_ue(r)
            fn = br_u(r, p.log2fn)
            if t = 5 then br_ue(r)
            pocPos = r.p
            poc = br_u(r, p.log2poc)
            if t = 5 then res.idr = true
            if (hdr and 96) <> 0 then res.isRef = true
            res.frameNum = fn
            newPoc = (poc + shift) mod p.maxPoc
            res.poc = newPoc
            if shift <> 0 then
                for i = 0 to p.log2poc - 1
                    bit = (newPoc >> (p.log2poc - 1 - i)) and 1
                    k = pocPos + i
                    mask = &H80 >> (k and 7)
                    if bit = 1 then
                        rb[k >> 3] = rb[k >> 3] or mask
                    else
                        rb[k >> 3] = rb[k >> 3] and (255 - mask)
                    end if
                end for
                newHead = CreateObject("roByteArray")
                newHead.push(hdr)
                newHead.Append(h264_escape(rb))
                restLen = l% - 1 - region
                if b64 = invalid then b64 = d.ToBase64String()
                nal = newHead
                if restLen > 0 then nal.Append(ba_slice(d, nalStart + 1 + region, restLen, b64))
                piece = CreateObject("roByteArray")
                ba_push_u32be(piece, nal.Count() + 0&)
                piece.Append(nal)
                parts.push(piece)
                res.changed = true
            else
                parts.push(invalid)
            end if
        else
            parts.push(invalid)
        end if
        parts.push({off: off, len: l% + 4})
        off = nalStart + l%
    end while
    if res.changed then
        if b64 = invalid then b64 = d.ToBase64String()
        out = CreateObject("roByteArray")
        i = 0
        while i < parts.Count()
            piece = parts[i]
            span = parts[i + 1]
            if piece <> invalid then
                out.Append(piece)
            else
                out.Append(ba_slice(d, span.off, span.len, b64))
            end if
            i = i + 2
        end while
        res.data = out
    end if
    return res
end function
