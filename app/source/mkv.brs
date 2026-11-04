' Live Matroska muxer (port of test/mkv_proto.py, which was validated on the
' device). Segment and Clusters use the "unknown size" encoding so the stream
' can be produced incrementally and never needs seeking or patching.
'
' AirPlay mirror payloads are already AVCC (4-byte length-prefixed NALs) and
' the codec-config payload is an avcC record, which is exactly what Matroska's
' V_MPEG4/ISO/AVC wants, so frames go in with no per-byte work.

function mkv_vint(n as integer) as object
    b = CreateObject("roByteArray")
    if n < 127 then
        b.push(&H80 or n)
    else if n < 16383 then
        b.push(&H40 or (n >> 8))
        b.push(n and 255)
    else if n < 2097151 then
        b.push(&H20 or (n >> 16))
        b.push((n >> 8) and 255)
        b.push(n and 255)
    else
        b.push(&H10 or ((n >> 24) and 15))
        b.push((n >> 16) and 255)
        b.push((n >> 8) and 255)
        b.push(n and 255)
    end if
    return b
end function

function mkv_el(idHex as string, payload as object) as object
    b = ba_hex(idHex)
    b.Append(mkv_vint(payload.Count()))
    b.Append(payload)
    return b
end function

function mkv_uint(idHex as string, v as dynamic) as object
    v& = v + 0&
    tmp = []
    while true
        lo& = v& mod 256&
        tmp.unshift(lo&)
        v& = v& \ 256&
        if v& = 0& then exit while
    end while
    p = CreateObject("roByteArray")
    for each x in tmp
        p.push(x)
    end for
    return mkv_el(idHex, p)
end function

function mkv_str(idHex as string, s as string) as object
    return mkv_el(idHex, ba_ascii(s))
end function

function mkv_cat(parts as object) as object
    b = CreateObject("roByteArray")
    for each p in parts
        b.Append(p)
    end for
    return b
end function

function mkv_ebml_header() as object
    return mkv_el("1A45DFA3", mkv_cat([mkv_uint("4286", 1), mkv_uint("42F7", 1), mkv_uint("42F2", 4), mkv_uint("42F3", 8), mkv_str("4282", "matroska"), mkv_uint("4287", 4), mkv_uint("4285", 2)]))
end function

function mkv_segment_start() as object
    ' Segment with unknown size, then Info (TimecodeScale = 1 ms)
    b = ba_hex("1853806701FFFFFFFFFFFFFF")
    b.Append(mkv_el("1549A966", mkv_cat([mkv_uint("2AD7B1", 1000000), mkv_str("4D80", "rokuairplay"), mkv_str("5741", "rokuairplay")])))
    return b
end function

' Header for a single H.264 video track (track number 1)
function mkv_video_header(w as integer, h as integer, avcc as object) as object
    video = mkv_el("E0", mkv_cat([mkv_uint("B0", w), mkv_uint("BA", h)]))
    track = mkv_el("AE", mkv_cat([mkv_uint("D7", 1), mkv_uint("73C5", 1), mkv_uint("83", 1), mkv_uint("9C", 0), mkv_str("86", "V_MPEG4/ISO/AVC"), mkv_el("63A2", avcc), video]))
    return mkv_cat([mkv_ebml_header(), mkv_segment_start(), mkv_el("1654AE6B", track)])
end function

' Header for a single ALAC audio track (track number 1)
function mkv_alac_header(spf as integer, rate as integer, channels as integer, bits as integer) as object
    cfg = CreateObject("roByteArray")
    ba_push_u32be(cfg, spf + 0&)
    cfg.push(0)
    cfg.push(bits)
    cfg.push(40)
    cfg.push(10)
    cfg.push(14)
    cfg.push(channels)
    ba_push_u16be(cfg, 255)
    ba_push_u32be(cfg, 0&)
    ba_push_u32be(cfg, 0&)
    ba_push_u32be(cfg, rate + 0&)
    ' SamplingFrequency is a float element: 44100.0 as IEEE754 double
    rateEl = ba_hex("B588")
    rateEl.Append(ba_hex(mkv_double_hex(rate)))
    audio = mkv_el("E1", mkv_cat([rateEl, mkv_uint("9F", channels), mkv_uint("6264", bits)]))
    track = mkv_el("AE", mkv_cat([mkv_uint("D7", 1), mkv_uint("73C5", 1), mkv_uint("83", 2), mkv_uint("9C", 0), mkv_str("86", "A_ALAC"), mkv_el("63A2", cfg), audio]))
    return mkv_cat([mkv_ebml_header(), mkv_segment_start(), mkv_el("1654AE6B", track)])
end function

function mkv_double_hex(rate as integer) as string
    if rate = 48000 then return "40E7700000000000"
    return "40E5888000000000"
end function

' Cluster with unknown size + Timecode (ms, absolute)
function mkv_cluster_start(tc as longinteger) as object
    b = ba_hex("1F43B67501FFFFFFFFFFFFFF")
    b.Append(mkv_uint("E7", tc))
    return b
end function

' SimpleBlock on track 1; rel = timecode relative to cluster (-32768..32767 ms)
function mkv_simple_block(rel as integer, key as boolean, data as object) as object
    n = data.Count() + 4
    b = CreateObject("roByteArray")
    b.push(&HA3)
    b.push(&H10 or ((n >> 24) and 15))
    b.push((n >> 16) and 255)
    b.push((n >> 8) and 255)
    b.push(n and 255)
    b.push(&H81)
    if rel < 0 then rel = rel + 65536
    b.push((rel >> 8) and 255)
    b.push(rel and 255)
    if key then b.push(&H80) else b.push(0)
    b.Append(data)
    return b
end function
