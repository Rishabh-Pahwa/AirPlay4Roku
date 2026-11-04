sub init()
    m.status = m.top.findNode("status")
    m.video = m.top.findNode("video")
    m.audio = m.top.findNode("audio")
    m.video.observeField("state", "onVideoState")
    m.audio.observeField("state", "onAudioState")
    m.clock = CreateObject("roTimespan")
    m.steps = [
        {p: "audio", url: "http://127.0.0.1:8888/v1_mine_escape.mka", fmt: "mka", d: 7, live: false},
        {p: "audio", url: "http://127.0.0.1:8888/v2_ff_escape.mka", fmt: "mka", d: 7, live: false},
        {p: "audio", url: "http://127.0.0.1:8888/v3_ff_alac4096.mka", fmt: "mka", d: 7, live: false},
        {p: "audio", url: "http://127.0.0.1:8888/v4_alac.m4a", fmt: "mp4", d: 7, live: false},
        {p: "audio", url: "http://127.0.0.1:8888/v5_escape.m4a", fmt: "mp4", d: 7, live: false}
    ]
    m.idx = -1
    m.task = CreateObject("roSGNode", "Spike2Task")
    m.task.observeField("serverReady", "onServerReady")
    m.task.control = "RUN"
    m.timer = CreateObject("roSGNode", "Timer")
    m.timer.observeField("fire", "nextStep")
end sub

sub onServerReady()
    nextStep()
end sub

sub nextStep()
    m.video.control = "stop"
    m.audio.control = "stop"
    m.idx = m.idx + 1
    if m.idx >= m.steps.count() then
        print "SPIKE: all steps done"
        m.status.text = "spike2 done"
        return
    end if
    s = m.steps[m.idx]
    print "SPIKE: step "; m.idx; " live="; s.live; " "; s.p; " "; s.fmt; " "; s.url
    m.status.text = "step " + m.idx.toStr() + " " + s.url
    c = CreateObject("roSGNode", "ContentNode")
    c.url = s.url
    c.streamFormat = s.fmt
    c.live = s.live
    m.clock.Mark()
    if s.p = "video" then
        m.video.content = c
        m.video.control = "play"
    else
        m.audio.content = c
        m.audio.control = "play"
    end if
    m.timer.duration = s.d
    m.timer.control = "start"
end sub

sub onVideoState()
    print "SPIKE: [step "; m.idx; " t="; m.clock.TotalMilliseconds(); "ms] video state="; m.video.state; " err="; m.video.errorCode; " "; m.video.errorMsg
end sub

sub onAudioState()
    print "SPIKE: [step "; m.idx; " t="; m.clock.TotalMilliseconds(); "ms] audio state="; m.audio.state; " err="; m.audio.errorCode; " "; m.audio.errorMsg
end sub
