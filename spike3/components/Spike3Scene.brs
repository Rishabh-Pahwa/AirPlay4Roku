sub init()
    m.video = m.top.findNode("video")
    m.audio = m.top.findNode("audio")
    m.video.notificationInterval = 0.5
    m.video.observeField("state", "onState")
    m.clock = CreateObject("roTimespan")
    dumpFields("Video", m.video)
    dumpFields("Audio", m.audio)
    dumpFields("ContentNode", CreateObject("roSGNode", "ContentNode"))
    m.steps = [
        {name: "c15", url: "http://127.0.0.1:8888/hls/c15/live.m3u8", fmt: "hls", delay: 1.1},
        {name: "c10", url: "http://127.0.0.1:8888/hls/c10/live.m3u8", fmt: "hls", delay: 1.1},
        {name: "q10", url: "http://127.0.0.1:8888/hls/q10/live.m3u8", fmt: "hls", delay: 0.6}
    ]
    m.idx = -1
    m.task = CreateObject("roSGNode", "Spike3Task")
    m.task.observeField("ready", "nextStep")
    m.task.control = "RUN"
    m.timer = CreateObject("roSGNode", "Timer")
    m.timer.duration = 36
    m.timer.observeField("fire", "nextStep")
    m.tick = CreateObject("roSGNode", "Timer")
    m.tick.duration = 1
    m.tick.repeat = true
    m.tick.observeField("fire", "onTick")
end sub

sub dumpFields(label as string, node as object)
    keys = []
    for each k in node.getFields()
        keys.push(k)
    end for
    keys.Sort()
    print "SPIKE: fields "; label; ": "; keys.Join(",")
end sub

sub nextStep()
    m.video.control = "stop"
    m.idx = m.idx + 1
    if m.idx >= m.steps.count() then
        m.tick.control = "stop"
        print "SPIKE: all steps done"
        return
    end if
    s = m.steps[m.idx]
    m.task.step = s.name
    c = CreateObject("roSGNode", "ContentNode")
    c.url = s.url
    c.streamFormat = s.fmt
    c.live = true
    m.video.content = c
    m.clock.Mark()
    print "SPIKE: === step "; s.name
    if s.delay > 0 then
        m.pending = true
        m.startTimer = CreateObject("roSGNode", "Timer")
        m.startTimer.duration = s.delay
        m.startTimer.observeField("fire", "doPlay")
        m.startTimer.control = "start"
    else
        m.video.control = "play"
    end if
    m.timer.control = "start"
    m.tick.control = "start"
end sub

sub onState()
    print "SPIKE: [" ; stepName(); " t="; m.clock.TotalMilliseconds(); "] state="; m.video.state; " "; m.video.errorMsg
end sub

sub onTick()
    vpos = Int(m.video.position * 1000)
    rel = m.task.releasedMs
    print "SPIKE: [" ; stepName(); " t="; m.clock.TotalMilliseconds(); "] "; m.video.state; " pos_ms="; vpos; " released_ms="; rel; " DEPTH_ms="; rel - vpos
end sub

function stepName() as string
    if m.idx < 0 or m.idx >= m.steps.count() then return "-"
    return m.steps[m.idx].name
end function

sub doPlay()
    print "SPIKE:   player start t="; m.clock.TotalMilliseconds()
    m.video.control = "play"
end sub
