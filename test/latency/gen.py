#!/usr/bin/env python3
"""Generate live-latency test media for spike3.

Writes into spike3/media/:
  low.mkv (+ low.sched)          live MKV like the receiver produces, ~iPhone static-screen bitrate
  lowpad1.mkv / lowpad4.mkv      same with 1 MB / 4 MB Matroska Void after Tracks
  h05/ h10/  (+ .sched)          HLS fMP4 split every 0.5 s / 1.0 s regardless of keyframes
                                 (iOS only sends one IDR, so segments can't rely on keyframes)
A .sched file lists "<release_ms> <bytes_or_segment>" so the device server can
release data at the same pace a real sender would produce it.
"""
import os, subprocess, sys, struct, re, shutil
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "test"))
import mkv_proto as mp

OUT = os.path.join(ROOT, "spike3", "media")
SCR = os.path.join(ROOT, "test", "scratch")
FPS = 30


def main():
    if os.path.exists(OUT):
        shutil.rmtree(OUT)
    os.makedirs(OUT)
    src = os.path.join(SCR, "lat_low.h264")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"testsrc=size=640x360:rate={FPS}",
                    "-t", "40", "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p", "-g", "9999",
                    "-b:v", "250k", "-maxrate", "250k", "-bufsize", "250k", "-bsf:v", "h264_mp4toannexb", "-f", "h264", src], check=True)
    nals = mp.split_annexb(open(src, "rb").read())
    sps = next(n for n in nals if n[0] & 0x1F == 7)
    pps = next(n for n in nals if n[0] & 0x1F == 8)
    avcc = bytes([1, sps[1], sps[2], sps[3], 0xFF, 0xE1]) + struct.pack(">H", len(sps)) + sps + b"\x01" + struct.pack(">H", len(pps)) + pps
    frames, cur = [], []
    for n in nals:
        t = n[0] & 0x1F
        if t in (1, 5):
            cur.append(n); frames.append(cur); cur = []
        elif t == 6:
            cur.append(n)
    for name, fill in ():
        out = bytearray(mp.header(640, 360, avcc))
        sched = [(0, len(out))]
        ctc = None
        for i, f in enumerate(frames):
            tc = i * 1000 // FPS
            key = any(n[0] & 31 == 5 for n in f)
            if ctc is None or key or tc - ctc >= 1000:
                ctc = tc
                out += mp.cluster_start(tc)
            data = b"".join(struct.pack(">I", len(n)) + n for n in f)
            if fill and i == 0:
                filler = b"\x0c" + b"\xff" * (fill - 2) + b"\x80"   # H.264 filler-data NAL (type 12)
                data += struct.pack(">I", len(filler)) + filler
            out += mp.simple_block(tc - ctc, key, data)
            sched.append((tc, len(out)))
        open(os.path.join(OUT, name + ".mkv"), "wb").write(out)
        open(os.path.join(OUT, name + ".sched"), "w").write("\n".join(f"{a} {b}" for a, b in sched) + "\n")
        print(name, len(out), "bytes")
    import fmp4_proto as fp
    # catch-up variants: after 4 s, give each 0.5 s of real frames 0.4 s of media time
    # until the media timeline is `target` behind real time's 3.9 s start depth
    for name, segt, target in (("c15", 0.5, 1.5), ("c10", 0.5, 1.0), ("q10", 0.25, 1.0)):
        d = os.path.join(OUT, name)
        os.makedirs(d)
        open(os.path.join(d, "init.mp4"), "wb").write(fp.init_segment(640, 360, avcc))
        dur = fp.TS // FPS
        per = int(segt * FPS)
        rows, media, saved = [], 0, 0.0
        need = 3.9 - target
        for si, i0 in enumerate(range(0, len(frames), per)):
            chunk = frames[i0:i0 + per]
            real_end = (i0 + len(chunk)) / FPS
            scale = 0.8 if (real_end > 4.0 and saved < need) else 1.0
            fd = int(dur * scale)
            samples = [(fd, any(n[0] & 31 == 5 for n in f), b"".join(struct.pack(">I", len(n)) + n for n in f)) for f in chunk]
            open(os.path.join(d, f"s{si}.m4s"), "wb").write(fp.media_segment(si + 1, media, samples))
            media += fd * len(chunk)
            saved += (dur - fd) * len(chunk) / fp.TS
            rows.append(f"{int(real_end * 1000)} {si} {media * 1000 // fp.TS} {fd * len(chunk) / fp.TS:.3f}")
        open(os.path.join(OUT, name + ".sched"), "w").write("\n".join(rows) + "\n")
        print(name, len(rows), "segments, saved %.2fs" % saved)
    for name, segt in (("h05", 0.5),):
        d = os.path.join(OUT, name)
        os.makedirs(d)
        open(os.path.join(d, "init.mp4"), "wb").write(fp.init_segment(640, 360, avcc))
        dur = fp.TS // FPS
        per = int(segt * FPS)
        rows = []
        for si, i0 in enumerate(range(0, len(frames), per)):
            chunk = frames[i0:i0 + per]
            samples = [(dur, any(n[0] & 31 == 5 for n in f), b"".join(struct.pack(">I", len(n)) + n for n in f)) for f in chunk]
            open(os.path.join(d, f"s{si}.m4s"), "wb").write(fp.media_segment(si + 1, i0 * dur, samples))
            rows.append(f"{(i0 + len(chunk)) * 1000 // FPS} {si} {(i0 + len(chunk)) * 1000 // FPS} {len(chunk) / FPS:.3f}")
        open(os.path.join(OUT, name + ".sched"), "w").write("\n".join(rows) + "\n")
        full = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-MAP:URI=\"init.mp4\"\n"
        full += "".join(f"#EXTINF:{r.split()[2]},\ns{r.split()[1]}.m4s\n" for r in rows) + "#EXT-X-ENDLIST\n"
        open(os.path.join(d, "full.m3u8"), "w").write(full)
        print(name, len(rows), "segments")


if __name__ == "__main__":
    main()
