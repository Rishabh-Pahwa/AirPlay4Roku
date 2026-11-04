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
    m.audio.observeField("state", "onAudioState")
    m.rx = CreateObject("roSGNode", "Receiver")
    m.rx.observeField("status", "onStatus")
    m.rx.observeField("info", "onInfo")
    m.rx.observeField("mirrorUrl", "onMirrorUrl")
    m.rx.observeField("audioUrl", "onAudioUrl")
    m.rx.observeField("volume", "onVolume")
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
        m.video.control = "stop"
        m.video.visible = false
        m.idle.visible = true
        return
    end if
    if m.global.noPlayer = true then return
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

sub onVideoState()
    m.rx.playerState = m.video.state
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
    return false
end function
