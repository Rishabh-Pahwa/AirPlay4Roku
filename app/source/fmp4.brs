' Fragmented MP4 writer for live HLS of the mirror stream (port of
' test/fmp4_proto.py). The Roku's HLS player starts ~3.4 s after the first
' segments exist and lets the receiver steer its delay afterwards (see
' hls_* in receiver.brs), whereas progressive MKV needed 15-20 s on a static
' iPhone screen. Segments are cut by time, not keyframes: iOS sends one IDR.
'
' Media timescale: 90 kHz. Sample data is AVCC exactly as AirPlay sends it.

function mp4_box(typ as string, payload as object) as object
    b = CreateObject("roByteArray")
    ba_push_u32be(b, payload.Count() + 8&)
    b.Append(ba_ascii(typ))
    b.Append(payload)
    return b
end function

function mp4_fbox(typ as string, ver as integer, flags as integer, payload as object) as object
    p = CreateObject("roByteArray")
    p.push(ver)
    p.push((flags >> 16) and 255)
    p.push((flags >> 8) and 255)
    p.push(flags and 255)
    p.Append(payload)
    return mp4_box(typ, p)
end function

function mp4_matrix() as object
    return ba_hex("000100000000000000000000000000000001000000000000000000000000000040000000")
end function

function mp4_init(w as integer, h as integer, avcc as object) as object
    ftyp = mp4_box("ftyp", ba_hex("69736f350000020069736f3569736f366d703431"))
    p = ba_hex("0000000000000000000003E800000000" + "00010000" + "0100" + "00000000000000000000")
    p.Append(mp4_matrix())
    p.Append(ba_hex("000000000000000000000000000000000000000000000000" + "00000002"))
    mvhd = mp4_fbox("mvhd", 0, 0, p)

    p = ba_hex("00000000" + "00000000" + "00000001" + "00000000" + "00000000" + "0000000000000000" + "0000" + "0000" + "0000" + "0000")
    p.Append(mp4_matrix())
    ba_push_u32be(p, w * 65536&)
    ba_push_u32be(p, h * 65536&)
    tkhd = mp4_fbox("tkhd", 0, 3, p)

    mdhd = mp4_fbox("mdhd", 0, 0, ba_hex("0000000000000000" + "00015F90" + "00000000" + "55C40000"))
    hp = ba_hex("00000000" + "76696465" + "000000000000000000000000")
    hp.Append(ba_ascii("VideoHandler"))
    hp.push(0)
    hdlr = mp4_fbox("hdlr", 0, 0, hp)
    vmhd = mp4_fbox("vmhd", 0, 1, ba_hex("0000000000000000"))
    dinf = mp4_box("dinf", mp4_fbox("dref", 0, 0, mkv_cat([ba_hex("00000001"), mp4_fbox("url ", 0, 1, ba_new(0))])))

    a = ba_hex("000000000000" + "0001" + "00000000000000000000000000000000")
    ba_push_u16be(a, w)
    ba_push_u16be(a, h)
    a.Append(ba_hex("00480000" + "00480000" + "00000000" + "0001"))
    a.Append(ba_new(32))
    a.Append(ba_hex("0018" + "FFFF"))
    a.Append(mp4_box("avcC", avcc))
    avc1 = mp4_box("avc1", a)

    stsd = mp4_fbox("stsd", 0, 0, mkv_cat([ba_hex("00000001"), avc1]))
    stbl = mp4_box("stbl", mkv_cat([stsd, mp4_fbox("stts", 0, 0, ba_new(4)), mp4_fbox("stsc", 0, 0, ba_new(4)), mp4_fbox("stsz", 0, 0, ba_new(8)), mp4_fbox("stco", 0, 0, ba_new(4))]))
    minf = mp4_box("minf", mkv_cat([vmhd, dinf, stbl]))
    mdia = mp4_box("mdia", mkv_cat([mdhd, hdlr, minf]))
    trak = mp4_box("trak", mkv_cat([tkhd, mdia]))
    mvex = mp4_box("mvex", mp4_fbox("trex", 0, 0, ba_hex("00000001" + "00000001" + "00000000" + "00000000" + "00000000")))
    moov = mp4_box("moov", mkv_cat([mvhd, trak, mvex]))
    return mkv_cat([ftyp, moov])
end function

' samples: array of {dur (ticks, Integer), key (Boolean), data (roByteArray)}
function mp4_segment(seq as integer, baseDts as longinteger, samples as object) as object
    n = samples.Count()
    trunLen = 8 + 4 + 4 + 4 + n * 12
    moofLen = 8 + 16 + 8 + 16 + 20 + trunLen
    tp = CreateObject("roByteArray")
    ba_push_u32be(tp, n + 0&)
    ba_push_u32be(tp, moofLen + 8&)
    total = 0
    for each s in samples
        ba_push_u32be(tp, s.dur + 0&)
        ba_push_u32be(tp, s.data.Count() + 0&)
        if s.key then tp.Append(ba_hex("02000000")) else tp.Append(ba_hex("01010000"))
        total = total + s.data.Count()
    end for
    trun = mp4_fbox("trun", 0, &H000701, tp)
    tfhd = mp4_fbox("tfhd", 0, &H020000, ba_hex("00000001"))
    dp = CreateObject("roByteArray")
    ba_push_u32be(dp, baseDts \ 4294967296&)
    ba_push_u32be(dp, baseDts mod 4294967296&)
    tfdt = mp4_fbox("tfdt", 1, 0, dp)
    traf = mp4_box("traf", mkv_cat([tfhd, tfdt, trun]))
    sp = CreateObject("roByteArray")
    ba_push_u32be(sp, seq + 0&)
    mfhd = mp4_fbox("mfhd", 0, 0, sp)
    out = mp4_box("moof", mkv_cat([mfhd, traf]))
    ba_push_u32be(out, total + 8&)
    out.Append(ba_ascii("mdat"))
    for each s in samples
        out.Append(s.data)
    end for
    return out
end function
