#!/usr/bin/env python3
"""Pull the receiver's live HLS over the LAN for N seconds into one fMP4 file."""
import sys, time, urllib.request, re
host, secs, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
base = f"http://{host}:8888/hls/current/"
def get(u):
    return urllib.request.urlopen(base + u, timeout=5).read()
seen, data, inits, t0 = set(), b"", {}, time.time()
while time.time() - t0 < secs:
    pl = get("live.m3u8").decode()
    init = None
    for line in pl.splitlines():
        m = re.match(r'#EXT-X-MAP:URI="(.+)"', line)
        if m:
            init = m.group(1)
        elif line.endswith(".m4s") and line not in seen:
            seq = int(line[1:-4])
            if not data or init not in inits:
                inits[init] = get(init)
                data += inits[init]
            try:
                data += get(line)     # parked until ready for future segments
                seen.add(line)
            except Exception as e:
                break
    time.sleep(0.2)
open(out, "wb").write(data)
print(f"captured {len(seen)} segments, {len(data)} bytes, inits {list(inits)}")
