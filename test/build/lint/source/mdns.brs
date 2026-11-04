' Minimal mDNS / DNS-SD responder (RFC 6762/6763) advertising
'   <name>._airplay._tcp.local   (port 7000)
'   <MACHEX>@<name>._raop._tcp.local (port 7000)
' plus an A record for our own host name. Runs on the receiver task's port.
'
' cfg: {name, host, ip, port, deviceId (AA:BB:..), airplayTxt [], raopTxt []}

function mdns_start(port as object, cfg as object) as object
    s = CreateObject("roDataGramSocket")
    s.setMessagePort(port)
    s.setReuseAddr(true)
    a = CreateObject("roSocketAddress")
    a.setPort(5353)
    okBind = s.setAddress(a)
    grp = CreateObject("roSocketAddress")
    grp.setAddress("224.0.0.251")
    okJoin = s.joinGroup(grp)
    s.setMulticastLoop(false)
    s.setMulticastTTL(255)
    s.notifyReadable(true)
    dbg("mdns bind=" + lstr(okBind) + " join=" + lstr(okJoin))
    mc = CreateObject("roSocketAddress")
    mc.setAddress("224.0.0.251:5353")
    rbuf = ba_new(9000)
    machex = cfg.deviceId.Split(":").Join("")
    st = {
        sock: s, mcast: mc, buf: rbuf, cfg: cfg,
        airplayInst: cfg.name + "._airplay._tcp.local",
        raopInst: machex + "@" + cfg.name + "._raop._tcp.local",
        hostName: cfg.host + ".local",
        announced: 0, nextAnnounce: 0
    }
    return st
end function

' ---------------------------------------------------------------- encoding

sub dns_put_name(b as object, name as string)
    ' labels may contain '.' only as separators; instance names must not contain dots
    parts = mdns_split_labels(name)
    for each p in parts
        lb = ba_ascii(p)
        b.push(lb.Count())
        b.Append(lb)
    end for
    b.push(0)
end sub

' Splits "Instance Name._airplay._tcp.local" into labels. The instance label is
' everything before the service-type part so it may contain spaces.
function mdns_split_labels(name as string) as object
    out = []
    for each p in name.Split(".")
        if p <> "" then out.push(p)
    end for
    return out
end function

sub dns_put_rr(b as object, name as string, rtype as integer, cacheFlush as boolean, ttl as integer, rdata as object)
    dns_put_name(b, name)
    ba_push_u16be(b, rtype)
    cls = 1
    if cacheFlush then cls = &H8001
    ba_push_u16be(b, cls)
    ba_push_u32be(b, ttl + 0&)
    ba_push_u16be(b, rdata.Count())
    b.Append(rdata)
end sub

function dns_name_rdata(name as string) as object
    r = CreateObject("roByteArray")
    dns_put_name(r, name)
    return r
end function

function dns_txt_rdata(items as object) as object
    r = CreateObject("roByteArray")
    for each it in items
        lb = ba_ascii(it)
        r.push(lb.Count())
        r.Append(lb)
    end for
    return r
end function

function dns_srv_rdata(port as integer, target as string) as object
    r = CreateObject("roByteArray")
    ba_push_u16be(r, 0)
    ba_push_u16be(r, 0)
    ba_push_u16be(r, port)
    dns_put_name(r, target)
    return r
end function

function dns_a_rdata(ip as string) as object
    r = CreateObject("roByteArray")
    for each p in ip.Split(".")
        r.push(str_int(p))
    end for
    return r
end function

' Build a response packet. which: AA of flags {airplay, raop, host, services}
function mdns_build(st as object, which as object, ttlScale as integer, qid as integer, questions as object) as object
    cfg = st.cfg
    rrs = []
    t1 = 4500 * ttlScale
    t2 = 120 * ttlScale
    if which.services then
        rrs.push({n: "_services._dns-sd._udp.local", t: 12, f: false, ttl: t1, d: dns_name_rdata("_airplay._tcp.local")})
        rrs.push({n: "_services._dns-sd._udp.local", t: 12, f: false, ttl: t1, d: dns_name_rdata("_raop._tcp.local")})
    end if
    if which.airplay then
        rrs.push({n: "_airplay._tcp.local", t: 12, f: false, ttl: t1, d: dns_name_rdata(st.airplayInst)})
        rrs.push({n: st.airplayInst, t: 33, f: true, ttl: t2, d: dns_srv_rdata(cfg.port, st.hostName)})
        rrs.push({n: st.airplayInst, t: 16, f: true, ttl: t1, d: dns_txt_rdata(cfg.airplayTxt)})
    end if
    if which.raop then
        rrs.push({n: "_raop._tcp.local", t: 12, f: false, ttl: t1, d: dns_name_rdata(st.raopInst)})
        rrs.push({n: st.raopInst, t: 33, f: true, ttl: t2, d: dns_srv_rdata(cfg.port, st.hostName)})
        rrs.push({n: st.raopInst, t: 16, f: true, ttl: t1, d: dns_txt_rdata(cfg.raopTxt)})
    end if
    if which.airplay or which.raop or which.host then
        rrs.push({n: st.hostName, t: 1, f: true, ttl: t2, d: dns_a_rdata(cfg.ip)})
    end if
    b = CreateObject("roByteArray")
    ba_push_u16be(b, qid)
    ba_push_u16be(b, &H8400)
    nq = 0
    if questions <> invalid then nq = questions.Count()
    ba_push_u16be(b, nq)
    ba_push_u16be(b, rrs.Count())
    ba_push_u16be(b, 0)
    ba_push_u16be(b, 0)
    if questions <> invalid then
        for each q in questions
            dns_put_name(b, q.name)
            ba_push_u16be(b, q.qtype)
            ba_push_u16be(b, 1)
        end for
    end if
    for each r in rrs
        dns_put_rr(b, r.n, r.t, r.f, r.ttl, r.d)
    end for
    return b
end function

' ---------------------------------------------------------------- decoding

' returns {name (lowercase, dotted, no trailing dot), next}
function dns_read_name(b as object, off as integer, n as integer) as object
    labels = []
    nextOff = -1
    jumps = 0
    while off < n and jumps < 16
        l = b[off]
        if l = 0 then
            off = off + 1
            exit while
        else if l >= 192 then
            if nextOff < 0 then nextOff = off + 2
            off = ((l and 63) << 8) or b[off + 1]
            jumps = jumps + 1
        else
            labels.push(ba_slice(b, off + 1, l).ToAsciiString())
            off = off + 1 + l
        end if
    end while
    if nextOff < 0 then nextOff = off
    return {name: LCase(labels.Join(".")), nxt: nextOff}
end function

sub mdns_on_readable(st as object)
    s = st.sock
    while s.isReadable()
        n = s.receive(st.buf, 0, 9000)
        if n <= 12 then exit while
        from = s.getReceivedFromAddress()
        mdns_handle_query(st, n, from)
    end while
end sub

sub mdns_handle_query(st as object, n as integer, from as object)
    b = st.buf
    flags = ba_u16be(b, 2)
    if (flags and &H8000) <> 0 then return
    qid = ba_u16be(b, 0)
    qd = ba_u16be(b, 4)
    off = 12
    which = {airplay: false, raop: false, host: false, services: false}
    hit = false
    unicastWanted = false
    qs = []
    ap = LCase(st.airplayInst)
    ra = LCase(st.raopInst)
    hn = LCase(st.hostName)
    for i = 1 to qd
        if off >= n then exit for
        r = dns_read_name(b, off, n)
        off = r.nxt
        if off + 4 > n then exit for
        qtype = ba_u16be(b, off)
        qclass = ba_u16be(b, off + 2)
        off = off + 4
        if (qclass and &H8000) <> 0 then unicastWanted = true
        nm = r.name
        matched = true
        if nm = "_airplay._tcp.local" or nm = ap then
            which.airplay = true
        else if nm = "_raop._tcp.local" or nm = ra then
            which.raop = true
        else if nm = hn then
            which.host = true
        else if nm = "_services._dns-sd._udp.local" then
            which.services = true
        else
            matched = false
        end if
        if matched then
            hit = true
            qs.push({name: r.name, qtype: qtype})
        end if
    end for
    if not hit then return
    port = from.getPort()
    if port <> 5353 then
        ' legacy unicast query: answer directly, echo id + questions, short TTLs
        pkt = mdns_build(st, which, 1, qid, qs)
        st.sock.setSendToAddress(from)
        st.sock.send(pkt, 0, pkt.Count())
        return
    end if
    pkt = mdns_build(st, which, 1, 0, invalid)
    if unicastWanted then
        st.sock.setSendToAddress(from)
        st.sock.send(pkt, 0, pkt.Count())
    end if
    st.sock.setSendToAddress(st.mcast)
    st.sock.send(pkt, 0, pkt.Count())
end sub

sub mdns_announce(st as object)
    pkt = mdns_build(st, {airplay: true, raop: true, host: true, services: true}, 1, 0, invalid)
    st.sock.setSendToAddress(st.mcast)
    st.sock.send(pkt, 0, pkt.Count())
    st.announced = st.announced + 1
end sub

sub mdns_goodbye(st as object)
    pkt = mdns_build(st, {airplay: true, raop: true, host: false, services: false}, 0, 0, invalid)
    st.sock.setSendToAddress(st.mcast)
    st.sock.send(pkt, 0, pkt.Count())
end sub
