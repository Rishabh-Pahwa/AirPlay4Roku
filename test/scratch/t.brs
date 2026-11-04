sub main()
  a& = 2147483647&
  b& = a& * 3&
  print "long mul "; b&
  x% = &HFFFFFFFF
  print "int -1 >> 28 = "; (x% >> 28)
  print "int ovf "; (2147483647 + 1)
  ba = createObject("roByteArray") : ba.fromHexString("00ff10")
  print ba.toBase64String(), ba[1]
  d = createObject("roEVPDigest") : d.setup("sha512") : print d.process(ba)
  c = createObject("roEVPCipher")
  print c
end sub
