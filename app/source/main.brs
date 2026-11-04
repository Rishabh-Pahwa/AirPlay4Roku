sub Main(args as dynamic)
    screen = CreateObject("roSGScreen")
    port = CreateObject("roMessagePort")
    screen.setMessagePort(port)
    ' testmode=1 (ECP launch param) lets test/fake_sender.py supply a plaintext
    ' stream key, since FairPlay can't be emulated on the sending side.
    testMode = false
    if type(args) = "roAssociativeArray" and args.testmode = "1" then testMode = true
    screen.getGlobalNode().addFields({testMode: testMode})
    scene = screen.CreateScene("MainScene")
    screen.show()
    while true
        msg = wait(0, port)
        if type(msg) = "roSGScreenEvent" and msg.isScreenClosed() then return
    end while
end sub
