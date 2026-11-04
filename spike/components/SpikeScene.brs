sub init()
    m.status = m.top.findNode("status")
    m.video = m.top.findNode("video")
    m.audio = m.top.findNode("audio")
    m.video.observeField("state", "onVideoState")
    m.audio.observeField("state", "onAudioState")
    m.task = CreateObject("roSGNode", "SpikeTask")
    m.task.observeField("serverReady", "onServerReady")
    m.task.observeField("statusText", "onStatus")
    m.task.control = "RUN"
    m.step = 0
    m.timer = CreateObject("roSGNode", "Timer")
    m.timer.duration = 12
    m.timer.observeField("fire", "onTimer")
end sub

sub onStatus()
    m.status.text = m.task.statusText
end sub

sub onServerReady()
    print "SPIKE: scene starting local HLS playback"
    c = CreateObject("roSGNode", "ContentNode")
    c.url = "http://127.0.0.1:8888/test.m3u8"
    c.streamFormat = "hls"
    m.video.content = c
    m.video.control = "play"
    m.timer.control = "start"
end sub

sub onVideoState()
    print "SPIKE: video state="; m.video.state; " err="; m.video.errorCode; " "; m.video.errorMsg
end sub

sub onAudioState()
    print "SPIKE: audio step="; m.step; " state="; m.audio.state; " err="; m.audio.errorCode; " "; m.audio.errorMsg
end sub

sub onTimer()
    m.step = m.step + 1
    m.video.control = "stop"
    c = CreateObject("roSGNode", "ContentNode")
    if m.step = 1 then
        print "SPIKE: audio test ALAC via http"
        c.url = "http://127.0.0.1:8888/alac.m4a"
        c.streamFormat = "mp4"
    else if m.step = 2 then
        print "SPIKE: audio test WAV via http"
        c.url = "http://127.0.0.1:8888/pcm.wav"
        c.streamFormat = "wav"
    else if m.step = 3 then
        print "SPIKE: audio test ALAC via pkg:"
        c.url = "pkg:/media/alac.m4a"
        c.streamFormat = "mp4"
    else if m.step = 4 then
        print "SPIKE: video test TS (non-HLS) via http"
        c.url = "http://127.0.0.1:8888/seg0.ts"
        c.streamFormat = "ts"
        m.audio.control = "stop"
        m.video.content = c
        m.video.control = "play"
        m.timer.control = "start"
        return
    else
        print "SPIKE: all media tests done"
        return
    end if
    m.audio.content = c
    m.audio.control = "play"
    m.timer.duration = 6
    m.timer.control = "start"
end sub
