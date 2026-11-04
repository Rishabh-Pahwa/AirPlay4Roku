#!/usr/bin/env python3
"""Differential test of app/source/plist.brs against Python's plistlib."""
import os, plistlib, subprocess, shutil, tempfile, sys
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
NODE = os.path.expanduser("~/.nvm/versions/node/v22.23.3/bin/node")
BRS = os.path.join(ROOT, "tools/node/node_modules/brs-node/bin/brs.cli.js")
sample = {"streams": [{"type": 110, "streamConnectionID": 12345678901234567890 - 2**64, "timestampInfo": [{"name": "SubSu"}]},
                      {"type": 96, "ct": 2, "spf": 352, "audioFormat": 0x40000, "controlPort": 50001}],
          "ekey": bytes(range(72)), "eiv": bytes(range(16, 32)), "timingPort": 62345, "isScreenMirroringSession": True,
          "deviceID": "AA:BB:CC:DD:EE:FF", "latencyMs": 90, "osBuildVersion": "21A350", "big": 2**40, "neg": -5,
          "rate": 0.5, "rf": 1.0 / 60.0, "qualifier": ["txtAirPlay"], "f": False,
          "longname": "x" * 40, "longdata": bytes(300)}
inp = plistlib.dumps(sample, fmt=plistlib.FMT_BINARY)
test = '''
function dump(v as dynamic) as string
    t = type(v)
    if t = "roAssociativeArray" then
        ks = []
        for each k in v
            ks.push(k)
        end for
        ks.Sort()
        s = "{"
        for each k in ks
            s = s + LCase(k) + ":" + dump(v[k]) + ","
        end for
        return s + "}"
    else if t = "roArray" then
        s = "["
        for each x in v
            s = s + dump(x) + ","
        end for
        return s + "]"
    else if t = "roByteArray" then
        return "<" + LCase(v.ToHexString()) + ">"
    else if t = "Double" or t = "roDouble" or t = "Float" or t = "roFloat" then
        return "R" + Str(v).Trim()
    end if
    return lstr(v)
end function

sub Main()
    b = CreateObject("roByteArray")
    b.FromHexString("%s")
    print "PARSED "; dump(plist_parse(b))
    d = pl_dict()
    pl_set(d, "deviceID", "AA:BB:CC:DD:EE:FF")
    pl_set(d, "features", 1518337766&)
    pl_set(d, "big", 6442450941&)
    pl_set(d, "vv", 2)
    pl_set(d, "keepAliveLowPower", true)
    pl_set(d, "pk", ba_hex("00112233"))
    pl_set(d, "refreshRate", pl_real_hex("3F91111111111111"))
    inner = pl_dict()
    pl_set(inner, "type", 110)
    pl_set(inner, "dataPort", 7100)
    pl_set(d, "streams", pl_array([inner, 300, "s"]))
    print "BUILT "; LCase(plist_build(d).ToHexString())
end sub
''' % inp.hex()
def pyd(v):
    if isinstance(v, dict): return "{" + "".join(f"{k.lower()}:{pyd(v[k])}," for k in sorted(v, key=str.lower)) + "}"
    if isinstance(v, list): return "[" + "".join(pyd(x) + "," for x in v) + "]"
    if isinstance(v, bytes): return "<" + v.hex() + ">"
    if isinstance(v, bool): return "true" if v else "false"
    if isinstance(v, float): return "R" + repr(v)
    return str(v)
tmp = tempfile.mkdtemp(dir=os.path.join(ROOT, "test"))
os.makedirs(tmp + "/source")
for f in ("util.brs", "plist.brs"): shutil.copy(os.path.join(ROOT, "app/source", f), tmp + "/source/")
open(tmp + "/source/t.brs", "w").write(test)
r = subprocess.run([NODE, BRS, "--root", tmp, "source/t.brs", "source/util.brs", "source/plist.brs"], capture_output=True, text=True, cwd=tmp)
shutil.rmtree(tmp)
out = r.stdout + r.stderr
ok = True
for line in out.splitlines():
    if line.startswith("PARSED "):
        got = line[7:].strip(); want = pyd(sample)
        print("parse match:", got == want)
        if got != want:
            ok = False
            i = next((i for i, (a, b) in enumerate(zip(got, want)) if a != b), min(len(got), len(want)))
            print(" diff at", i, "got:", got[max(0, i - 60):i + 60]); print("                want:", want[max(0, i - 60):i + 60])
    elif line.startswith("BUILT "):
        d = plistlib.loads(bytes.fromhex(line[6:].strip()))
        print("built ->", d)
        exp = {"deviceID": "AA:BB:CC:DD:EE:FF", "features": 1518337766, "big": 6442450941, "vv": 2, "keepAliveLowPower": True,
               "pk": bytes.fromhex("00112233"), "refreshRate": 1/60, "streams": [{"type": 110, "dataPort": 7100}, 300, "s"]}
        ok = ok and d == exp
        print("build match:", d == exp)
    elif "rror" in line:
        print(line); ok = False
print("RESULT", "PASS" if ok else "FAIL")
