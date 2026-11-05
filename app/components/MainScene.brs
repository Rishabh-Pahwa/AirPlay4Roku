sub init()
    m.video = m.top.findNode("video")
    m.audio = m.top.findNode("audio")
    m.idle = m.top.findNode("idle")
    m.statusLabel = m.top.findNode("status")
    m.nameLabel = m.top.findNode("name")
    m.netLabel = m.top.findNode("net")
    m.audioLabel = m.top.findNode("audioLabel")
    m.video.observeField("state", "onVideoState")
    m.video.notificationInterval = 0.1
    m.video.observeField("position", "onVideoPosition")
    m.video.observeField("duration", "onVideoDuration")
    m.mode = ""          ' "mirror" or "url": who owns the Video node
    m.startFrac = 0
    m.audio.observeField("state", "onAudioState")
    m.rx = CreateObject("roSGNode", "Receiver")
    m.rx.observeField("status", "onStatus")
    m.rx.observeField("info", "onInfo")
    m.rx.observeField("mirrorUrl", "onMirrorUrl")
    m.rx.observeField("audioUrl", "onAudioUrl")
    m.rx.observeField("volume", "onVolume")
    m.rx.observeField("videoCmd", "onVideoCmd")
    m.rx.control = "RUN"
    m.top.setFocus(true)
end sub

sub onInfo()
    i = m.rx.info
    m.nameLabel.text = "Name on your devices:  " + i.name
    m.netLabel.text = "IP " + i.ip + "   ID " + i.deviceId
end sub

sub onStatus()
    m.statusLabel.text = m.rx.status
end sub

sub onMirrorUrl()
    url = m.rx.mirrorUrl
    if url = "" then
        ' a URL video may have replaced the mirror on the Video node
        if m.mode = "mirror" then videoOff()
        return
    end if
    if m.global.noPlayer = true then return
    m.mode = "mirror"
    m.video.enableUI = false
    m.top.setFocus(true)
    c = CreateObject("roSGNode", "ContentNode")
    c.url = url
    c.streamFormat = "hls"
    c.live = true
    m.video.content = c
    m.video.visible = true
    m.idle.visible = false
    m.video.control = "play"
end sub

sub onAudioUrl()
    url = m.rx.audioUrl
    if url = "" then
        m.audio.control = "stop"
        m.audioLabel.visible = false
        return
    end if
    c = CreateObject("roSGNode", "ContentNode")
    c.url = url
    c.streamFormat = "mka"
    c.live = true
    m.audio.content = c
    m.audio.control = "play"
    m.audioLabel.visible = not m.video.visible
end sub

sub videoOff()
    m.video.control = "stop"
    m.video.visible = false
    m.idle.visible = true
    m.mode = ""
end sub

' AirPlay video-URL playback commands from the receiver (source/video.brs)
sub onVideoCmd()
    cmd = m.rx.videoCmd
    if cmd = invalid or cmd.op = invalid then return
    op = cmd.op
    if op = "play" then
        m.mode = "url"
        c = CreateObject("roSGNode", "ContentNode")
        c.url = cmd.url
        c.streamFormat = cmd.fmt
        c.HttpCertificatesFile = "common:/certs/ca-bundle.crt"
        if cmd.startSec > 0 then c.PlayStart = cmd.startSec
        m.startFrac = cmd.startFrac
        m.rx.playerDuration = 0
        m.video.enableUI = true
        m.video.content = c
        m.video.visible = true
        m.idle.visible = false
        m.video.setFocus(true)
        m.video.control = "play"
    else if m.mode <> "url" then
        return
    else if op = "pause" then
        m.video.control = "pause"
    else if op = "resume" then
        m.video.control = "resume"
    else if op = "seek" then
        m.video.seek = cmd.pos
    else if op = "stop" then
        videoOff()
        m.top.setFocus(true)
    end if
end sub

sub onVideoDuration()
    m.rx.playerDuration = m.video.duration
    if m.mode = "url" and m.startFrac > 0 and m.video.duration > 0 then
        m.video.seek = m.startFrac * m.video.duration
        m.startFrac = 0
    end if
end sub

sub onVideoState()
    st = m.video.state
    m.rx.playerState = st
    if m.mode = "url" then
        if st = "error" then
            m.rx.playerNote = "error " + m.video.errorCode.toStr() + ": " + m.video.errorMsg
        else if st = "playing" then
            ' the duration observer doesn't fire if it equals the last video's
            if m.video.duration > 0 then m.rx.playerDuration = m.video.duration
            n = 0
            if m.video.availableAudioTracks <> invalid then n = m.video.availableAudioTracks.Count()
            m.rx.playerNote = "playing, duration " + m.video.duration.toStr() + " s, audio tracks " + n.toStr()
        end if
    end if
end sub

sub onVideoPosition()
    m.rx.playerPos = m.video.position
end sub

' AirPlay volume is -30..0 dB (-144 = mute). The Roku Audio node only offers
' mute, so the bottom of the slider (or mute) silences playback.
sub onVolume()
    v = m.rx.volume
    m.audio.mute = (v <= -29.9)
end sub

sub onAudioState()
end sub

function onKeyEvent(key as string, press as boolean) as boolean
    ' Back during a URL video stops it (the receiver tells the sender via the
    ' player's "stopped" state) instead of exiting the channel
    if press and key = "back" and m.mode = "url" then
        videoOff()
        m.top.setFocus(true)
        return true
    end if
    return false
end function
