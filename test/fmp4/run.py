#!/usr/bin/env python3
"""app/source/fmp4.brs must produce byte-identical output to test/fmp4_proto.py."""
import os, sys, subprocess, shutil, tempfile, secrets
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "test"))
import fmp4_proto as fp
NODE = os.path.expanduser("~/.nvm/versions/node/v22.23.3/bin/node")
BRS = os.path.join(ROOT, "tools/node/node_modules/brs-node/bin/brs.cli.js")
avcc = bytes.fromhex("01640028ffe1001b67640028acd940500bfc") + secrets.token_bytes(20)
samples = [(3000 + i, i == 0, secrets.token_bytes(50 + i * 7)) for i in range(15)]
base = 5 * 2**32 + 123456
want_init = fp.init_segment(332, 720, avcc)
want_seg = fp.media_segment(7, base, samples)
brs = 'sub Main()\n'
brs += f'    print "INIT "; LCase(mp4_init(332, 720, ba_hex("{avcc.hex()}")).ToHexString())\n'
brs += '    s = []\n'
for d, k, b in samples:
    brs += f'    s.push({{dur: {d}, key: {"true" if k else "false"}, data: ba_hex("{b.hex()}")}})\n'
brs += f'    print "SEG "; LCase(mp4_segment(7, {base}&, s).ToHexString())\nend sub\n'
tmp = tempfile.mkdtemp(dir=os.path.join(ROOT, "test"))
os.makedirs(tmp + "/source")
for f in ("util.brs", "mkv.brs", "fmp4.brs"):
    shutil.copy(os.path.join(ROOT, "app/source", f), tmp + "/source/")
open(tmp + "/source/t.brs", "w").write(brs)
r = subprocess.run([NODE, BRS, "--root", tmp, "source/t.brs", "source/util.brs", "source/mkv.brs", "source/fmp4.brs"], capture_output=True, text=True, cwd=tmp)
shutil.rmtree(tmp)
got = {l.split()[0]: bytes.fromhex(l.split()[1]) for l in r.stdout.splitlines() if l.startswith(("INIT ", "SEG "))}
ok = got.get("INIT") == want_init and got.get("SEG") == want_seg
print("init match:", got.get("INIT") == want_init, "segment match:", got.get("SEG") == want_seg)
if not ok:
    print(r.stdout[-500:], r.stderr[-500:])
print("RESULT", "PASS" if ok else "FAIL")
