' Spike 2: arithmetic micro-benchmarks + HTTP server with a throttled
' "live" mode that drip-feeds a file at roughly real-time rate with no
' Content-Length, to emulate a never-ending mirror stream.

sub init()
    m.top.functionName = "run"
end sub

sub dbg(s as string)
    print "SPIKE: "; s
end sub

sub run()
    m.port = CreateObject("roMessagePort")
    m.conns = {}
    addr = CreateObject("roSocketAddress")
    addr.setPort(8888)
    m.srv = CreateObject("roStreamSocket")
    m.srv.setMessagePort(m.port)
    m.srv.setAddress(addr)
    m.srv.notifyReadable(true)
    m.srv.listen(4)
    m.top.serverReady = true
    tick = CreateObject("roTimespan")
    tick.Mark()
    while true
        msg = wait(50, m.port)
        if type(msg) = "roSocketEvent" then
            id = msg.getSocketID()
            if id = m.srv.getID() then
                cs = m.srv.accept()
                if cs <> invalid then
                    cs.setMessagePort(m.port)
                    cs.notifyReadable(true)
                    m.conns[cs.getID().toStr()] = {sock: cs, inbuf: "", out: invalid, outPos: 0, limit: 0, live: false, rate: 0}
                end if
            else if m.conns.doesExist(id.toStr()) then
                onConn(m.conns[id.toStr()], id.toStr())
            end if
        end if
        if tick.TotalMilliseconds() >= 100 then
            tick.Mark()
            for each k in m.conns.keys()
                c = m.conns[k]
                if c <> invalid and c.live and c.out <> invalid then
                    c.limit = c.limit + c.rate
                    pumpOut(c, k)
                end if
            end for
        end if
    end while
end sub

sub benchArith()
    ts = CreateObject("roTimespan")
    N = 25600

    ts.Mark()
    for i = 1 to N
    end for
    dbg("empty loop 25600: " + ts.TotalMilliseconds().toStr() + " ms")

    ts.Mark()
    x% = 0
    a% = 12345
    b% = 23456
    for i = 1 to N
        x% = x% + a% * b%
    end for
    dbg("int local muladd: " + ts.TotalMilliseconds().toStr() + " ms")

    ts.Mark()
    xl& = 0&
    al& = 12345&
    bl& = 23456&
    for i = 1 to N
        xl& = xl& + al& * bl&
    end for
    dbg("long local muladd: " + ts.TotalMilliseconds().toStr() + " ms")

    ts.Mark()
    xd# = 0#
    ad# = 12345#
    bd# = 23456#
    for i = 1 to N
        xd# = xd# + ad# * bd#
    end for
    dbg("double local muladd: " + ts.TotalMilliseconds().toStr() + " ms")

    ia = []
    for i = 0 to 31
        ia.push(i + 1000)
    end for
    ts.Mark()
    x% = 0
    for i = 1 to N
        x% = x% + ia[i and 15] * ia[(i and 15) + 16]
    end for
    dbg("int array muladd: " + ts.TotalMilliseconds().toStr() + " ms")

    la = []
    for i = 0 to 31
        la.push(1000& + i)
    end for
    ts.Mark()
    xl& = 0&
    for i = 1 to N
        xl& = xl& + la[i and 15] * la[(i and 15) + 16]
    end for
    dbg("long array muladd: " + ts.TotalMilliseconds().toStr() + " ms")

    da = []
    for i = 0 to 31
        da.push(1000# + i)
    end for
    ts.Mark()
    xd# = 0#
    for i = 1 to N
        xd# = xd# + da[i and 15] * da[(i and 15) + 16]
    end for
    dbg("double array muladd: " + ts.TotalMilliseconds().toStr() + " ms")

    ' Unrolled: 256 reps of a 10-term long dot product written out
    a0& = 1001&: a1& = 1002&: a2& = 1003&: a3& = 1004&: a4& = 1005&
    a5& = 1006&: a6& = 1007&: a7& = 1008&: a8& = 1009&: a9& = 1010&
    b0& = 2001&: b1& = 2002&: b2& = 2003&: b3& = 2004&: b4& = 2005&
    b5& = 2006&: b6& = 2007&: b7& = 2008&: b8& = 2009&: b9& = 2010&
    ts.Mark()
    for i = 1 to 2560
        r& = a0& * b0& + a1& * b1& + a2& * b2& + a3& * b3& + a4& * b4& + a5& * b5& + a6& * b6& + a7& * b7& + a8& * b8& + a9& * b9&
    end for
    dbg("long unrolled 25600 muladds: " + ts.TotalMilliseconds().toStr() + " ms")

    c0% = 1001: c1% = 1002: c2% = 1003: c3% = 1004: c4% = 1005
    c5% = 1006: c6% = 1007: c7% = 1008: c8% = 1009: c9% = 1010
    ts.Mark()
    for i = 1 to 2560
        r% = c0% * c1% + c1% * c2% + c2% * c3% + c3% * c4% + c4% * c5% + c5% * c6% + c6% * c7% + c7% * c8% + c8% * c9% + c9% * c0%
    end for
    dbg("int unrolled 25600 muladds: " + ts.TotalMilliseconds().toStr() + " ms")

    d0# = 1001#: d1# = 1002#: d2# = 1003#: d3# = 1004#: d4# = 1005#
    d5# = 1006#: d6# = 1007#: d7# = 1008#: d8# = 1009#: d9# = 1010#
    ts.Mark()
    for i = 1 to 2560
        r# = d0# * d1# + d1# * d2# + d2# * d3# + d3# * d4# + d4# * d5# + d5# * d6# + d6# * d7# + d7# * d8# + d8# * d9# + d9# * d0#
    end for
    dbg("double unrolled 25600 muladds: " + ts.TotalMilliseconds().toStr() + " ms")

    ' carry extraction costs
    ts.Mark()
    v& = 123456789012345&
    for i = 1 to 2560
        q& = v& >> 26
        lo& = v& and &H3FFFFFF&
    end for
    dbg("long shift+mask x2560: " + ts.TotalMilliseconds().toStr() + " ms")
    ts.Mark()
    vd# = 123456789012345#
    for i = 1 to 2560
        qd# = Int(vd# * 1.4901161193847656e-08#)
    end for
    dbg("double Int() x2560: " + ts.TotalMilliseconds().toStr() + " ms q=" + qd#.toStr())

    ts.Mark()
    for i = 1 to 2560
        noop()
    end for
    dbg("2560 sub calls: " + ts.TotalMilliseconds().toStr() + " ms")

    ' bytearray native slice options
    src = CreateObject("roByteArray")
    src[99999] = 7
    src.WriteFile("tmp:/slice.bin")
    ts.Mark()
    for i = 1 to 200
        part = CreateObject("roByteArray")
        part.ReadFile("tmp:/slice.bin", i * 100, 184)
    end for
    dbg("200 ReadFile(range 184): " + ts.TotalMilliseconds().toStr() + " ms")
    ts.Mark()
    for i = 1 to 200
        src.AppendFile("tmp:/out.bin", i * 100, 184)
    end for
    dbg("200 AppendFile(range 184): " + ts.TotalMilliseconds().toStr() + " ms")
    ts.Mark()
    for i = 1 to 200
        h = CreateObject("roByteArray")
        h.FromHexString("47400010")
    end for
    dbg("200 FromHexString(4B): " + ts.TotalMilliseconds().toStr() + " ms")
end sub

sub noop()
end sub

sub onConn(c as object, id as string)
    s = c.sock
    if s.isReadable() then
        avail = s.getCountRcvBuf()
        if avail = 0 then
            s.close()
            m.conns.delete(id)
            return
        end if
        c.inbuf = c.inbuf + s.receiveStr(avail)
        if Instr(1, c.inbuf, Chr(13) + Chr(10) + Chr(13) + Chr(10)) > 0 then
            line = c.inbuf.split(Chr(13) + Chr(10))[0]
            hdrs = c.inbuf
            c.inbuf = ""
            dbg("http req " + line)
            rng = ""
            for each h in hdrs.split(Chr(13) + Chr(10))
                if LCase(Left(h, 6)) = "range:" then rng = h
            end for
            if rng <> "" then dbg("  " + rng)
            off = 0
            if rng <> "" then off = Val(rng.split("=")[1].split("-")[0])
            serveFile(c, line.split(" ")[1], off)
        end if
    end if
    if c.out <> invalid and s.isWritable() then pumpOut(c, id)
end sub

sub serveFile(c as object, path as string, off as integer)
    rate = 0
    q = Instr(1, path, "?rate=")
    if q > 0 then
        rate = Val(Mid(path, q + 6))
        path = Left(path, q - 1)
    end if
    live = (Left(path, 6) = "/live/")
    if live then path = Mid(path, 6)
    body = CreateObject("roByteArray")
    ok = body.ReadFile("pkg:/media" + path)
    crlf = Chr(13) + Chr(10)
    if not ok then
        hdr = "HTTP/1.1 404 Not Found" + crlf + "Content-Length: 0" + crlf + "Connection: close" + crlf + crlf
        body = CreateObject("roByteArray")
    else if live then
        hdr = "HTTP/1.1 200 OK" + crlf + "Content-Type: video/x-matroska" + crlf + "Connection: close" + crlf + crlf
    else
        hdr = "HTTP/1.1 200 OK" + crlf + "Content-Length: " + body.Count().toStr() + crlf + "Connection: close" + crlf + crlf
    end if
    out = CreateObject("roByteArray")
    out.FromAsciiString(hdr)
    if off > 0 and ok then
        tmpb = CreateObject("roByteArray")
        body.WriteFile("tmp:/b.bin")
        tmpb.ReadFile("tmp:/b.bin", off, body.Count() - off)
        body = tmpb
    end if
    out.Append(body)
    c.out = out
    c.outPos = 0
    c.live = live and ok
    if c.live then
        ' ~ real time for the 30 s / ~1 MB test file, per 100 ms tick
        c.rate = rate
        c.limit = out.Count() - body.Count() + rate
    else
        c.limit = out.Count()
    end if
    c.sock.notifyWritable(true)
    pumpOut(c, c.sock.getID().toStr())
end sub

sub pumpOut(c as object, id as string)
    s = c.sock
    total = c.out.Count()
    lim = c.limit
    if lim > total then lim = total
    while c.outPos < lim
        n = s.send(c.out, c.outPos, lim - c.outPos)
        if n <= 0 then exit while
        c.outPos = c.outPos + n
    end while
    if c.outPos >= total then
        s.notifyWritable(false)
        c.out = invalid
        s.close()
        m.conns.delete(id)
    else if c.outPos >= lim then
        s.notifyWritable(false)
    else
        s.notifyWritable(true)
    end if
end sub
