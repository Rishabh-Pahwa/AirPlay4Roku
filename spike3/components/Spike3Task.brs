' Serves pre-generated live test media on the schedule a sender would produce it.
sub init()
    m.top.functionName = "run"
end sub

function loadSched(name as string) as object
    rows = []
    txt = ReadAsciiFile("pkg:/media/" + name + ".sched")
    for each ln in txt.Split(Chr(10))
        p = ln.Trim().Split(" ")
        if p.Count() >= 4 then rows.push({ms: Val(p[0], 10), v: Val(p[1], 10), media: Val(p[2], 10), d: p[3]})
    end for
    return rows
end function

sub run()
    m.port = CreateObject("roMessagePort")
    m.conns = {}
    a = CreateObject("roSocketAddress")
    a.setPort(8888)
    m.srv = CreateObject("roStreamSocket")
    m.srv.setMessagePort(m.port)
    m.srv.setAddress(a)
    m.srv.notifyReadable(true)
    m.srv.listen(8)
    m.top.observeField("step", m.port)
    m.cur = ""
    m.clock = CreateObject("roTimespan")
    m.top.ready = true
    while true
        msg = wait(20, m.port)
        t = type(msg)
        if t = "roSGNodeEvent" then
            for each k in m.conns.Keys()
                m.conns[k].sock.close()
            end for
            m.conns = {}
            m.cur = m.top.step
            m.sched = loadSched(m.cur)
            m.isHls = (Left(m.cur, 3) <> "low")

            if not m.isHls then
                m.file = CreateObject("roByteArray")
                m.file.ReadFile("pkg:/media/" + m.cur + ".mkv")
            end if
            m.clock.Mark()
        else if t = "roSocketEvent" then
            id = msg.getSocketID()
            if id = m.srv.getID() then
                cs = m.srv.accept()
                if cs <> invalid then
                    cs.setMessagePort(m.port)
                    cs.notifyReadable(true)
                    m.conns[cs.getID().toStr()] = {sock: cs, inb: "", out: invalid, pos: 0, live: false, off: 0}
                end if
            else if m.conns.DoesExist(id.toStr()) then
                onConn(m.conns[id.toStr()], id.toStr())
            end if
        end if
        release()
    end while
end sub

' how much is available now
sub release()
    if m.cur = "" then return
    el = m.clock.TotalMilliseconds()
    relMs = 0
    m.availBytes = 0
    m.availSegs = 0
    for each r in m.sched
        if m.isHls then
            if r.ms <= el then
                m.availSegs = r.v + 1
                relMs = r.media
            end if
        else
            if r.ms <= el then
                m.availBytes = r.v
                relMs = r.ms
            end if
        end if
    end for
    m.top.releasedMs = relMs
    if not m.isHls then
        for each k in m.conns.Keys()
            c = m.conns[k]
            if c <> invalid and c.live then pump(c, k)
        end for
    end if
end sub

sub onConn(c as object, id as string)
    s = c.sock
    if s.isReadable() then
        n = s.getCountRcvBuf()
        if n = 0 then
            s.close()
            m.conns.Delete(id)
            return
        end if
        c.inb = c.inb + s.receiveStr(n)
        if Instr(1, c.inb, Chr(13) + Chr(10) + Chr(13) + Chr(10)) > 0 then
            lines = c.inb.Split(Chr(13) + Chr(10))
            path = lines[0].Split(" ")[1]
            rng = 0
            for each h in lines
                if LCase(Left(h, 6)) = "range:" then rng = Val(h.Split("=")[1].Split("-")[0], 10)
            end for
            c.inb = ""
            print "SPIKE:   GET "; path; " range="; rng; " t="; m.clock.TotalMilliseconds()
            serve(c, id, path, rng)
        end if
    end if
    if c.out <> invalid and s.isWritable() then pump(c, id)
end sub

sub serve(c as object, id as string, path as string, rng as integer)
    crlf = Chr(13) + Chr(10)
    if Left(path, 5) = "/mkv/" then
        c.live = true
        c.off = rng
        c.hdrSent = false
        c.hdr = "HTTP/1.1 200 OK" + crlf + "Content-Type: video/x-matroska" + crlf + "Connection: close" + crlf + crlf
        c.out = m.file
        c.pos = rng
        pump(c, id)
        return
    end if
    parts = path.Split("/")
    fname = parts[parts.Count() - 1]
    body = CreateObject("roByteArray")
    code = "200 OK"
    ctype = "video/mp4"
    if fname = "live.m3u8" or fname = "win.m3u8" then
        ctype = "application/vnd.apple.mpegurl"
        first = 0
        if fname = "win.m3u8" and m.availSegs > 4 then first = m.availSegs - 4
        pl = "#EXTM3U" + crlf + "#EXT-X-VERSION:7" + crlf + "#EXT-X-TARGETDURATION:1" + crlf + "#EXT-X-MEDIA-SEQUENCE:" + first.toStr() + crlf + "#EXT-X-MAP:URI=" + Chr(34) + "init.mp4" + Chr(34) + crlf
        for i = first to m.availSegs - 1
            pl = pl + "#EXTINF:" + m.sched[i].d + "," + crlf + "s" + i.toStr() + ".m4s" + crlf
        end for
        body.FromAsciiString(pl)
    else
        dir = m.cur

        ok = body.ReadFile("pkg:/media/" + dir + "/" + fname)
        if not ok then code = "404 Not Found"
    end if
    out = CreateObject("roByteArray")
    out.FromAsciiString("HTTP/1.1 " + code + crlf + "Content-Type: " + ctype + crlf + "Content-Length: " + body.Count().toStr() + crlf + "Connection: close" + crlf + crlf)
    out.Append(body)
    c.hdrSent = true
    c.out = out
    c.pos = 0
    c.live = false
    pump(c, id)
end sub

sub pump(c as object, id as string)
    s = c.sock
    if not c.hdrSent then
        h = CreateObject("roByteArray")
        h.FromAsciiString(c.hdr)
        s.send(h, 0, h.Count())
        c.hdrSent = true
    end if
    lim = c.out.Count()
    if c.live then lim = m.availBytes
    while c.pos < lim
        n = s.send(c.out, c.pos, lim - c.pos)
        if n <= 0 then exit while
        c.pos = c.pos + n
    end while
    if not c.live and c.pos >= c.out.Count() then
        s.close()
        m.conns.Delete(id)
        return
    end if
    s.notifyWritable(c.pos < lim)
end sub
