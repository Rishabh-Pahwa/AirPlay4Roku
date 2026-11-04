#!/usr/bin/env python3
"""app/source/h264.brs must match test/h264/h264tool.py byte for byte."""
import os, sys, subprocess, shutil, tempfile, random, struct
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import h264tool as ht
NODE = os.path.expanduser("~/.nvm/versions/node/v22.23.3/bin/node")
BRS = os.path.join(ROOT, "tools/node/node_modules/brs-node/bin/brs.cli.js")

IOS_AVCC = "0164001effe100112764001eac1314505416fbe6e021a0204001000428ee3cb002000000"
ios = os.path.join(HERE, "build", "ios_like.h264")
if not os.path.exists(ios):
    ht.selftest()
nals = ht.split_annexb(open(ios, "rb").read())
sps_nal = next(n for n in nals if n[0] & 31 == 7)
pps_nal = next(n for n in nals if n[0] & 31 == 8)
conv_avcc = bytes([1, sps_nal[1], sps_nal[2], sps_nal[3], 0xFF, 0xE1]) + struct.pack(">H", len(sps_nal)) + sps_nal + b"\x01" + struct.pack(">H", len(pps_nal)) + pps_nal
frames = ht.frames_of(nals)

def avcc_frame(fr):
    return b"".join(struct.pack(">I", len(n)) + n for n in fr if n[0] & 31 in (1, 5, 6))

def params(avcc_hex):
    b = bytes.fromhex(avcc_hex)
    o = 6; l = int.from_bytes(b[o:o + 2], "big"); sps = ht.parse_sps(b[o + 2:o + 2 + l]); o += 2 + l + 1
    l = int.from_bytes(b[o:o + 2], "big"); pps = ht.parse_pps(b[o + 2:o + 2 + l])
    return sps, pps

rnd = random.Random(5)
lines = ['sub Main()']
exp = []
for name, ah in (("ios", IOS_AVCC), ("conv", conv_avcc.hex())):
    sps, pps = params(ah)
    data = ht.skip_slice_data(sps["width_mbs"] * sps["height_mbs"], pps["pic_init_qp"])
    lines.append(f'    p = h264_params(ba_hex("{ah}"))')
    lines.append(f'    print "DATA {name} "; LCase(p.data.ToHexString())')
    exp.append(f"DATA {name} {data.hex()}")
    for k in range(4):
        fn, poc = rnd.randrange(4096), rnd.randrange(8192)
        lines.append(f'    print "SKIP {name} {k} "; LCase(h264_skip_frame(p, {fn}, {poc}).ToHexString())')
        nal = ht.skip_nal(sps, pps, fn, poc, data)
        exp.append(f"SKIP {name} {k} {(struct.pack('>I', len(nal)) + nal).hex()}")
sps, pps = params(conv_avcc.hex())
lines.append(f'    p = h264_params(ba_hex("{conv_avcc.hex()}"))')
for k, fr in enumerate(frames[:40]):
    if not any(n[0] & 31 in (1, 5) for n in fr):
        continue
    shift = rnd.choice([0, 2, 6, 8190, 4000])
    src = avcc_frame(fr)
    want = b"".join(struct.pack(">I", len(x)) + x for x in
                    [(ht.shift_poc(n, sps, shift) if (n[0] & 31) in (1, 5) and shift else n) for n in fr if n[0] & 31 in (1, 5, 6)])
    lines.append(f'    r = h264_process_frame(p, ba_hex("{src.hex()}"), {shift})')
    lines.append(f'    print "SHIFT {k} "; LCase(r.data.ToHexString())')
    exp.append(f"SHIFT {k} {want.hex()}")
lines.append('end sub')
tmp = tempfile.mkdtemp(dir=os.path.join(ROOT, "test"))
os.makedirs(tmp + "/source")
for f in ("util.brs", "h264.brs"):
    shutil.copy(os.path.join(ROOT, "app/source", f), tmp + "/source/")
open(tmp + "/source/t.brs", "w").write("\n".join(lines) + "\n")
r = subprocess.run([NODE, BRS, "--root", tmp, "source/t.brs", "source/util.brs", "source/h264.brs"], capture_output=True, text=True, cwd=tmp, timeout=600)
shutil.rmtree(tmp)
got = [l.strip() for l in r.stdout.splitlines() if l.startswith(("DATA", "SKIP", "SHIFT"))]
bad = [(e[:60], g[:60]) for e, g in zip(exp, got) if e != g]
print(f"{len(exp)} expected, {len(got)} got, {len(bad)} mismatches")
for e, g in bad[:5]:
    print("  want", e, "\n  got ", g)
if len(got) != len(exp):
    print(r.stdout[-800:], r.stderr[-800:])
print("RESULT", "PASS" if not bad and len(got) == len(exp) else "FAIL")
