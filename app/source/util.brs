' Small helpers shared by the receiver. Hot paths avoid per-byte BrightScript
' loops (~3 us per byte on a Roku 2 XS) by leaning on native roByteArray /
' string operations.

sub dbg(s as string)
    ' Log to a ring buffer served at http://<roku>:8888/log. Console output is
    ' opt-in (registry key "console"): the 8085 debug console accepts one
    ' client, and a stale session that stops reading makes every print block
    ' for seconds, freezing the receiver.
    g = GetGlobalAA()
    if g.consolePrint = true then print "[airplay] "; s
    if g.logRing = invalid then
        g.logRing = []
        g.logClock = CreateObject("roTimespan")
    end if
    t = g.logClock.TotalMilliseconds()
    g.logRing.push((t \ 1000).toStr() + "." + Right("00" + (t mod 1000).toStr(), 3) + " " + s)
    if g.logRing.Count() > 2000 then g.logRing.Shift()
end sub

function CRLF() as string
    return Chr(13) + Chr(10)
end function

function ba_new(n as integer) as object
    b = CreateObject("roByteArray")
    if n > 0 then b[n - 1] = 0
    return b
end function

function ba_hex(s as string) as object
    b = CreateObject("roByteArray")
    b.FromHexString(s)
    return b
end function

function ba_ascii(s as string) as object
    b = CreateObject("roByteArray")
    b.FromAsciiString(s)
    return b
end function

' Copy n bytes from b starting at off, using native base64 + string slicing.
' b64 may be passed in (b.ToBase64String()) when slicing one buffer repeatedly.
function ba_slice(b as object, off as integer, n as integer, b64 = invalid as dynamic) as object
    out = CreateObject("roByteArray")
    if n <= 0 then return out
    if n <= 24 then
        for i = off to off + n - 1
            out.push(b[i])
        end for
        return out
    end if
    if b64 = invalid then b64 = b.ToBase64String()
    g0 = off \ 3
    lead = off - g0 * 3
    groups = (lead + n + 2) \ 3
    out.FromBase64String(Mid(b64, g0 * 4 + 1, groups * 4))
    for i = 1 to lead
        out.Shift()
    end for
    while out.Count() > n
        out.Pop()
    end while
    return out
end function

function ba_u16be(b as object, off as integer) as integer
    return (b[off] << 8) or b[off + 1]
end function

function ba_u32be(b as object, off as integer) as longinteger
    return b[off] * 16777216& + b[off + 1] * 65536& + b[off + 2] * 256& + b[off + 3]
end function

function ba_u32le(b as object, off as integer) as longinteger
    return b[off + 3] * 16777216& + b[off + 2] * 65536& + b[off + 1] * 256& + b[off]
end function

sub ba_push_u16be(b as object, v as integer)
    b.push((v >> 8) and 255)
    b.push(v and 255)
end sub

sub ba_push_u32be(b as object, v as longinteger)
    b.push(((v \ 16777216&) mod 256&))
    b.push(((v \ 65536&) mod 256&))
    b.push(((v \ 256&) mod 256&))
    b.push((v mod 256&))
end sub

' index of first CRLFCRLF at or after start, or -1
function ba_find_crlfcrlf(b as object, start as integer, n as integer) as integer
    i = start
    last = n - 4
    while i <= last
        if b[i + 3] = 10 then
            if b[i + 2] = 13 and b[i + 1] = 10 and b[i] = 13 then return i
            i = i + 1
        else if b[i + 3] = 13 then
            i = i + 1
        else
            i = i + 4
        end if
    end while
    return -1
end function

function str_int(s as string) as integer
    return Val(s.Trim(), 10)
end function

function lstr(v as dynamic) as string
    if v = invalid then return "invalid"
    t = type(v)
    if t = "roString" or t = "String" then return v
    if t = "roBoolean" or t = "Boolean" then
        if v then return "true"
        return "false"
    end if
    return v.toStr()
end function
