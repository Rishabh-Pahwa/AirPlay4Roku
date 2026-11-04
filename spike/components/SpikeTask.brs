' Feasibility spike: probes language semantics, crypto, CPU speed and
' networking on the real device. All output goes to the debug console (8085)
' prefixed with "SPIKE:".

sub init()
    m.top.functionName = "run"
end sub

sub dbg(s as string)
    print "SPIKE: "; s
end sub

sub run()
    dbg("task start")
    testEnv()
    testInts()
    testCrypto()
    bench()
    m.port = CreateObject("roMessagePort")
    m.conns = {}
    m.servers = {}
    startTcpServer(8888, "http")
    startTcpServer(7000, "airplay")
    startTcpServer(7100, "mirror")
    startMdns()
    m.top.statusText = "spike: servers up"
    m.top.serverReady = true
    eventLoop()
end sub

sub testEnv()
    di = CreateObject("roDeviceInfo")
    dbg("model=" + di.GetModel() + " ver=" + di.GetVersion() + " displayMode=" + di.GetDisplayMode())
    ips = di.GetIPAddrs()
    for each k in ips
        dbg("ip " + k + "=" + ips[k])
    end for
    dbg("toStr int=" + (42).toStr())
    x& = 1234567890123&
    dbg("toStr long=" + x&.toStr())
end sub

sub testInts()
    a% = 2147483647
    b% = a% + 1
    dbg("int ovf 2147483647+1=" + stri(b%))
    c% = &H7FFFFFFF * 3
    dbg("int mul ovf=" + stri(c%))
    n% = -8
    dbg("int -8>>1=" + stri(n% >> 1))
    hb% = &H80000000
    dbg("int &H80000000>>31=" + stri(hb% >> 31))
    dbg("int 1<<31=" + stri(1 << 31))
    l& = -8&
    dbg("long -8>>1=" + (l& >> 1).toStr())
    big& = &HFFFFFFFF&
    dbg("long &HFFFFFFFF&=" + big&.toStr())
    dbg("long mul=" + (big& * big&).toStr())
    dbg("long (1<<40)=" + (1& << 40).toStr())
    dbg("int and=" + stri(&HF0F0 and &H0FF0) + " or=" + stri(&HF0F0 or &H0FF0) + " not0=" + stri(not 0))
    dbg("long and=" + ((&HFFFFFFFFF& and &HF0F0F0F0F&)).toStr())
    m1& = 5000000000&
    m2% = 7
    dbg("mixed long*int=" + (m1& * m2%).toStr() + " type=" + type(m1& * m2%))
    dbg("int\int -7\2=" + stri(-7 \ 2) + " 7 mod 3=" + stri(7 mod 3) + " -7 mod 3=" + stri(-7 mod 3))
    ba = CreateObject("roByteArray")
    ba.push(200)
    dbg("bytearray[0]=" + stri(ba[0]) + " getSignedByte=" + stri(ba.GetSignedByte(0)))
end sub

sub testCrypto()
    ba = CreateObject("roByteArray")
    ba.FromAsciiString("abc")
    d = CreateObject("roEVPDigest")
    d.Setup("sha512")
    h = d.Process(ba)
    ok = (LCase(h) = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
    dbg("sha512 ok=" + ok.toStr())

    c = CreateObject("roEVPCipher")
    r = c.Setup(true, "aes-128-ctr", "2b7e151628aed2a6abf7158809cf4f3c", "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff", 0)
    dbg("ctr setup ret=" + stri(r))
    pt = CreateObject("roByteArray")
    pt.FromHexString("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
    p1 = CreateObject("roByteArray")
    p2 = CreateObject("roByteArray")
    for i = 0 to 6
        p1.push(pt[i])
    end for
    for i = 7 to 31
        p2.push(pt[i])
    end for
    o1 = c.Update(p1)
    o2 = c.Update(p2)
    hex = ""
    if o1 <> invalid then hex = hex + o1.ToHexString()
    if o2 <> invalid then hex = hex + o2.ToHexString()
    dbg("ctr split out=" + LCase(hex))
    dbg("ctr ok=" + (LCase(hex) = "874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff").toStr())

    e = CreateObject("roEVPCipher")
    r = e.Setup(true, "aes-128-ecb", "2b7e151628aed2a6abf7158809cf4f3c", "", 0)
    blk = CreateObject("roByteArray")
    blk.FromHexString("6bc1bee22e409f96e93d7e117393172a")
    eo = e.Update(blk)
    s = "invalid"
    if eo <> invalid then s = LCase(eo.ToHexString())
    dbg("ecb setup=" + stri(r) + " out=" + s + " (want 3ad77bb40d7a3660a89ecaf32466ef97)")

    cbc = CreateObject("roEVPCipher")
    r = cbc.Setup(false, "aes-128-cbc", "2b7e151628aed2a6abf7158809cf4f3c", "000102030405060708090a0b0c0d0e0f", 0)
    ct = CreateObject("roByteArray")
    ct.FromHexString("7649abac8119b246cee98e9b12e9197d")
    co = cbc.Update(ct)
    s = "invalid"
    if co <> invalid then s = LCase(co.ToHexString())
    dbg("cbc-dec setup=" + stri(r) + " out=" + s + " (want 6bc1bee22e409f96e93d7e117393172a)")

    hm = CreateObject("roHMAC")
    dbg("roHMAC=" + type(hm))
end sub

sub bench()
    ts = CreateObject("roTimespan")
    a = []
    b = []
    t = []
    for i = 0 to 15
        a.push(65000& + i)
        b.push(64000& + i)
    end for
    for i = 0 to 31
        t.push(0&)
    end for
    ts.Mark()
    for it = 1 to 100
        for i = 0 to 31
            t[i] = 0&
        end for
        for i = 0 to 15
            ai = a[i]
            for j = 0 to 15
                t[i + j] = t[i + j] + ai * b[j]
            end for
        end for
    end for
    ms = ts.TotalMilliseconds()
    dbg("bench 100x 16x16 long mul: " + stri(ms) + " ms")

    ba = CreateObject("roByteArray")
    ba[99999] = 0
    ts.Mark()
    s = 0
    for i = 0 to 99999
        s = s + ba[i]
    end for
    dbg("bench 100k bytearray reads: " + stri(ts.TotalMilliseconds()) + " ms")

    ts.Mark()
    out = CreateObject("roByteArray")
    for i = 0 to 9999
        out.push(i and 255)
    end for
    dbg("bench 10k bytearray push: " + stri(ts.TotalMilliseconds()) + " ms")

    src = CreateObject("roByteArray")
    src[187999] = 1
    ts.Mark()
    dst = CreateObject("roByteArray")
    for p = 0 to 999
        dst.Append(src)
        if dst.Count() > 1000000 then dst.Clear()
    end for
    dbg("bench 1000x Append(188k): " + stri(ts.TotalMilliseconds()) + " ms")

    big = CreateObject("roByteArray")
    big[1999999] = 0
    c = CreateObject("roEVPCipher")
    c.Setup(true, "aes-128-ctr", "2b7e151628aed2a6abf7158809cf4f3c", "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff", 0)
    ts.Mark()
    o = c.Update(big)
    dbg("bench aes-ctr 2MB: " + stri(ts.TotalMilliseconds()) + " ms")

    ts.Mark()
    str = ""
    for i = 0 to 999
        str = str + "x"
    end for
    dbg("bench 1000 str concat: " + stri(ts.TotalMilliseconds()) + " ms")
end sub

sub startTcpServer(portNum as integer, kind as string)
    addr = CreateObject("roSocketAddress")
    addr.setPort(portNum)
    s = CreateObject("roStreamSocket")
    s.setMessagePort(m.port)
    okAddr = s.setAddress(addr)
    s.notifyReadable(true)
    okListen = s.listen(4)
    dbg("tcp " + kind + " port " + stri(portNum) + " bind=" + okAddr.toStr() + " listen=" + okListen.toStr() + " isListening=" + s.isListening().toStr())
    m.servers[s.getID().toStr()] = {sock: s, kind: kind}
end sub

sub startMdns()
    s = CreateObject("roDataGramSocket")
    s.setMessagePort(m.port)
    s.setReuseAddr(true)
    addr = CreateObject("roSocketAddress")
    addr.setPort(5353)
    okAddr = s.setAddress(addr)
    grp = CreateObject("roSocketAddress")
    grp.setAddress("224.0.0.251")
    okJoin = s.joinGroup(grp)
    s.setMulticastLoop(false)
    s.setMulticastTTL(255)
    s.notifyReadable(true)
    dbg("mdns bind=" + okAddr.toStr() + " join=" + okJoin.toStr() + " status=" + stri(s.status()))
    m.mdns = s
    m.mdnsCount = 0
    m.mdnsBuf = CreateObject("roByteArray")
    m.mdnsBuf[8999] = 0
end sub

sub eventLoop()
    while true
        msg = wait(5000, m.port)
        if type(msg) = "roSocketEvent" then
            id = msg.getSocketID().toStr()
            if m.mdns <> invalid and id = m.mdns.getID().toStr() then
                onMdns()
            else if m.servers.doesExist(id) then
                srv = m.servers[id]
                if srv.sock.isReadable() then
                    cs = srv.sock.accept()
                    if cs <> invalid then
                        cs.setMessagePort(m.port)
                        cs.notifyReadable(true)
                        m.conns[cs.getID().toStr()] = {sock: cs, kind: srv.kind, inbuf: "", out: invalid, outPos: 0}
                        dbg("accept " + srv.kind + " from " + cs.getReceivedFromAddress().getAddress())
                    end if
                end if
            else if m.conns.doesExist(id) then
                onConn(m.conns[id], id)
            end if
        end if
    end while
end sub

sub onMdns()
    s = m.mdns
    while s.isReadable()
        n = s.receive(m.mdnsBuf, 0, 9000)
        if n <= 0 then exit while
        m.mdnsCount = m.mdnsCount + 1
        if m.mdnsCount <= 15 then
            from = s.getReceivedFromAddress().getAddress()
            dbg("mdns pkt #" + stri(m.mdnsCount) + " len=" + stri(n) + " from=" + from + " q0=" + dnsName(m.mdnsBuf, 12, n))
        end if
    end while
end sub

function dnsName(b as object, off as integer, n as integer) as string
    name = ""
    guard = 0
    while off < n and guard < 20
        l = b[off]
        if l = 0 then exit while
        if l >= 192 then
            name = name + "<ptr>"
            exit while
        end if
        lab = CreateObject("roByteArray")
        for i = 1 to l
            lab.push(b[off + i])
        end for
        name = name + lab.ToAsciiString() + "."
        off = off + l + 1
        guard = guard + 1
    end while
    return name
end function

sub onConn(c as object, id as string)
    s = c.sock
    if s.isReadable() then
        avail = s.getCountRcvBuf()
        if avail = 0 then
            dbg("conn " + c.kind + " closed by peer")
            s.close()
            m.conns.delete(id)
            return
        end if
        c.inbuf = c.inbuf + s.receiveStr(avail)
        if c.kind = "http" then
            idx = Instr(1, c.inbuf, Chr(13) + Chr(10) + Chr(13) + Chr(10))
            if idx > 0 then
                line = c.inbuf.split(Chr(13) + Chr(10))[0]
                parts = line.split(" ")
                path = parts[1]
                dbg("http req " + line)
                c.inbuf = ""
                serveFile(c, path)
            end if
        else
            dbg("conn " + c.kind + " got " + stri(Len(c.inbuf)) + " chars: " + Left(c.inbuf, 200))
        end if
    end if
    if s.isWritable() and c.out <> invalid then
        pumpOut(c, id)
    end if
end sub

sub serveFile(c as object, path as string)
    q = Instr(1, path, "?")
    if q > 0 then path = Left(path, q - 1)
    body = CreateObject("roByteArray")
    ctype = "application/octet-stream"
    if path.Right(5) = ".m3u8" then ctype = "application/vnd.apple.mpegurl"
    if path.Right(3) = ".ts" then ctype = "video/mp2t"
    if path.Right(4) = ".m4a" then ctype = "audio/mp4"
    if path.Right(4) = ".wav" then ctype = "audio/wav"
    ok = body.ReadFile("pkg:/media" + path)
    if ok then
        hdr = "HTTP/1.1 200 OK" + Chr(13) + Chr(10) + "Content-Type: " + ctype + Chr(13) + Chr(10) + "Content-Length: " + body.Count().toStr() + Chr(13) + Chr(10) + "Connection: close" + Chr(13) + Chr(10) + Chr(13) + Chr(10)
    else
        hdr = "HTTP/1.1 404 Not Found" + Chr(13) + Chr(10) + "Content-Length: 0" + Chr(13) + Chr(10) + "Connection: close" + Chr(13) + Chr(10) + Chr(13) + Chr(10)
        body = CreateObject("roByteArray")
    end if
    out = CreateObject("roByteArray")
    out.FromAsciiString(hdr)
    out.Append(body)
    c.out = out
    c.outPos = 0
    c.sock.notifyWritable(true)
    pumpOut(c, c.sock.getID().toStr())
end sub

sub pumpOut(c as object, id as string)
    s = c.sock
    total = c.out.Count()
    while c.outPos < total
        n = s.send(c.out, c.outPos, total - c.outPos)
        if n <= 0 then exit while
        c.outPos = c.outPos + n
    end while
    if c.outPos >= total then
        s.notifyWritable(false)
        c.out = invalid
        s.close()
        m.conns.delete(id)
    end if
end sub
