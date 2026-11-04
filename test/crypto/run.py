#!/usr/bin/env python3
"""Differential test of app/source/curve25519.brs against pyca/cryptography.

Usage: test/crypto/run.py [n_random]   (runs in the local brs interpreter)
Also writes test/crypto/device_test.brs, a self-checking version for the Roku.
"""
import os, subprocess, sys, secrets
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives import serialization as ser

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
NODE = os.path.expanduser("~/.nvm/versions/node/v22.23.3/bin/node")
BRS = os.path.join(ROOT, "tools/node/node_modules/brs-node/bin/brs.cli.js")
raw = dict(encoding=ser.Encoding.Raw, format=ser.PublicFormat.Raw)
n = int(sys.argv[1]) if len(sys.argv) > 1 else 3

xv = [("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4",
       "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c",
       "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")]
pubv = []
edv = []
for _ in range(n):
    a, b = secrets.token_bytes(32), X25519PrivateKey.generate()
    pa = X25519PrivateKey.from_private_bytes(a)
    shared = pa.exchange(b.public_key())
    xv.append((a.hex(), b.public_key().public_bytes(**raw).hex(), shared.hex()))
    pubv.append((a.hex(), pa.public_key().public_bytes(**raw).hex()))
    seed = secrets.token_bytes(32)
    edv.append((seed.hex(), Ed25519PrivateKey.from_private_bytes(seed).public_key().public_bytes(**raw).hex(),
                secrets.token_bytes(64).hex()))

def brs_list(rows):
    return "[" + ", ".join("[" + ", ".join('"%s"' % c for c in r) + "]" for r in rows) + "]"

test = f'''
function hx(s as string) as object
    b = CreateObject("roByteArray")
    b.FromHexString(s)
    return b
end function

sub Main()
    ts = CreateObject("roTimespan")
    fails = 0
    for each v in {brs_list(xv)}
        ts.Mark()
        r = LCase(x25519(hx(v[0]), hx(v[1])).ToHexString())
        print "X25519 "; r = v[2]; " ms="; ts.TotalMilliseconds()
        if r <> v[2] then fails = fails + 1
    end for
    for each v in {brs_list(pubv)}
        ts.Mark()
        r = LCase(x25519_public(hx(v[0])).ToHexString())
        print "X25519PUB "; r = v[1]; " ms="; ts.TotalMilliseconds()
        if r <> v[1] then fails = fails + 1
    end for
    for each v in {brs_list(edv)}
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
'''
open(os.path.join(ROOT, "test/crypto/test_main.brs"), "w").write(test)

if os.environ.get("NO_RUN"):
    sys.exit(0)
import shutil, tempfile
tmp = tempfile.mkdtemp(prefix="brs-crypto-", dir=os.path.join(ROOT, "test"))
os.makedirs(os.path.join(tmp, "source"))
for f in ("fe25519.brs", "curve25519.brs"):
    shutil.copy(os.path.join(ROOT, "app/source", f), os.path.join(tmp, "source", f))
shutil.copy(os.path.join(ROOT, "test/crypto/test_main.brs"), os.path.join(tmp, "source", "test_main.brs"))
shutil.copytree(os.path.join(ROOT, "app/assets"), os.path.join(tmp, "assets"))
r = subprocess.run([NODE, BRS, "--root", tmp, "source/test_main.brs", "source/fe25519.brs", "source/curve25519.brs"],
                   capture_output=True, text=True, timeout=1800, cwd=tmp)
out = r.stdout + r.stderr
shutil.rmtree(tmp)
bad = 0
for line in out.splitlines():
    line = line.strip()
    if line.startswith(("X25519", "ED25519PUB", "BRS_FAILS")):
        print(line)
        if "false" in line.split()[1:2]:
            bad += 1
    elif line.startswith("SIG "):
        _, pub, msg, sig = line.split()
        try:
            Ed25519PublicKey.from_public_bytes(bytes.fromhex(pub)).verify(bytes.fromhex(sig), bytes.fromhex(msg))
            print("SIG verify OK")
        except Exception as e:
            print("SIG verify FAILED", e); bad += 1
    elif "rror" in line:
        print(line); bad += 1
print("RESULT", "PASS" if bad == 0 and "BRS_FAILS  0" in out.replace("BRS_FAILS 0", "BRS_FAILS  0") else "FAIL")
