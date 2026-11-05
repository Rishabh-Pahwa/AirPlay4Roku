' AirPlay video-URL playback ("AirPlay video", the non-mirroring mode).
'
' The sender doesn't stream pixels: it hands the receiver a URL (POST /play,
' Content-Location) and the Roku's own player fetches and plays it, with audio,
' at full quality. The sender then drives playback (/rate, /scrub, /stop) and
' polls /playback-info for its progress bar. A second connection is upgraded
' with POST /reverse (PTTH/1.0); the receiver sends state events
' (POST /event) to the sender over it.
'
' Protocol as handled by UxPlay (lib/http_handlers.h) and trimeplay. This file
' handles direct http(s) locations only; YouTube's sender-provided HLS
' playlists (FCUP requests, POST /action) are not implemented yet.

' Returns true if the request was a video-URL request (and has been answered).
function vid_handle(c as object, req as object) as boolean
    meth = req.method
    url = req.url
    path = url.Split("?")[0]
    if meth = "POST" and path = "/reverse" then
        vid_reverse(c, req)
    else if meth = "GET" and path = "/server-info" then
        vid_server_info(c, req)
    else if meth = "POST" and path = "/play" then
        vid_play(c, req)
    else if meth = "POST" and path = "/rate" then
        v = Val(vid_query(url, "value"))
        if m.url <> invalid then
            if v = 0 then
                m.top.videoCmd = {op: "pause"}
            else
                m.top.videoCmd = {op: "resume"}
            end if
        end if
        rtsp_reply(c, req, 200, {}, "", invalid)
    else if path = "/scrub" then
        if meth = "POST" then
            p = Val(vid_query(url, "position"))
            dbg("  scrub to " + vid_sec(p))
            if m.url <> invalid then
                m.url.pos = p
                m.top.videoCmd = {op: "seek", pos: p}
            end if
            rtsp_reply(c, req, 200, {}, "", invalid)
        else
            d = 0
            p = 0
            if m.url <> invalid then
                d = m.url.dur
                p = m.url.pos
            end if
            body = "duration: " + vid_sec(d) + Chr(10) + "position: " + vid_sec(p) + Chr(10)
            rtsp_reply(c, req, 200, {}, "text/parameters", ba_ascii(body))
        end if
    else if meth = "POST" and path = "/stop" then
        vid_stop("stopped by sender", false)
        rtsp_reply(c, req, 200, {}, "", invalid)
    else if meth = "GET" and path = "/playback-info" then
        vid_playback_info(c, req)
    else if meth = "PUT" and path = "/setProperty" then
        dbg("  " + vid_body_dump(req))
        body = vid_plist_xml("<key>errorCode</key><integer>0</integer>")
        rtsp_reply(c, req, 200, {}, "text/x-apple-plist+xml", ba_ascii(body))
    else if path = "/getProperty" then
        rtsp_reply(c, req, 200, {}, "", invalid)
    else if meth = "POST" and path = "/fp-setup2" then
        ' A FairPlay variant nobody has reverse-engineered. UxPlay answers 421
        ' and the sender carries on without it (a 404 made iOS retry and give up).
        v = -1
        if req.body.Count() > 4 then v = req.body[4]
        dbg("  fp-setup2 (version " + v.toStr() + ") not supported -> 421")
        rtsp_reply(c, req, 421, {}, "", invalid)
    else if meth = "POST" and path = "/action" then
        vid_action(c, req)
    else
        return false
    end if
    return true
end function

' value of one query parameter ("" if absent)
function vid_query(url as string, key as string) as string
    q = url.Split("?")
    if q.Count() < 2 then return ""
    for each kv in q[1].Split("&")
        p = Instr(1, kv, "=")
        if p > 1 and Left(kv, p - 1) = key then return Mid(kv, p + 1)
    end for
    return ""
end function

' seconds as "s.mmm" (Str() of a float can switch to exponent notation)
function vid_sec(v as dynamic) as string
    if v = invalid or v < 0 then v = 0
    ms& = Int(v * 1000 + 0.5)
    fr = (ms& mod 1000&).toStr()
    while Len(fr) < 3
        fr = "0" + fr
    end while
    return (ms& \ 1000&).toStr() + "." + fr
end function

function vid_plist_xml(inner as string) as string
    q = Chr(34)
    return "<?xml version=" + q + "1.0" + q + " encoding=" + q + "UTF-8" + q + "?>" + Chr(10) + "<!DOCTYPE plist PUBLIC " + q + "-//Apple//DTD PLIST 1.0//EN" + q + " " + q + "http://www.apple.com/DTDs/PropertyList-1.0.dtd" + q + ">" + Chr(10) + "<plist version=" + q + "1.0" + q + "><dict>" + inner + "</dict></plist>" + Chr(10)
end function

function vid_xml_escape(s as string) as string
    return s.Split("&").Join("&amp;").Split("<").Join("&lt;").Split(">").Join("&gt;")
end function

' POST /reverse: this connection becomes the receiver -> sender event channel.
sub vid_reverse(c as object, req as object)
    purpose = ""
    if req.headers.DoesExist("x-apple-purpose") then purpose = req.headers["x-apple-purpose"]
    dbg("  reverse connection (" + purpose + ")")
    if m.reverse <> invalid and m.handlers[m.reverse.id] <> invalid and m.reverse.id <> c.id then
        dbg("  replacing previous reverse connection")
        rx_close(m.reverse)
    end if
    h = req.proto + " 101 Switching Protocols" + CRLF() + "Upgrade: PTTH/1.0" + CRLF() + "Connection: Upgrade" + CRLF()
    if req.headers.DoesExist("cseq") then h = h + "CSeq: " + req.headers["cseq"] + CRLF()
    sock_send_all(c.sock, ba_ascii(h + CRLF()))
    c.reverse = true
    m.reverse = c
end sub

sub vid_server_info(c as object, req as object)
    cfg = m.cfg
    feat& = m.features& mod 4294967296&
    inner = "<key>deviceid</key><string>" + cfg.deviceId + "</string>"
    inner = inner + "<key>features</key><integer>" + feat&.toStr() + "</integer>"
    inner = inner + "<key>macAddress</key><string>" + cfg.deviceId + "</string>"
    inner = inner + "<key>model</key><string>AppleTV3,2</string>"
    inner = inner + "<key>osBuildVersion</key><string>12B435</string>"
    inner = inner + "<key>protovers</key><string>1.0</string>"
    inner = inner + "<key>srcvers</key><string>220.68</string>"
    inner = inner + "<key>vv</key><integer>2</integer>"
    rtsp_reply(c, req, 200, {}, "text/x-apple-plist+xml", ba_ascii(vid_plist_xml(inner)))
end sub

' Guess the Roku streamFormat from the URL (the sender doesn't say).
function vid_format(url as string) as string
    u = LCase(url.Split("?")[0])
    if Instr(1, u, ".m3u8") > 0 or Instr(1, LCase(url), "m3u8") > 0 then return "hls"
    if Right(u, 4) = ".mpd" then return "dash"
    if Right(u, 4) = ".mkv" then return "mkv"
    if Right(u, 3) = ".ts" then return "ts"
    if Right(u, 4) = ".mp3" then return "mp3"
    return "mp4"
end function

' POST /play: {Content-Location, Start-Position-Seconds | Start-Position, uuid, ...}
sub vid_play(c as object, req as object)
    ct = ""
    if req.headers.DoesExist("content-type") then ct = LCase(req.headers["content-type"])
    loc = ""
    startSec = 0
    startFrac = 0
    uuid = ""
    procName = ""
    if Instr(1, ct, "binary-plist") > 0 then
        p = plist_parse(req.body)
        if p <> invalid and type(p) = "roAssociativeArray" then
            if type(p["Content-Location"]) = "String" or type(p["Content-Location"]) = "roString" then loc = p["Content-Location"]
            v = p["Start-Position-Seconds"]
            if v <> invalid and vid_is_num(v) then startSec = v
            v = p["Start-Position"]
            if v <> invalid and vid_is_num(v) then startFrac = v
            if p["uuid"] <> invalid then uuid = lstr(p["uuid"])
            if p["clientProcName"] <> invalid then procName = lstr(p["clientProcName"])
        end if
    else
        ' older senders: text/parameters "Content-Location: ...\nStart-Position: 0.0"
        for each ln in req.body.ToAsciiString().Split(Chr(10))
            k = Instr(1, ln, ":")
            if k > 1 then
                key = LCase(Left(ln, k - 1).Trim())
                pv = Mid(ln, k + 1).Trim()
                if key = "content-location" then loc = pv
                if key = "start-position" then startFrac = Val(pv)
                if key = "start-position-seconds" then startSec = Val(pv)
            end if
        end for
    end if
    sid = ""
    if req.headers.DoesExist("x-apple-session-id") then sid = req.headers["x-apple-session-id"]
    dbg("  play " + loc + " start=" + vid_sec(startSec) + "s/" + lstr(startFrac) + " app=" + procName)
    lloc = LCase(loc)
    if Left(lloc, 7) <> "http://" and Left(lloc, 8) <> "https://" then
        dbg("  play: unsupported location (only http/https URLs are handled)")
        rtsp_reply(c, req, 400, {}, "", invalid)
        return
    end if
    ' the Video node is shared: URL playback replaces screen mirroring
    if m.vs <> invalid then mirror_stop()
    if startFrac > 0 and startFrac < 1 and startSec = 0 then
        ' fraction of the duration, applied by the scene once it is known
    else
        startFrac = 0
    end if
    m.gen = m.gen + 1
    m.url = {gen: m.gen, url: loc, uuid: uuid, sid: sid, app: procName, fmt: vid_format(loc), dur: 0, pos: startSec, state: "loading", started: false, ended: false, lastEvent: ""}
    m.top.videoCmd = {op: "play", url: loc, fmt: m.url.fmt, startSec: startSec, startFrac: startFrac, gen: m.gen}
    rx_status("playing video")
    if procName <> "" then m.top.client = procName
    vid_event("loading")
    rtsp_reply(c, req, 200, {}, "", invalid)
end sub

function vid_is_num(v as dynamic) as boolean
    t = type(v)
    return t = "Integer" or t = "roInteger" or t = "LongInteger" or t = "Float" or t = "roFloat" or t = "Double" or t = "roDouble"
end function

' End URL playback. fromPlayer: the player finished or failed by itself.
sub vid_stop(why as string, fromPlayer as boolean)
    if m.url = invalid then return
    dbg("video end: " + why)
    if fromPlayer then
        ' keep m.url (marked ended) so /playback-info can tell the sender
        m.url.ended = true
        vid_event("stopped")
        return
    end if
    m.top.videoCmd = {op: "stop"}
    m.url = invalid
    rx_status("ready")
    m.top.client = ""
end sub

' Player state from the scene (port event), while a URL is playing.
sub vid_on_player_state(st as string)
    u = m.url
    if u = invalid or u.ended then return
    if st = "buffering" then
        u.state = "loading"
        vid_event("loading")
    else if st = "playing" then
        u.started = true
        u.state = "playing"
        vid_event("playing")
    else if st = "paused" then
        u.state = "paused"
        vid_event("paused")
    else if st = "finished" then
        if u.started then vid_stop("finished", true)
    else if st = "error" then
        vid_stop("player error", true)
    else if st = "stopped" then
        if u.started then vid_stop("player stopped", true)
    end if
end sub

' Event to the sender over the reverse connection.
sub vid_event(state as string)
    u = m.url
    if u = invalid or u.lastEvent = state then return
    u.lastEvent = state
    rc = m.reverse
    if rc = invalid or m.handlers[rc.id] = invalid then return
    inner = "<key>category</key><string>video</string><key>state</key><string>" + state + "</string>"
    if u.uuid <> "" then inner = inner + "<key>uuid</key><string>" + vid_xml_escape(u.uuid) + "</string>"
    body = ba_ascii(vid_plist_xml(inner))
    h = "POST /event HTTP/1.1" + CRLF() + "Content-Type: text/x-apple-plist+xml" + CRLF() + "Content-Length: " + body.Count().toStr() + CRLF()
    if u.sid <> "" then h = h + "X-Apple-Session-ID: " + u.sid + CRLF()
    out = ba_ascii(h + CRLF())
    out.Append(body)
    sock_send_all(rc.sock, out)
    dbg("  event -> sender: " + state)
end sub

' GET /playback-info, polled by the sender about once a second.
sub vid_playback_info(c as object, req as object)
    u = m.url
    if u = invalid or u.ended then
        ' nothing playing (any more): an empty reply plus closing the
        ' connection is how UxPlay tells the sender playback is over
        rtsp_reply(c, req, 200, {}, "", invalid)
        if u <> invalid then
            m.url = invalid
            m.top.videoCmd = {op: "stop"}
            rx_status("ready")
            m.top.client = ""
            rx_close(c)
        end if
        return
    end if
    if u.dur <= 0 then
        ' not loaded yet
        rtsp_reply(c, req, 200, {}, "", invalid)
        return
    end if
    rate = "0.0"
    if u.state = "playing" then rate = "1.0"
    d = vid_sec(u.dur)
    p = vid_sec(u.pos)
    rest = vid_sec(u.dur - u.pos)
    ready = "0"
    if u.started then ready = "1"
    empty = "0"
    if u.state = "loading" then empty = "1"
    inner = "<key>duration</key><real>" + d + "</real>"
    inner = inner + "<key>position</key><real>" + p + "</real>"
    inner = inner + "<key>rate</key><real>" + rate + "</real>"
    inner = inner + "<key>readyToPlay</key><integer>" + ready + "</integer>"
    inner = inner + "<key>playbackBufferEmpty</key><integer>" + empty + "</integer>"
    inner = inner + "<key>playbackBufferFull</key><integer>0</integer>"
    inner = inner + "<key>playbackLikelyToKeepUp</key><integer>1</integer>"
    inner = inner + "<key>loadedTimeRanges</key><array><dict><key>duration</key><real>" + rest + "</real><key>start</key><real>" + p + "</real></dict></array>"
    inner = inner + "<key>seekableTimeRanges</key><array><dict><key>duration</key><real>" + d + "</real><key>start</key><real>0.0</real></dict></array>"
    rtsp_reply(c, req, 200, {}, "text/x-apple-plist+xml", ba_ascii(vid_plist_xml(inner)))
end sub

' POST /action: the sender's answers to FCUP requests (YouTube playlists) and
' playlist edits. Not implemented yet; logged so the flow can be seen.
sub vid_action(c as object, req as object)
    p = plist_parse(req.body)
    t = "?"
    if p <> invalid and type(p) = "roAssociativeArray" and p["type"] <> invalid then t = lstr(p["type"])
    dbg("  action type=" + t + " (not handled) " + pl_dump(p, 0))
    rtsp_reply(c, req, 200, {}, "", invalid)
end sub

' Compact text form of a parsed plist, for the log (long values cut).
function pl_dump(v as dynamic, depth as integer) as string
    if depth > 6 then return "..."
    t = type(v)
    if t = "roAssociativeArray" then
        parts = []
        for each k in v
            parts.push(k + ": " + pl_dump(v[k], depth + 1))
        end for
        return "{" + parts.Join(", ") + "}"
    else if t = "roArray" then
        parts = []
        for each x in v
            parts.push(pl_dump(x, depth + 1))
        end for
        return "[" + parts.Join(", ") + "]"
    else if t = "roByteArray" then
        if v.Count() <= 16 then return "<" + v.ToHexString() + ">"
        return "<data " + v.Count().toStr() + ">"
    else if t = "String" or t = "roString" then
        if Len(v) > 200 then return Chr(34) + Left(v, 200) + "..." + Chr(34)
        return Chr(34) + v + Chr(34)
    else if v = invalid then
        return "null"
    end if
    return lstr(v)
end function

' Request body as text for the log: bplist decoded, otherwise the start of it
function vid_body_dump(req as object) as string
    ct = ""
    if req.headers.DoesExist("content-type") then ct = req.headers["content-type"]
    if req.body.Count() = 0 then return "(no body)"
    p = plist_parse(req.body)
    if p <> invalid then return pl_dump(p, 0)
    s = req.body.ToAsciiString()
    if Len(s) > 300 then s = Left(s, 300) + "..."
    return ct + ": " + s
end function

' 32-bit value as 8 hex digits
function vid_hex32(v as longinteger) as string
    digits = "0123456789abcdef"
    s = ""
    for i = 1 to 8
        s = Mid(digits, (v mod 16&) + 1, 1) + s
        v = v \ 16&
    end for
    return s
end function
