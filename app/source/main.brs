sub Main(args as dynamic)
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.setMessagePort(port)
    ' testmode=1 (ECP launch param) lets test/fake_sender.py supply a plaintext
    ' stream key, since FairPlay can't be emulated on the sending side.
    testMode = false
    if type(args) = "roAssociativeArray" and args.testmode = "1" then testMode = true
    hlsTarget = 0
    if testMode and args.hlstarget <> invalid then hlsTarget = Val(args.hlstarget, 10)
    noFeedback = testMode and args.nofeedback = "1"
    noPlayer = testMode and args.noplayer = "1"
    ' urlvideo=1 / urlvideo=0 (ECP launch param) switches AirPlay video-URL
    ' playback on/off; it is remembered in the registry (off by default).
    if type(args) = "roAssociativeArray" and args.urlvideo <> invalid then
        reg = CreateObject("roRegistrySection", "airplay")
        if args.urlvideo = "1" then reg.Write("urlvideo", "1") else reg.Delete("urlvideo")
        reg.Flush()
    end if
    screen.getGlobalNode().addFields({testMode: testMode, hlsTarget: hlsTarget, noFeedback: noFeedback, noPlayer: noPlayer})
    scene = screen.CreateScene("MainScene")
    screen.show()
    while true
        msg = wait(0, port)
        if type(msg) = "roSGScreenEvent" and msg.isScreenClosed() then return
    end while
end sub
