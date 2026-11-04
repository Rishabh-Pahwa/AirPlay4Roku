' BrightScript side of the playfair differential test (see run.sh).
' Needs app/source/fairplay.brs and a generated fp_test_vectors() returning lines
' "<op> <hex> [<hex>]"; prints "<op> <result hex>" in the same format as
' build/harness run, plus "TIME ..." lines.

function fpt_hex(s as string) as object
    b = CreateObject("roByteArray")
    b.FromHexString(s)
    return b
end function

function fpt_hexa(a as object) as string
    b = CreateObject("roByteArray")
    for each v in a
        b.push(v)
    end for
    return LCase(b.ToHexString())
end function

sub Main()
    ts = CreateObject("roTimespan")
    ts.Mark()
    t = fp_tables()
    print "TIME tables_ms="; ts.TotalMilliseconds()
    if t = invalid then
        print "FAIL tables"
        return
    end if
    total = 0
    nd = 0
    for each line in fp_test_vectors()
        f = line.Tokenize(" ")
        op = f[0]
        if op = "decrypt" then
            ts.Mark()
            r = FairPlay_Decrypt(fpt_hex(f[1]), fpt_hex(f[2]))
            ms = ts.TotalMilliseconds()
            total = total + ms
            nd = nd + 1
            print "decrypt "; LCase(r.ToHexString())
            if nd <= 3 then print "TIME decrypt_ms="; ms
        else if op = "setup" then
            req = fpt_hex(f[1])
            r = FairPlay_SetupReply(req)
            if r = invalid then
                if req[4] = 3 then print "setup undefined" else print "setup invalid"
            else
                print "setup "; LCase(r.ToHexString())
            end if
        else if op = "handshake" then
            r = FairPlay_HandshakeReply(fpt_hex(f[1]))
            if r = invalid then print "handshake invalid" else print "handshake "; LCase(r.ToHexString())
        else if op = "saphash" then
            print "saphash "; fpt_hexa(fp_sap_hash(t, fpt_hex(f[1]), 0))
        else if op = "md5" then
            k = fpt_hex(f[2])
            kw = []
            for i = 0 to 12 step 4
                kw.push(k[i] or (k[i + 1] << 8) or (k[i + 2] << 16) or (k[i + 3] << 24))
            end for
            o = []
            for each w in fp_md5(t, fpt_hex(f[1]), 0, kw)
                o.push(w and 255) : o.push((w >> 8) and 255) : o.push((w >> 16) and 255) : o.push((w >> 24) and 255)
            end for
            print "md5 "; fpt_hexa(o)
        else if op = "sessionkey" then
            print "sessionkey "; fpt_hexa(fp_session_key(t, fpt_hex(f[1])))
        end if
    end for
    if nd > 0 then print "TIME decrypt_avg_ms="; total \ nd; " n="; nd
end sub
