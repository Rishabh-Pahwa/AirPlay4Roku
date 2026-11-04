function hx(s as string) as object
 b = CreateObject("roByteArray")
 b.FromHexString(s)
 return b
end function
sub Main()
 r = LCase(sc_reduce64(hx("48f26d0b801632ea43201e8db2a91596e58fd438c813a6d69ac3c314ed6ab7f75135596dc49f8167d6e144d4ac21d0b6cc3e7a09a7926d0e7c9e3a7b2ffda5ca")).ToHexString())
 print "red "; r = "3d221facd5b29945393323d1e56a2db4e3c685c55dd6c274339f6babfb412000"; " "; r; " want 3d221facd5b29945393323d1e56a2db4e3c685c55dd6c274339f6babfb412000"
 r = LCase(sc_reduce64(hx("f6ff68e8af1b48851fe69a3315ab8fdcb32e0390600582824b26d0f6099341ae5be902e743699e113d9bfd8bfbccdc386e0884fec55713633c4da8f254266646")).ToHexString())
 print "red "; r = "8a51ba8ff3786a88a2075735104f209ba3e2b9283671d8ef18994d377b38970f"; " "; r; " want 8a51ba8ff3786a88a2075735104f209ba3e2b9283671d8ef18994d377b38970f"
 r = LCase(sc_reduce64(hx("7fc1d72a454f2b737cc9c8d50d078dcf3ce5792a0db5240b204bf49709bb119aa25a575211ee509fdffc59d1eb659cbba57fd7bfd1227599b2da462910c01c1d")).ToHexString())
 print "red "; r = "75885524b673081ce1f797ceee4c5a4c46ad0b9d7af1a1d5e1593e320df6a001"; " "; r; " want 75885524b673081ce1f797ceee4c5a4c46ad0b9d7af1a1d5e1593e320df6a001"
 r = LCase(sc_reduce64(hx("57e5064829f9653bff7abc158d24d9eadbdd62c5609b381be2c0a87e3c87b6a9f397ae5620889c890ba5f943d9da738bac6ff48c107caa6a3276ecda34afd26c")).ToHexString())
 print "red "; r = "df6c113d2d0ccafb7252d89e492613f534f467f2256e64fe2b09ecf2d9b81102"; " "; r; " want df6c113d2d0ccafb7252d89e492613f534f467f2256e64fe2b09ecf2d9b81102"
 r = LCase(sc_muladd(hx("df90a0132a412bcdbcd45aa27e53e04cfd916fdffb15a963c78e431171d97179"),hx("c8aa9fd583a2f35f5bab12b9120ea283b32ce7140fe167cf3bd8394e0c79c6e6"),hx("716cf2da62f403380ce2b3b8c193d5a9d09de74c2386683ad79d239f4c3d1daf")).ToHexString())
 print "ma "; r = "090bab528a5a51cac91c8ab89adc97ec87501b8a32c31d97e8aee2be7691ce09"; " "; r; " want 090bab528a5a51cac91c8ab89adc97ec87501b8a32c31d97e8aee2be7691ce09"
 r = LCase(sc_muladd(hx("b9ca35133eecaa34bf0568dfe7e4ad6e9cf3913f9f8444ebde1ddae93a294796"),hx("14938b45a670e3f39705e3c4b540042bc0846454792b24faafc42fda825f3f7f"),hx("f60f556a0825bffeed004e69bbdc886275dbad60e7750040090410bda2a681a1")).ToHexString())
 print "ma "; r = "bc79cac145c7f717d81539b414174b37c8ed3649280694ceba852b81c258f70a"; " "; r; " want bc79cac145c7f717d81539b414174b37c8ed3649280694ceba852b81c258f70a"
 r = LCase(sc_muladd(hx("d8111c3939f5cb9e370e84210a2887673e4ac5c6dfeef8bc19af39a58a89f759"),hx("1f114060f2404ce4a4b04b9b97c9be2d8f2a42545fbc353697b1220a7ee16db1"),hx("0181c298dd3edcd6c98db9494984e832d8da0ca800e5ef63897ec0fdac3b2ca5")).ToHexString())
 print "ma "; r = "cfe9a6a45c58adcacd8498feb77c70445961c6c2f14ce8a3b16820c3b6623e0b"; " "; r; " want cfe9a6a45c58adcacd8498feb77c70445961c6c2f14ce8a3b16820c3b6623e0b"
end sub
