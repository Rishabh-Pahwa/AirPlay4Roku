
function hx(s as string) as object
    b = CreateObject("roByteArray")
    b.FromHexString(s)
    return b
end function

sub Main()
    ts = CreateObject("roTimespan")
    fails = 0
    for each v in [["a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4", "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c", "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552"], ["17d7fa160dcc9ee19b60f9dba6d6f3d1490fa431c91a968a6348b29e0f829da1", "14aab8d79d0b0d54b54c425aed4df360275cc75f9bf476c00f952649f3a25e7e", "31a4e02685bdb6c531861090e4e98c59f9c5487a4c54d6a1e42a6986eed3bf45"], ["3051d777c7e828295c025e2adf8dfe9c7391d859fe342cf403e8d4a0f26bb728", "129e3c7cb8fb9457506f94061f00c757e2302ea6ece3e1dbaba97eb4a3622147", "fd50f644fbe62b1f27a72373df1841297e76ffb990a704215450382822113c39"]]
        ts.Mark()
        r = LCase(x25519(hx(v[0]), hx(v[1])).ToHexString())
        print "X25519 "; r = v[2]; " ms="; ts.TotalMilliseconds()
        if r <> v[2] then fails = fails + 1
    end for
    for each v in [["17d7fa160dcc9ee19b60f9dba6d6f3d1490fa431c91a968a6348b29e0f829da1", "bf368181a614e13470916b45dc969edd2e1852a97403e8e642d351c8d06e773e"], ["3051d777c7e828295c025e2adf8dfe9c7391d859fe342cf403e8d4a0f26bb728", "93433c88c890677423cf94575b7b47c9607b89d4d797add2ad6f4a4715ec7e7c"]]
        ts.Mark()
        r = LCase(x25519_public(hx(v[0])).ToHexString())
        print "X25519PUB "; r = v[1]; " ms="; ts.TotalMilliseconds()
        if r <> v[1] then fails = fails + 1
    end for
    for each v in [["07c5f2907b535cf9aa73fb9d9ed61793dfab99263e8f5ad34dc392b1d0cade61", "21f4397ae1295bdd31e51c3be9e111b4da674c666663cf532645fe2a5ca5a510", "39f29ea8464972c468f87701d211f85fa1e497debb0d362083a4036ef1c012180b5a298ab764b23b4d621f762d2700505114dbf3b6914037e8b5e6b3f9f455a8"], ["1cbf7a82647e9259f8801d9314817b7f57844c609251b9986fbeb052cb489759", "ec0a684af4d29ac31138b3beef4b4ae3659a21335603aecd1e76513050e572c1", "b1d009d580f860a053b88eeb84173720d974136dcced5cadb78e7001ef230b9e191c4e3e5dafe78bb01c1c3745252f3d8ae1839b5b6f724cf59260f1ec01eccb"]]
        ts.Mark()
        key = ed25519_keypair(hx(v[0]))
        okpub = (LCase(key.pub.ToHexString()) = v[1])
        t1 = ts.TotalMilliseconds()
        ts.Mark()
        nonce = ed25519_nonce()
        t2 = ts.TotalMilliseconds()
        ts.Mark()
        sig = ed25519_sign(key, nonce, hx(v[2]))
        print "ED25519PUB "; okpub; " ms="; t1; " nonce_ms="; t2; " sign_ms="; ts.TotalMilliseconds()
        print "SIG "; v[1]; " "; v[2]; " "; LCase(sig.ToHexString())
        if not okpub then fails = fails + 1
    end for
    print "BRS_FAILS "; fails
end sub
