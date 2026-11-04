' AirPlay receiver core, run inside the Receiver Task node.
'
' Architecture (adapted from RPiPlay/UxPlay to a single-threaded BrightScript
' event loop):
'   :7000  TCP  RTSP/HTTP control  (info, pair-setup/verify, fp-setup, SETUP...)
'   :7100  TCP  mirror stream      (128-byte header + AES-CTR H.264 payload)
'   :6002  UDP  audio RTP data     (AES-CBC ALAC)      :6003 UDP audio control
'   :6010  UDP  NTP timing client
'   :5353  UDP  mDNS responder
'   :8888  TCP  local media server (127.0.0.1) that feeds live Matroska to the
'               Roku Video/Audio nodes, which can't take raw elementary streams
'
' Decoded media never touches BrightScript loops: decryption is roEVPCipher,
' muxing is header bytes + roByteArray.Append.

' ======================================================================= setup

sub rx_main()
    m.port = CreateObject("roMessagePort")
    m.ts = CreateObject("roTimespan")
    m.ts.Mark()
    m.handlers = {}
    m.conns = {}
    m.pool = []
    m.session = invalid
    m.vs = invalid
    m.aud = invalid
    m.players = {}
    m.gen = 0
    m.nextAnnounceMs = 0
    m.announceCount = 0
    m.nextNtpMs = 0
    m.nextStatsMs = 0
    m.stats = {vframes: 0, vbytes: 0, apkts: 0}

    rx_identity()
    rx_status("starting")
    m.mdns = mdns_start(m.port, m.cfg)
    m.handlers[m.mdns.sock.getID().toStr()] = {kind: "mdns"}
    rx_listen(7000, "rtsp-listen")
    rx_listen(7100, "mirror-listen")
    rx_listen(8888, "http-listen")
    m.ntpSock = rx_udp(6010, "ntp")
    m.audioData = rx_udp(6002, "audio-data")
    m.audioCtrl = rx_udp(6003, "audio-ctrl")
    m.udpBuf = ba_new(2048)

    fp_tables()
    m.top.info = {name: m.cfg.name, ip: m.cfg.ip, deviceId: m.cfg.deviceId}
    rx_status("ready")
    dbg("ready as '" + m.cfg.name + "' on " + m.cfg.ip)

    while true
        msg = wait(40, m.port)
        if type(msg) = "roSocketEvent" then
            rx_dispatch(msg.getSocketID().toStr())
        end if
        rx_timers()
        if m.top.quit = true then exit while
    end while
    mdns_goodbye(m.mdns)
end sub

sub rx_identity()
    reg = CreateObject("roRegistrySection", "airplay")
    if not reg.Exists("seed") then
        reg.Write("seed", random_bytes(32).ToHexString())
        r = random_bytes(6)
        r[0] = (r[0] and 254) or 2
        parts = []
        for i = 0 to 5
            h = ba_slice(r, i, 1).ToHexString()
            parts.push(h)
        end for
        reg.Write("devid", parts.Join(":"))
        reg.Flush()
    end if
    seed = ba_hex(reg.Read("seed"))
    devid = UCase(reg.Read("devid"))
    t = CreateObject("roTimespan")
    m.edkey = ed25519_keypair(seed)
    dbg("ed25519 identity ready in " + t.TotalMilliseconds().toStr() + " ms")
    di = CreateObject("roDeviceInfo")
    name = "Roku"
    name = di.GetModelDisplayName()
    if name = invalid or name = "" then name = "Roku"
    name = name.Split(".").Join(" ").Trim()
    if reg.Exists("name") then name = reg.Read("name")
    ip = ""
    ips = di.GetIPAddrs()
    for each k in ips
        if ip = "" then ip = ips[k]
    end for
    pk = LCase(m.edkey.pub.ToHexString())
    features = "0x5A7FFEE6,0x0"
    m.features& = 1518337766&
    if reg.Exists("nopair") then
        ' bit 27 (legacy pairing) off: clients skip pair-setup/verify
        features = "0x527FFEE6,0x0"
        m.features& = 1384120038&
    end if
    host = "roku-airplay-" + LCase(Right(devid.Split(":").Join(""), 6))
    m.cfg = {
        name: name, host: host, ip: ip, port: 7000, deviceId: devid,
        width: 1280, height: 720, fps: 30,
        airplayTxt: ["deviceid=" + devid, "features=" + features, "flags=0x4", "model=AppleTV3,2", "pk=" + pk, "pi=2e388006-13ba-4041-9a67-25dd4a43d536", "srcvers=220.68", "vv=2", "pw=false"],
        raopTxt: ["ch=2", "cn=0,1,2,3", "da=true", "et=0,3,5", "vv=2", "ft=" + features, "am=AppleTV3,2", "md=0,1,2", "rhd=5.6.0.0", "pw=false", "sf=0x4", "sr=44100", "ss=16", "sv=false", "tp=UDP", "txtvers=1", "vs=220.68", "vn=65537", "pk=" + pk]
    }
end sub

sub rx_listen(portNum as integer, kind as string)
    a = CreateObject("roSocketAddress")
    a.setPort(portNum)
    s = CreateObject("roStreamSocket")
    s.setMessagePort(m.port)
    s.setReuseAddr(true)
    s.setAddress(a)
    s.notifyReadable(true)
    ok = s.listen(8)
    dbg("listen " + kind + " :" + portNum.toStr() + " ok=" + lstr(ok))
    m.handlers[s.getID().toStr()] = {kind: kind, sock: s}
end sub

function rx_udp(portNum as integer, kind as string) as object
    s = CreateObject("roDataGramSocket")
    s.setMessagePort(m.port)
    a = CreateObject("roSocketAddress")
    a.setPort(portNum)
    s.setAddress(a)
    s.notifyReadable(true)
    m.handlers[s.getID().toStr()] = {kind: kind, sock: s}
    return s
end function

sub rx_status(s as string)
    m.top.status = s
end sub

function now_ms() as integer
    return m.ts.TotalMilliseconds()
end function

' ======================================================================= loop

sub rx_dispatch(id as string)
    h = m.handlers[id]
    if h = invalid then return
    k = h.kind
    if k = "mdns" then
        mdns_on_readable(m.mdns)
    else if k = "rtsp-listen" or k = "mirror-listen" or k = "http-listen" then
        cs = h.sock.accept()
        if cs = invalid then return
        cs.setMessagePort(m.port)
        cs.notifyReadable(true)
        cid = cs.getID().toStr()
        peer = cs.getReceivedFromAddress().getAddress()
        if k = "rtsp-listen" then
            c = {kind: "rtsp", sock: cs, id: cid, peer: peer, buf: ba_new(0), blen: 0, scan: 0, pair: {}}
            dbg("rtsp connection from " + peer)
        else if k = "mirror-listen" then
            c = {kind: "mirror", sock: cs, id: cid, peer: peer, hdr: ba_new(128), hpos: 0, payload: invalid, ppos: 0, psize: 0}
            dbg("mirror stream connected from " + peer)
            rx_status("mirroring")
        else
            c = {kind: "http", sock: cs, id: cid, peer: peer, buf: ba_new(0), blen: 0, scan: 0, q: [], qpos: 0, stream: invalid, closeWhenDone: false}
        end if
        m.handlers[cid] = c
    else if k = "rtsp" then
        rtsp_on_readable(h)
    else if k = "mirror" then
        mirror_on_readable(h)
    else if k = "http" then
        http_on_event(h)
    else if k = "audio-data" or k = "audio-ctrl" then
        audio_on_readable(h)
    else if k = "ntp" then
        s = h.sock
        while s.isReadable()
            n = s.receive(m.udpBuf, 0, 2048)
            if n <= 0 then exit while
        end while
    end if
end sub

sub rx_close(c as object)
    if c = invalid then return
    c.sock.close()
    m.handlers.Delete(c.id)
    if c.kind = "rtsp" then
        dbg("rtsp connection closed (" + c.peer + ")")
        if m.session <> invalid and m.session.connId = c.id then session_end("control connection closed")
    else if c.kind = "mirror" then
        dbg("mirror stream closed")
        if m.vs <> invalid then m.vs.mirrorConn = invalid
    else if c.kind = "http" then
        if c.stream <> invalid then c.stream.clients.Delete(c.id)
    end if
end sub

sub rx_timers()
    t = now_ms()
    if t >= m.nextAnnounceMs then
        mdns_announce(m.mdns)
        m.announceCount = m.announceCount + 1
        if m.announceCount < 4 then
            m.nextAnnounceMs = t + 1000 * m.announceCount
        else
            m.nextAnnounceMs = t + 60000
        end if
    end if
    if m.session <> invalid and m.session.ntpAddr <> invalid and t >= m.nextNtpMs then
        ntp_send_request()
        m.nextNtpMs = t + 3000
    end if
    if m.session = invalid and m.pool.Count() < 1 and not rx_has_rtsp() then
        pool_refill()
    end if
    if m.vs <> invalid then hls_tick(m.vs)
    if t >= m.nextStatsMs then
        m.nextStatsMs = t + 10000
        if m.stats.vframes > 0 or m.stats.apkts > 0 then
            dbg("stats 10s: video frames=" + m.stats.vframes.toStr() + " bytes=" + m.stats.vbytes.toStr() + " audio pkts=" + m.stats.apkts.toStr())
            m.stats = {vframes: 0, vbytes: 0, apkts: 0}
        end if
    end if
end sub

function rx_has_rtsp() as boolean
    for each k in m.handlers
        if m.handlers[k].kind = "rtsp" then return true
    end for
    return false
end function

' Precompute an ephemeral X25519 key and an Ed25519 nonce while idle, so a
' pair-verify only costs one X25519 + one cheap signature.
sub pool_refill()
    t = CreateObject("roTimespan")
    priv = random_bytes(32)
    e = {priv: priv, pub: x25519_public(priv), nonce: ed25519_nonce()}
    m.pool.push(e)
    dbg("pairing precompute done in " + t.TotalMilliseconds().toStr() + " ms")
end sub

' ======================================================================= RTSP

sub rtsp_on_readable(c as object)
    s = c.sock
    avail = s.getCountRcvBuf()
    if avail <= 0 then
        rx_close(c)
        return
    end if
    start = c.blen
    c.buf[start + avail - 1] = 0
    got = s.receive(c.buf, start, avail)
    if got <= 0 then
        rx_close(c)
        return
    end if
    c.blen = start + got
    while true
        he = ba_find_crlfcrlf(c.buf, c.scan, c.blen)
        if he < 0 then
            c.scan = c.blen - 3
            if c.scan < 0 then c.scan = 0
            exit while
        end if
        req = http_parse_head(ba_slice(c.buf, 0, he).ToAsciiString())
        clen = 0
        if req.headers.DoesExist("content-length") then clen = str_int(req.headers["content-length"])
        total = he + 4 + clen
        if c.blen < total then
            c.scan = he
            exit while
        end if
        req.body = ba_slice(c.buf, he + 4, clen)
        ' keep any pipelined remainder
        rest = c.blen - total
        if rest > 0 then
            c.buf = ba_slice(c.buf, total, rest)
        else
            c.buf = ba_new(0)
        end if
        c.blen = rest
        c.scan = 0
        rtsp_handle(c, req)
        if m.handlers[c.id] = invalid then exit while
    end while
end sub

function http_parse_head(text as string) as object
    lines = text.Split(CRLF())
    first = lines[0].Split(" ")
    req = {method: first[0], url: "", proto: "RTSP/1.0", headers: {}}
    if first.Count() > 1 then req.url = first[1]
    if first.Count() > 2 then req.proto = first[2]
    for i = 1 to lines.Count() - 1
        ln = lines[i]
        p = Instr(1, ln, ":")
        if p > 1 then req.headers[LCase(Left(ln, p - 1).Trim())] = Mid(ln, p + 1).Trim()
    end for
    return req
end function

sub rtsp_reply(c as object, req as object, code as integer, extra as object, ctype as string, body as dynamic)
    reason = "OK"
    if code = 404 then reason = "Not Found"
    if code = 400 then reason = "Bad Request"
    if code = 500 then reason = "Internal Server Error"
    proto = req.proto
    if Left(proto, 4) <> "RTSP" and Left(proto, 4) <> "HTTP" then proto = "RTSP/1.0"
    h = proto + " " + code.toStr() + " " + reason + CRLF()
    if req.headers.DoesExist("cseq") then h = h + "CSeq: " + req.headers["cseq"] + CRLF()
    h = h + "Server: AirTunes/220.68" + CRLF()
    for each k in extra
        h = h + k + ": " + extra[k] + CRLF()
    end for
    n = 0
    if body <> invalid then n = body.Count()
    if n > 0 and ctype <> "" then h = h + "Content-Type: " + ctype + CRLF()
    h = h + "Content-Length: " + n.toStr() + CRLF() + CRLF()
    out = ba_ascii(h)
    if n > 0 then out.Append(body)
    sock_send_all(c.sock, out)
end sub

' Control replies are small; the socket buffer takes them in one go normally.
sub sock_send_all(s as object, out as object)
    sent = 0
    total = out.Count()
    tries = 0
    while sent < total and tries < 200
        n = s.send(out, sent, total - sent)
        if n > 0 then
            sent = sent + n
        else
            tries = tries + 1
            sleep(5)
        end if
    end while
end sub

sub rtsp_handle(c as object, req as object)
    meth = req.method
    url = req.url
    dbg(meth + " " + url + " (" + req.body.Count().toStr() + " bytes)")
    if meth = "GET" and Instr(1, url, "/info") > 0 then
        h_info(c, req)
    else if meth = "POST" and url = "/pair-setup" then
        rtsp_reply(c, req, 200, {}, "application/octet-stream", m.edkey.pub)
    else if meth = "POST" and url = "/pair-verify" then
        h_pair_verify(c, req)
    else if meth = "POST" and url = "/fp-setup" then
        h_fp_setup(c, req)
    else if meth = "OPTIONS" then
        rtsp_reply(c, req, 200, {"Public": "SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER"}, "", invalid)
    else if meth = "SETUP" then
        h_setup(c, req)
    else if meth = "RECORD" then
        rtsp_reply(c, req, 200, {"Audio-Latency": "11025", "Audio-Jack-Status": "connected; type=analog"}, "", invalid)
    else if meth = "GET_PARAMETER" then
        body = req.body.ToAsciiString()
        if Instr(1, body, "volume") > 0 then
            rtsp_reply(c, req, 200, {}, "text/parameters", ba_ascii("volume: 0.000000" + CRLF()))
        else
            rtsp_reply(c, req, 200, {}, "", invalid)
        end if
    else if meth = "SET_PARAMETER" then
        ct = ""
        if req.headers.DoesExist("content-type") then ct = req.headers["content-type"]
        if ct = "text/parameters" then
            txt = req.body.ToAsciiString().Trim()
            dbg("  " + txt)
            if Left(txt, 7) = "volume:" then m.top.volume = Val(Mid(txt, 8).Trim())
        end if
        rtsp_reply(c, req, 200, {}, "", invalid)
    else if meth = "FLUSH" then
        rtsp_reply(c, req, 200, {}, "", invalid)
    else if meth = "TEARDOWN" then
        h_teardown(c, req)
    else if meth = "POST" and (url = "/feedback" or url = "/audioMode" or url = "/command") then
        rtsp_reply(c, req, 200, {}, "", invalid)
    else
        dbg("  unhandled " + meth + " " + url)
        rtsp_reply(c, req, 404, {}, "", invalid)
    end if
end sub

function txt_bytes(items as object) as object
    return dns_txt_rdata(items)
end function

sub h_info(c as object, req as object)
    cfg = m.cfg
    d = pl_dict()
    qual = ""
    hasCT = req.headers.DoesExist("content-type")
    if hasCT and req.body.Count() > 0 then
        p = plist_parse(req.body)
        if p <> invalid and type(p) = "roAssociativeArray" and type(p["qualifier"]) = "roArray" and p["qualifier"].Count() > 0 then qual = p["qualifier"][0]
    end if
    if qual = "txtAirPlay" then pl_set(d, "txtAirPlay", txt_bytes(cfg.airplayTxt))
    if qual = "txtRAOP" then pl_set(d, "txtRAOP", txt_bytes(cfg.raopTxt))
    if not hasCT then
        pl_set(d, "deviceID", cfg.deviceId)
        pl_set(d, "macAddress", cfg.deviceId)
        pl_set(d, "pk", m.edkey.pub)
        pl_set(d, "features", m.features&)
        pl_set(d, "name", cfg.name)
        pl_set(d, "pi", "2e388006-13ba-4041-9a67-25dd4a43d536")
        pl_set(d, "vv", 2)
        pl_set(d, "statusFlags", 68)
        pl_set(d, "keepAliveLowPower", true)
        pl_set(d, "sourceVersion", "220.68")
        pl_set(d, "keepAliveSendStatsAsBody", true)
        pl_set(d, "model", "AppleTV3,2")
        pl_set(d, "initialVolume", pl_real_hex("0000000000000000"))
        lat = []
        fmts = []
        for each tp in [100, 101]
            l = pl_dict()
            pl_set(l, "type", tp)
            pl_set(l, "inputLatencyMicros", 0)
            pl_set(l, "audioType", "default")
            pl_set(l, "outputLatencyMicros", false)
            lat.push(l)
            f = pl_dict()
            pl_set(f, "audioOutputFormats", 67108860)
            pl_set(f, "type", tp)
            pl_set(f, "audioInputFormats", 67108860)
            fmts.push(f)
        end for
        pl_set(d, "audioLatencies", pl_array(lat))
        pl_set(d, "audioFormats", pl_array(fmts))
        disp = pl_dict()
        pl_set(disp, "uuid", "e0ff8a27-6738-3d56-8a16-cc53aacee925")
        pl_set(disp, "widthPhysical", 0)
        pl_set(disp, "heightPhysical", 0)
        pl_set(disp, "width", cfg.width)
        pl_set(disp, "height", cfg.height)
        pl_set(disp, "widthPixels", cfg.width)
        pl_set(disp, "heightPixels", cfg.height)
        pl_set(disp, "rotation", false)
        pl_set(disp, "refreshRate", pl_real_hex("3F91111111111111"))
        pl_set(disp, "maxFPS", cfg.fps)
        pl_set(disp, "overscanned", false)
        pl_set(disp, "features", 14)
        pl_set(d, "displays", pl_array([disp]))
    end if
    rtsp_reply(c, req, 200, {}, "application/x-apple-binary-plist", plist_build(d))
end sub

sub h_pair_verify(c as object, req as object)
    b = req.body
    if b.Count() < 4 then
        rtsp_reply(c, req, 400, {}, "", invalid)
        return
    end if
    if b[0] = 1 and b.Count() >= 68 then
        t = CreateObject("roTimespan")
        if m.pool.Count() = 0 then pool_refill()
        e = m.pool.Shift()
        theirs = ba_slice(b, 4, 32)
        shared = x25519(e.priv, theirs)
        msg = bytes_concat(e.pub, theirs)
        sig = ed25519_sign(m.edkey, e.nonce, msg)
        key = sha512_bytes(bytes_concat(ba_ascii("Pair-Verify-AES-Key"), shared))
        iv = sha512_bytes(bytes_concat(ba_ascii("Pair-Verify-AES-IV"), shared))
        ciph = CreateObject("roEVPCipher")
        ciph.Setup(true, "aes-128-ctr", ba_slice(key, 0, 16).ToHexString(), ba_slice(iv, 0, 16).ToHexString(), 0)
        enc = ciph.Update(sig)
        c.pair = {shared: shared}
        out = CreateObject("roByteArray")
        out.Append(e.pub)
        out.Append(enc)
        dbg("  pair-verify step 1 computed in " + t.TotalMilliseconds().toStr() + " ms")
        rtsp_reply(c, req, 200, {}, "application/octet-stream", out)
    else
        ' step 2: client's encrypted signature; transient pairing, so accept it
        c.pair.verified = true
        rtsp_reply(c, req, 200, {}, "application/octet-stream", invalid)
    end if
end sub

sub h_fp_setup(c as object, req as object)
    b = req.body
    if b.Count() = 16 then
        r = FairPlay_SetupReply(b)
        if r = invalid then
            rtsp_reply(c, req, 400, {}, "", invalid)
        else
            rtsp_reply(c, req, 200, {}, "application/octet-stream", r)
        end if
    else if b.Count() = 164 then
        c.fpKeyMsg = b
        rtsp_reply(c, req, 200, {}, "application/octet-stream", FairPlay_HandshakeReply(b))
    else
        rtsp_reply(c, req, 400, {}, "", invalid)
    end if
end sub

' unsigned decimal string for a (possibly negative = >= 2^63) 64-bit value
function u64_str(v as dynamic) as string
    v& = v + 0&
    if v& >= 0& then return v&.toStr()
    u& = v& + 9223372036854775807& + 1&
    hi& = u& \ 4294967296& + 2147483648&
    lo& = u& mod 4294967296&
    digits = ""
    while hi& > 0& or lo& > 0&
        r& = hi& mod 10&
        hi& = hi& \ 10&
        t& = r& * 4294967296& + lo&
        lo& = t& \ 10&
        digits = (t& mod 10&).toStr() + digits
    end while
    return digits
end function

sub h_setup(c as object, req as object)
    p = plist_parse(req.body)
    if p = invalid then p = {}
    res = pl_dict()
    if type(p["ekey"]) = "roByteArray" and type(p["eiv"]) = "roByteArray" then
        if c.fpKeyMsg = invalid then
            dbg("  SETUP without fp-setup; rejecting")
            rtsp_reply(c, req, 400, {}, "", invalid)
            return
        end if
        session_end("new session")
        t = CreateObject("roTimespan")
        if m.global.testMode = true and type(p["testAesKey"]) = "roByteArray" then
            dbg("  TEST MODE: using plaintext testAesKey from sender")
            aeskey = p["testAesKey"]
        else
            aeskey = FairPlay_Decrypt(c.fpKeyMsg, p["ekey"])
            dbg("  fairplay decrypt " + t.TotalMilliseconds().toStr() + " ms")
        end if
        if c.pair.DoesExist("shared") then
            aeskey = ba_slice(sha512_bytes(bytes_concat(aeskey, c.pair.shared)), 0, 16)
        end if
        sess = {connId: c.id, peer: c.peer, aeskey: aeskey, aesiv: p["eiv"], ntpAddr: invalid, name: "", model: ""}
        if p["name"] <> invalid then sess.name = lstr(p["name"])
        if p["model"] <> invalid then sess.model = lstr(p["model"])
        m.session = sess
        tp = p["timingPort"]
        if tp <> invalid then
            a = CreateObject("roSocketAddress")
            a.setAddress(c.peer.Split(":")[0])
            a.setPort(tp)
            sess.ntpAddr = a
        end if
        pl_set(res, "eventPort", 0)
        pl_set(res, "timingPort", 6010)
        who = sess.name
        if who = "" then who = c.peer
        rx_status("connected: " + who)
        m.top.client = who
        dbg("  session from " + who + " model=" + sess.model)
    end if
    if type(p["streams"]) = "roArray" then
        outStreams = []
        for each st in p["streams"]
            tp = st["type"]
            if tp = 110 then
                mirror_setup(st["streamConnectionID"])
                r = pl_dict()
                pl_set(r, "dataPort", 7100)
                pl_set(r, "type", 110)
                outStreams.push(r)
            else if tp = 96 then
                ct = 0
                if st["ct"] <> invalid then ct = st["ct"]
                spf = 352
                if st["spf"] <> invalid then spf = st["spf"]
                audio_setup(ct, spf)
                r = pl_dict()
                pl_set(r, "dataPort", 6002)
                pl_set(r, "controlPort", 6003)
                pl_set(r, "type", 96)
                outStreams.push(r)
            else
                dbg("  unknown stream type " + lstr(tp))
            end if
        end for
        pl_set(res, "streams", pl_array(outStreams))
    end if
    rtsp_reply(c, req, 200, {}, "application/x-apple-binary-plist", plist_build(res))
end sub

sub h_teardown(c as object, req as object)
    p = plist_parse(req.body)
    t96 = false
    t110 = false
    if p <> invalid and type(p["streams"]) = "roArray" then
        for each st in p["streams"]
            if st["type"] = 96 then t96 = true
            if st["type"] = 110 then t110 = true
        end for
    end if
    rtsp_reply(c, req, 200, {"Connection": "close"}, "", invalid)
    if t96 then audio_stop()
    if t110 then mirror_stop()
    if not t96 and not t110 then session_end("teardown")
end sub

sub session_end(why as string)
    if m.session = invalid and m.vs = invalid and m.aud = invalid then return
    dbg("session end: " + why)
    mirror_stop()
    audio_stop()
    m.session = invalid
    m.top.client = ""
    rx_status("ready")
end sub

' ======================================================================= timing

sub ntp_send_request()
    b = ba_new(32)
    b[0] = &H80
    b[1] = &HD2
    b[2] = 0
    b[3] = 7
    dt = CreateObject("roDateTime")
    secs& = dt.AsSeconds() + 2208988800&
    ms = dt.GetMilliseconds()
    b[24] = ((secs& \ 16777216&) mod 256&)
    b[25] = ((secs& \ 65536&) mod 256&)
    b[26] = ((secs& \ 256&) mod 256&)
    b[27] = (secs& mod 256&)
    frac& = (ms * 4294967&)
    b[28] = ((frac& \ 16777216&) mod 256&)
    b[29] = ((frac& \ 65536&) mod 256&)
    m.ntpSock.setSendToAddress(m.session.ntpAddr)
    m.ntpSock.send(b, 0, 32)
end sub

' ======================================================================= mirror

sub mirror_setup(streamId as dynamic)
    s = m.session
    if s = invalid then return
    idstr = u64_str(streamId)
    hk = sha512_bytes(bytes_concat(ba_ascii("AirPlayStreamKey" + idstr), s.aeskey))
    hv = sha512_bytes(bytes_concat(ba_ascii("AirPlayStreamIV" + idstr), s.aeskey))
    ciph = CreateObject("roEVPCipher")
    ciph.Setup(false, "aes-128-ctr", ba_slice(hk, 0, 16).ToHexString(), ba_slice(hv, 0, 16).ToHexString(), 0)
    m.gen = m.gen + 1
    m.vs = {kind: "video", gen: m.gen, cipher: ciph, init: invalid, avcc: invalid, clients: {}, w: 0, h: 0}
    dbg("  mirror stream set up, id=" + idstr)
end sub

sub mirror_stop()
    if m.vs = invalid then return
    for each k in m.vs.clients
        cl = m.vs.clients[k]
        cl.sock.close()
        m.handlers.Delete(k)
    end for
    m.vs = invalid
    m.top.mirrorUrl = ""
    ' close the mirror TCP connection if still open
    for each k in m.handlers.Keys()
        h = m.handlers[k]
        if h <> invalid and h.kind = "mirror" then
            h.sock.close()
            m.handlers.Delete(k)
        end if
    end for
end sub

sub mirror_on_readable(c as object)
    s = c.sock
    avail = s.getCountRcvBuf()
    if avail <= 0 then
        rx_close(c)
        return
    end if
    while avail > 0
        if c.payload = invalid then
            want = 128 - c.hpos
            if want > avail then want = avail
            got = s.receive(c.hdr, c.hpos, want)
            if got <= 0 then exit while
            c.hpos = c.hpos + got
            avail = avail - got
            if c.hpos = 128 then
                ps% = ba_u32le(c.hdr, 0)
                c.psize = ps%
                if c.psize < 0 or c.psize > 16000000 then
                    dbg("bad mirror packet size " + c.psize.toStr())
                    rx_close(c)
                    return
                end if
                c.payload = ba_new(c.psize)
                c.ppos = 0
                if c.psize = 0 then
                    mirror_packet(c.hdr, c.payload)
                    c.payload = invalid
                    c.hpos = 0
                end if
            end if
        else
            want = c.psize - c.ppos
            if want > avail then want = avail
            got = s.receive(c.payload, c.ppos, want)
            if got <= 0 then exit while
            c.ppos = c.ppos + got
            avail = avail - got
            if c.ppos = c.psize then
                mirror_packet(c.hdr, c.payload)
                c.payload = invalid
                c.hpos = 0
            end if
        end if
    end while
end sub

sub mirror_packet(hdr as object, payload as object)
    vs = m.vs
    if vs = invalid then return
    ptype = hdr[4]
    if ptype = 0 then
        if vs.init = invalid then return
        dec = vs.cipher.Update(payload)
        if dec = invalid then return
        ' NTP-format timestamp, little endian: [8..11] fraction, [12..15] seconds
        secs& = ba_u32le(hdr, 12)
        frac& = ba_u32le(hdr, 8)
        ms& = secs& * 1000& + (frac& * 1000&) \ 4294967296&
        key = (hdr[5] = &H10)
        if not key then key = h264_has_idr(dec)
        mux_video_frame(vs, ms&, key, dec)
        m.stats.vframes = m.stats.vframes + 1
        m.stats.vbytes = m.stats.vbytes + dec.Count()
    else if ptype = 1 then
        ' codec config: payload is an avcC record (unencrypted)
        w = hdr_float_le(hdr, 56)
        h = hdr_float_le(hdr, 60)
        dbg("mirror codec config " + w.toStr() + "x" + h.toStr() + " avcC " + payload.Count().toStr() + " bytes")
        if payload.Count() < 8 or payload[0] <> 1 then
            dbg("  not an avcC record (HEVC?) - ignoring")
            return
        end if
        mux_video_config(vs, payload, w, h)
    end if
end sub

function h264_has_idr(d as object) as boolean
    off = 0
    n = d.Count()
    guard = 0
    while off + 5 <= n and guard < 16
        l& = ba_u32be(d, off)
        if (d[off + 4] and 31) = 5 then return true
        l% = l&
        off = off + 4 + l%
        guard = guard + 1
    end while
    return false
end function

function hdr_float_le(b as object, off as integer) as integer
    bits& = ba_u32le(b, off)
    ex = ((bits& \ 8388608&) mod 256&)
    mant& = bits& mod 8388608&
    if ex = 0 then return 0
    v# = (1# + mant& / 8388608#) * (2# ^ (ex - 127))
    return Int(v#)
end function

' ----------------------------------------------------------------- live HLS
' Mirror frames become 0.5 s fMP4 segments in a sliding-window live playlist.
' The Roku HLS player starts ~3.4 s behind live; afterwards the scene reports
' the player's position and we shorten (or stretch) sample durations so the
' player drifts to ~HLS_TARGET_MS behind the newest segment and stays there.
' (Measured on the device: steady 1.3 s, no rebuffering; see test/latency.)

function HLS_SEG_TICKS() as integer
    return 36000
end function

function HLS_TARGET_MS() as integer
    return 1500
end function

sub mux_video_config(vs as object, avcc as object, w as integer, h as integer)
    if w <= 0 then w = 1280
    if h <= 0 then h = 720
    if vs.init <> invalid and vs.avcc <> invalid and vs.avcc.ToHexString() = avcc.ToHexString() then
        dbg("  same codec config, continuing stream")
        return
    end if
    ' new stream generation (first config, rotation, resolution change)
    m.gen = m.gen + 1
    vs.gen = m.gen
    vs.avcc = avcc
    vs.init = mp4_init(w, h, avcc)
    vs.w = w
    vs.h = h
    vs.segs = []
    vs.nextSeq = 1
    vs.cur = []
    vs.curTicks = 0
    vs.baseDts = 0&
    vs.pend = invalid
    vs.gotKey = false
    vs.published = false
    vs.scale = 100
    vs.lastClose = now_ms()
    vs.lastState = ""
    m.top.mirrorUrl = ""
    m.top.mirrorSize = w.toStr() + "x" + h.toStr()
end sub

sub mux_video_frame(vs as object, msl as longinteger, key as boolean, data as object)
    if vs.init = invalid then return
    if not vs.gotKey then
        if not key then return
        vs.gotKey = true
    end if
    if vs.pend <> invalid then
        d& = msl - vs.pend.ms
        if d& < 1& or d& > 1000& then d& = 33&
        d% = d&
        hls_add_sample(vs, vs.pend, d%)
    end if
    vs.pend = {ms: msl, key: key, data: data, at: now_ms()}
end sub

sub hls_add_sample(vs as object, f as object, dms as integer)
    ticks = (dms * 90 * vs.scale) \ 100
    if ticks < 90 then ticks = 90
    vs.cur.push({dur: ticks, key: f.key, data: f.data})
    vs.curTicks = vs.curTicks + ticks
    if vs.curTicks >= HLS_SEG_TICKS() then hls_close_segment(vs)
end sub

sub hls_close_segment(vs as object)
    if vs.cur.Count() = 0 then return
    data = mp4_segment(vs.nextSeq, vs.baseDts, vs.cur)
    ms = vs.curTicks \ 90
    frac = (ms mod 1000).toStr()
    while Len(frac) < 3
        frac = "0" + frac
    end while
    vs.segs.push({seq: vs.nextSeq, data: data, dur: (ms \ 1000).toStr() + "." + frac})
    vs.baseDts = vs.baseDts + vs.curTicks
    vs.nextSeq = vs.nextSeq + 1
    vs.cur = []
    vs.curTicks = 0
    vs.lastClose = now_ms()
    while vs.segs.Count() > 14
        vs.segs.Shift()
    end while
    if not vs.published and vs.segs.Count() >= 2 then
        vs.published = true
        m.top.mirrorUrl = "http://127.0.0.1:8888/hls/" + vs.gen.toStr() + "/live.m3u8"
    end if
    hls_steer(vs)
end sub

' Adjust the media clock rate from the player's reported position, with
' hysteresis: speed up (80%) above HLS_TARGET_MS + 500 until back at the
' target, slow down (115%) below HLS_TARGET_MS - 350 until back at the target.
sub hls_steer(vs as object)
    if m.top.playerState <> vs.lastState then
        dbg("player " + m.top.playerState)
        vs.lastState = m.top.playerState
    end if
    if m.top.playerState <> "playing" then
        vs.scale = 100
        return
    end if
    endMs& = vs.baseDts \ 90&
    posMs& = Int(m.top.playerPos * 1000)
    depth& = endMs& - posMs&
    tgt = HLS_TARGET_MS()
    old = vs.scale
    if vs.scale = 80 then
        if depth& <= tgt then vs.scale = 100
    else if vs.scale = 115 then
        if depth& >= tgt then vs.scale = 100
    else if depth& > tgt + 500 then
        vs.scale = 80
    else if depth& < tgt - 350 then
        vs.scale = 115
    end if
    if old <> vs.scale then dbg("hls depth " + depth&.toStr() + " ms -> rate " + vs.scale.toStr() + "%")
    dd% = depth&
    m.top.mirrorDepth = dd%
end sub

' called from the main loop: keep segments flowing when the sender pauses
sub hls_tick(vs as object)
    if vs = invalid or vs.init = invalid then return
    t = now_ms()
    if vs.pend <> invalid and t - vs.pend.at > 200 then
        d = t - vs.pend.at
        if d > 1000 then d = 1000
        f = vs.pend
        vs.pend = invalid
        hls_add_sample(vs, f, d)
    end if
    if vs.cur.Count() > 0 and t - vs.lastClose > 600 then hls_close_segment(vs)
end sub

function hls_playlist(vs as object) as object
    n = vs.segs.Count()
    first = 0
    if n > 8 then first = n - 8
    pl = "#EXTM3U" + CRLF() + "#EXT-X-VERSION:7" + CRLF() + "#EXT-X-TARGETDURATION:1" + CRLF()
    seq = 1
    if n > 0 then seq = vs.segs[first].seq
    pl = pl + "#EXT-X-MEDIA-SEQUENCE:" + seq.toStr() + CRLF()
    pl = pl + "#EXT-X-MAP:URI=" + Chr(34) + "init.mp4" + Chr(34) + CRLF()
    for i = first to n - 1
        sg = vs.segs[i]
        pl = pl + "#EXTINF:" + sg.dur + "," + CRLF() + "s" + sg.seq.toStr() + ".m4s" + CRLF()
    end for
    return ba_ascii(pl)
end function

' append a chunk to the replay cache and all connected players
sub stream_push(st as object, chunk as object)
    if st.cacheBytes < 48000000 then
        st.cache.push(chunk)
        st.cacheBytes = st.cacheBytes + chunk.Count()
    end if
    for each k in st.clients
        cl = st.clients[k]
        cl.q.push(chunk)
        http_pump(cl)
    end for
end sub

' ======================================================================= audio

sub audio_setup(ct as integer, spf as integer)
    s = m.session
    if s = invalid then return
    dbg("  audio stream ct=" + ct.toStr() + " spf=" + spf.toStr())
    ciph = CreateObject("roEVPCipher")
    ciph.Setup(false, "aes-128-cbc", s.aeskey.ToHexString(), s.aesiv.ToHexString(), 0)
    playable = (ct = 2)
    if not playable then dbg("  audio codec ct=" + ct.toStr() + " is not playable on this Roku (only ALAC); ignoring audio")
    m.gen = m.gen + 1
    m.aud = {kind: "audio", gen: m.gen, ct: ct, spf: spf, cipher: ciph, playable: playable, header: mkv_alac_header(spf, 44100, 2, 16), cache: [], cacheBytes: 0, base: invalid, clusterTc: -1, clients: {}, started: false, lastTc: 0}
end sub

sub audio_stop()
    if m.aud = invalid then return
    for each k in m.aud.clients
        cl = m.aud.clients[k]
        cl.sock.close()
        m.handlers.Delete(k)
    end for
    m.aud = invalid
    m.top.audioUrl = ""
end sub

sub audio_on_readable(h as object)
    s = h.sock
    buf = m.udpBuf
    while s.isReadable()
        n = s.receive(buf, 0, 2048)
        if n <= 0 then exit while
        if h.kind = "audio-data" then
            audio_packet(buf, n)
        else if n > 16 and (buf[1] and 127) = &H56 then
            ' retransmitted packet: 4-byte header + original RTP packet
            inner = ba_slice(buf, 4, n - 4)
            audio_packet(inner, n - 4)
        end if
    end while
end sub

sub audio_packet(buf as object, n as integer)
    ast = m.aud
    if ast = invalid or not ast.playable or n <= 12 then return
    pt = buf[1] and 127
    if pt <> &H60 then return
    m.stats.apkts = m.stats.apkts + 1
    rtpts& = ba_u32be(buf, 4)
    plen = n - 12
    enclen = (plen \ 16) * 16
    b64 = buf.ToBase64String()
    frame = CreateObject("roByteArray")
    if enclen > 0 then
        ast.cipher.Reinit()
        dec = ast.cipher.Update(ba_slice(buf, 12, enclen, b64))
        if dec <> invalid then frame.Append(dec)
    end if
    for i = 12 + enclen to n - 1
        frame.push(buf[i])
    end for
    if ast.base = invalid then
        ast.base = rtpts&
        m.top.audioUrl = "http://127.0.0.1:8888/audio/" + ast.gen.toStr() + ".mka"
    end if
    d& = rtpts& - ast.base
    if d& < -2147483648& then d& = d& + 4294967296&
    if d& < 0& then return
    t% = (d& * 1000&) \ 44100&
    t = t%
    if t < ast.lastTc then t = ast.lastTc
    ast.lastTc = t
    if ast.clusterTc < 0 or t - ast.clusterTc >= 1000 then
        if t - ast.clusterTc >= 1000 and ast.cacheBytes > 4000000 then
            ast.cache = []
            ast.cacheBytes = 0
        end if
        ast.clusterTc = t
        stream_push(ast, mkv_cluster_start(t + 0&))
    end if
    stream_push(ast, mkv_simple_block(t - ast.clusterTc, true, frame))
end sub

' ======================================================================= local media HTTP

sub http_on_event(c as object)
    s = c.sock
    if s.isReadable() then
        avail = s.getCountRcvBuf()
        if avail <= 0 then
            rx_close(c)
            return
        end if
        start = c.blen
        c.buf[start + avail - 1] = 0
        got = s.receive(c.buf, start, avail)
        if got > 0 then c.blen = start + got
        if c.stream = invalid then
            he = ba_find_crlfcrlf(c.buf, 0, c.blen)
            if he >= 0 then
                req = http_parse_head(ba_slice(c.buf, 0, he).ToAsciiString())
                http_serve(c, req)
            end if
        end if
    end if
    if m.handlers[c.id] <> invalid and s.isWritable() then http_pump(c)
end sub

sub http_serve(c as object, req as object)
    url = req.url
    if Left(url, 5) = "/hls/" then
        http_serve_hls(c, req)
        return
    end if
    if url = "/log" then
        ring = GetGlobalAA().logRing
        txt = ""
        if ring <> invalid then txt = ring.Join(Chr(10)) + Chr(10)
        body = ba_ascii(txt)
        c.q.push(ba_ascii("HTTP/1.1 200 OK" + CRLF() + "Content-Type: text/plain" + CRLF() + "Content-Length: " + body.Count().toStr() + CRLF() + "Connection: close" + CRLF() + CRLF()))
        c.q.push(body)
        c.closeWhenDone = true
        c.stream = {kind: "log", clients: {}}
        http_pump(c)
        return
    end if
    st = invalid
    if Left(url, 7) = "/audio/" and m.aud <> invalid and (url = "/audio/" + m.aud.gen.toStr() + ".mka" or url = "/audio/current.mka") then
        st = m.aud
    end if
    off = 0
    if req.headers.DoesExist("range") then
        r = req.headers["range"]
        eq = Instr(1, r, "=")
        if eq > 0 then off = str_int(Mid(r, eq + 1).Split("-")[0])
    end if
    dbg("player " + req.method + " " + url + " from " + off.toStr())
    if st = invalid then
        sock_send_all(c.sock, ba_ascii("HTTP/1.1 404 Not Found" + CRLF() + "Content-Length: 0" + CRLF() + "Connection: close" + CRLF() + CRLF()))
        rx_close(c)
        return
    end if
    ctype = "video/x-matroska"
    if st.kind = "audio" then ctype = "audio/x-matroska"
    c.q.push(ba_ascii("HTTP/1.1 200 OK" + CRLF() + "Content-Type: " + ctype + CRLF() + "Cache-Control: no-cache" + CRLF() + "Connection: close" + CRLF() + CRLF()))
    if req.method = "HEAD" then
        http_pump(c)
        return
    end if
    ' Map the requested offset onto header + replay cache. Offsets beyond the
    ' header but before the cache start resume at the cache start.
    hl = st.header.Count()
    if off < hl then
        if off = 0 then c.q.push(st.header) else c.q.push(ba_slice(st.header, off, hl - off))
        for each ch in st.cache
            c.q.push(ch)
        end for
    else
        cpos = hl
        started = false
        for each ch in st.cache
            if started then
                c.q.push(ch)
            else if off < cpos + ch.Count() then
                started = true
                skip = off - cpos
                if skip > 0 then c.q.push(ba_slice(ch, skip, ch.Count() - skip)) else c.q.push(ch)
            end if
            cpos = cpos + ch.Count()
        end for
        if not started then
            for each ch in st.cache
                c.q.push(ch)
            end for
        end if
    end if
    c.stream = st
    st.clients[c.id] = c
    http_pump(c)
end sub

sub http_serve_hls(c as object, req as object)
    parts = req.url.Split("?")[0].Split("/")
    vs = m.vs
    body = invalid
    ctype = "video/mp4"
    if parts.Count() >= 4 and vs <> invalid and vs.init <> invalid and (parts[2] = vs.gen.toStr() or parts[2] = "current") then
        name = parts[3]
        if name = "live.m3u8" then
            body = hls_playlist(vs)
            ctype = "application/vnd.apple.mpegurl"
        else if name = "init.mp4" then
            body = vs.init
        else if Left(name, 1) = "s" and Right(name, 4) = ".m4s" then
            want = str_int(Mid(name, 2, Len(name) - 5))
            for each sg in vs.segs
                if sg.seq = want then body = sg.data
            end for
        end if
    end if
    if body = invalid then
        dbg("hls 404 " + req.url)
        sock_send_all(c.sock, ba_ascii("HTTP/1.1 404 Not Found" + CRLF() + "Content-Length: 0" + CRLF() + "Connection: close" + CRLF() + CRLF()))
        rx_close(c)
        return
    end if
    c.q.push(ba_ascii("HTTP/1.1 200 OK" + CRLF() + "Content-Type: " + ctype + CRLF() + "Content-Length: " + body.Count().toStr() + CRLF() + "Cache-Control: no-cache" + CRLF() + "Connection: close" + CRLF() + CRLF()))
    if req.method <> "HEAD" then c.q.push(body)
    c.closeWhenDone = true
    c.stream = {kind: "hls", clients: {}}
    http_pump(c)
end sub

sub http_pump(c as object)
    s = c.sock
    while c.q.Count() > 0
        ch = c.q[0]
        total = ch.Count()
        n = s.send(ch, c.qpos, total - c.qpos)
        if n <= 0 then exit while
        c.qpos = c.qpos + n
        if c.qpos >= total then
            c.q.Shift()
            c.qpos = 0
        end if
    end while
    if c.q.Count() = 0 and c.closeWhenDone then
        rx_close(c)
        return
    end if
    s.notifyWritable(c.q.Count() > 0)
    if c.q.Count() > 4000 then
        dbg("player too slow; dropping connection")
        rx_close(c)
    end if
end sub
