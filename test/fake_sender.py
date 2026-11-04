#!/usr/bin/env python3
"""Fake AirPlay sender for testing the Roku receiver from a computer.

Implements the client side of the same protocol RPiPlay/UxPlay accept:
mDNS discovery, GET /info, pair-setup + pair-verify (real X25519/Ed25519, the
receiver's signature is verified), fp-setup, SETUP, and then streams
AES-CTR-encrypted H.264 (mirroring) and/or AES-CBC-encrypted ALAC (audio).

FairPlay can't be emulated client-side, so the mirror/audio key is sent in
the clear as `testAesKey`, which the receiver only honours when launched with
testmode=1 (ECP: POST /launch/dev?testmode=1).

usage: fake_sender.py ROKU_IP [discover|info|pair|mirror|audio|all] [seconds]
"""
import os, socket, struct, sys, time, plistlib, hashlib, secrets, subprocess, threading
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import serialization as ser

RAW = dict(encoding=ser.Encoding.Raw, format=ser.PublicFormat.Raw)
HERE = os.path.dirname(os.path.abspath(__file__))


def log(*a):
    print("[sender]", *a, flush=True)


# ------------------------------------------------------------------ mDNS

def mdns_query(name="_airplay._tcp.local", qtype=12, timeout=3.0):
    q = struct.pack(">HHHHHH", 0x1234, 0, 1, 0, 0, 0)
    for label in name.split("."):
        q += bytes([len(label)]) + label.encode()
    q += b"\x00" + struct.pack(">HH", qtype, 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    s.sendto(q, ("224.0.0.251", 5353))   # from an ephemeral port => legacy unicast reply
    out = []
    end = time.time() + timeout
    while time.time() < end:
        try:
            data, addr = s.recvfrom(9000)
        except socket.timeout:
            break
        out.append((addr, parse_dns(data)))
    return out


def read_name(d, off):
    labels, jumped, nxt = [], False, None
    while True:
        l = d[off]
        if l == 0:
            off += 1
            break
        if l >= 192:
            if not jumped:
                nxt = off + 2
            off = ((l & 63) << 8) | d[off + 1]
            jumped = True
            continue
        labels.append(d[off + 1:off + 1 + l].decode(errors="replace"))
        off += 1 + l
    return ".".join(labels), (nxt if jumped else off)


def parse_dns(d):
    _, flags, qd, an, ns, ar = struct.unpack(">HHHHHH", d[:12])
    off = 12
    for _ in range(qd):
        _, off = read_name(d, off)
        off += 4
    rrs = []
    for _ in range(an + ns + ar):
        name, off = read_name(d, off)
        t, c, ttl, rl = struct.unpack(">HHIH", d[off:off + 10])
        off += 10
        rd = d[off:off + rl]
        if t == 12:
            val = read_name(d, off)[0]
        elif t == 33:
            val = (struct.unpack(">H", rd[4:6])[0], read_name(d, off + 6)[0])
        elif t == 16:
            val, i = [], 0
            while i < len(rd):
                val.append(rd[i + 1:i + 1 + rd[i]].decode(errors="replace"))
                i += 1 + rd[i]
        elif t == 1:
            val = ".".join(str(x) for x in rd)
        else:
            val = rd.hex()
        rrs.append((name, {1: "A", 12: "PTR", 16: "TXT", 33: "SRV"}.get(t, t), ttl, val))
        off += rl
    return rrs


# ------------------------------------------------------------------ RTSP

class Rtsp:
    def __init__(self, host, port=7000):
        self.host = host
        self.s = socket.create_connection((host, port), timeout=60)
        self.cseq = 0
        self.lock = threading.Lock()

    def req(self, method, url, body=b"", ctype=None, headers=None, proto="RTSP/1.0"):
        with self.lock:
            self.cseq += 1
            h = f"{method} {url} {proto}\r\nCSeq: {self.cseq}\r\nUser-Agent: AirPlay/690.7.1\r\n"
            if ctype:
                h += f"Content-Type: {ctype}\r\n"
            for k, v in (headers or {}).items():
                h += f"{k}: {v}\r\n"
            h += f"Content-Length: {len(body)}\r\n\r\n"
            t0 = time.time()
            self.s.sendall(h.encode() + body)
            buf = b""
            while b"\r\n\r\n" not in buf:
                chunk = self.s.recv(65536)
                if not chunk:
                    raise ConnectionError("closed")
                buf += chunk
            head, rest = buf.split(b"\r\n\r\n", 1)
            lines = head.decode().split("\r\n")
            hdrs = {l.split(":", 1)[0].lower(): l.split(":", 1)[1].strip() for l in lines[1:] if ":" in l}
            n = int(hdrs.get("content-length", 0))
            while len(rest) < n:
                rest += self.s.recv(65536)
            code = int(lines[0].split()[1])
            log(f"{method} {url} -> {code} ({len(rest)} bytes, {time.time() - t0:.2f}s)")
            return code, hdrs, rest


def plist(d):
    return plistlib.dumps(d, fmt=plistlib.FMT_BINARY)


# ------------------------------------------------------------------ steps

def do_info(r):
    code, h, body = r.req("GET", "/info", plist({"qualifier": ["txtAirPlay"]}), "application/x-apple-binary-plist")
    p = plistlib.loads(body)
    log("info(txtAirPlay) keys:", list(p))
    code, h, body = r.req("GET", "/info")
    p = plistlib.loads(body)
    log("info:", {k: (v if not isinstance(v, bytes) else v.hex()) for k, v in p.items() if k not in ("audioFormats", "audioLatencies")})
    return p


def do_pair(r, info_pk):
    ed = Ed25519PrivateKey.generate()
    ed_pub = ed.public_key().public_bytes(**RAW)
    code, h, body = r.req("POST", "/pair-setup", ed_pub, "application/octet-stream")
    assert code == 200 and len(body) == 32, "pair-setup failed"
    server_ed = body
    if info_pk is not None:
        assert server_ed == info_pk, "pair-setup key != /info pk"
    x = X25519PrivateKey.generate()
    x_pub = x.public_key().public_bytes(**RAW)
    code, h, body = r.req("POST", "/pair-verify", b"\x01\x00\x00\x00" + x_pub + ed_pub, "application/octet-stream")
    assert code == 200 and len(body) == 96, f"pair-verify 1 failed ({code}, {len(body)})"
    server_x = body[:32]
    shared = x.exchange(X25519PublicKey.from_public_bytes(server_x))
    key = hashlib.sha512(b"Pair-Verify-AES-Key" + shared).digest()[:16]
    iv = hashlib.sha512(b"Pair-Verify-AES-IV" + shared).digest()[:16]
    ctr = Cipher(algorithms.AES(key), modes.CTR(iv)).encryptor()
    sig = ctr.update(body[32:])
    Ed25519PublicKey.from_public_bytes(server_ed).verify(sig, server_x + x_pub)
    log("pair-verify: receiver signature VERIFIED, shared secret established")
    mysig = ed.sign(x_pub + server_x)
    enc = ctr.update(mysig)
    code, h, body = r.req("POST", "/pair-verify", b"\x00\x00\x00\x00" + enc, "application/octet-stream")
    assert code == 200
    return shared


def do_fp(r):
    p1 = bytes.fromhex("46504c590301010000000004020000bb")
    code, h, body = r.req("POST", "/fp-setup", p1, "application/octet-stream")
    assert code == 200 and len(body) == 142, f"fp-setup 1 failed {code} {len(body)}"
    p2 = bytes.fromhex("46504c5903010300000000980000") + secrets.token_bytes(150)
    code, h, body = r.req("POST", "/fp-setup", p2, "application/octet-stream")
    assert code == 200 and len(body) == 32 and body[12:] == p2[144:], "fp-setup 2 failed"
    log("fp-setup ok (reply echoes last 20 bytes)")


def stream_keys(aeskey, shared, conn_id):
    k = hashlib.sha512(aeskey + shared).digest()[:16] if shared else aeskey
    vk = hashlib.sha512(f"AirPlayStreamKey{conn_id}".encode() + k).digest()[:16]
    vi = hashlib.sha512(f"AirPlayStreamIV{conn_id}".encode() + k).digest()[:16]
    return k, vk, vi


def setup_session(r, aeskey, aesiv):
    body = plist({"ekey": secrets.token_bytes(72), "eiv": aesiv, "testAesKey": aeskey, "timingPort": 61111,
                  "timingProtocol": "NTP", "name": "fake_sender", "model": "iPhone14,2", "deviceID": "11:22:33:44:55:66",
                  "isScreenMirroringSession": True, "sessionUUID": "8BC6C5E3-0000-0000-0000-000000000000"})
    code, h, resp = r.req("SETUP", "rtsp://x/1", body, "application/x-apple-binary-plist")
    assert code == 200, "SETUP 1 failed"
    log("SETUP 1 ->", plistlib.loads(resp))


def annexb_to_frames(path):
    data = open(path, "rb").read()
    if os.environ.get("MIRROR_IOS_LAYOUT", "1") == "1":
        # re-express libx264 output in the iOS layout (POC type 0, 12-bit
        # frame_num), like a real iPhone stream
        sys.path.insert(0, os.path.join(HERE, "h264"))
        import h264tool
        data = h264tool.to_annexb(h264tool.convert_x264(h264tool.split_annexb(data)))
    starts, i = [], 0
    while True:
        j = data.find(b"\x00\x00\x01", i)
        if j < 0:
            break
        starts.append(j + 3)
        i = j + 3
    nals = []
    for k, s in enumerate(starts):
        e = starts[k + 1] - 3 if k + 1 < len(starts) else len(data)
        n = data[s:e]
        while n.endswith(b"\x00"):
            n = n[:-1]
        nals.append(n)
    sps = next(n for n in nals if n[0] & 31 == 7)
    pps = next(n for n in nals if n[0] & 31 == 8)
    frames, cur = [], []
    for n in nals:
        t = n[0] & 31
        if t in (1, 5):
            cur.append(n)
            frames.append(cur)
            cur = []
        elif t == 6:
            cur.append(n)
    return sps, pps, frames


def do_mirror(r, aeskey, shared, seconds, w=1280, h=720, fps=30):
    rate = os.environ.get("MIRROR_RATE", "2M")
    noise = os.environ.get("MIRROR_NOISE", "0")
    src = os.path.join(HERE, "scratch", f"mirror_{w}x{h}_{rate}_n{noise}.h264")
    if not os.path.exists(src):
        vf = f"testsrc=size={w}x{h}:rate={fps}" + (f",noise=alls={noise}:allf=t" if noise != "0" else "")
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", vf, "-t", "40", "-c:v", "libx264",
                        "-profile:v", "high", "-pix_fmt", "yuv420p", "-g", "300", "-b:v", rate, "-maxrate", rate,
                        "-x264-params", "bframes=0:weightp=0:slices=1",
                        "-bufsize", rate, "-bsf:v", "h264_mp4toannexb", "-f", "h264", src], check=True)
    sps, pps, frames = annexb_to_frames(src)
    conn_id = secrets.randbits(63) | (1 << 63)   # exercise the unsigned >= 2^63 path
    code, hd, resp = r.req("SETUP", "rtsp://x/1", plist({"streams": [{"type": 110, "streamConnectionID": conn_id - 2**64,
                                                                      "timestampInfo": [{"name": "SubSu"}]}]}),
                           "application/x-apple-binary-plist")
    port = plistlib.loads(resp)["streams"][0]["dataPort"]
    _, vk, vi = stream_keys(aeskey, shared, conn_id)
    ctr = Cipher(algorithms.AES(vk), modes.CTR(vi)).encryptor()
    m = socket.create_connection((r.host, port))
    log("mirror connected to", port)

    def header(size, ptype, opt=0, ts=0, extra=b""):
        hdr = struct.pack("<IBBH", size, ptype, opt & 0xFF, (opt >> 8)) + struct.pack("<Q", ts)
        hdr += extra
        return hdr + b"\x00" * (128 - len(hdr))

    def config_packet(sps, pps, w, h):
        avcc = bytes([1, sps[1], sps[2], sps[3], 0xFF, 0xE1]) + struct.pack(">H", len(sps)) + sps + b"\x01" + struct.pack(">H", len(pps)) + pps
        hdr = bytearray(header(len(avcc), 1, 0x0116))
        struct.pack_into("<ff", hdr, 40, w, h)
        struct.pack_into("<ff", hdr, 56, w, h)
        return bytes(hdr) + avcc

    # iPhone-like behaviour: irregular frame pacing with occasional still-screen
    # pauses (MIRROR_JITTER=1) and a rotation to portrait halfway (MIRROR_ROTATE=1)
    import random
    rnd = random.Random(7)
    jitter = os.environ.get("MIRROR_JITTER", "0") != "0"
    max_pause = 2.5 if os.environ.get("MIRROR_JITTER") == "2" else 1.5
    rotate = os.environ.get("MIRROR_ROTATE") == "1"
    streams = [(sps, pps, frames, w, h)]
    if rotate:
        src2 = os.path.join(HERE, "scratch", "mirror_portrait.h264")
        if not os.path.exists(src2):
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=332x720:rate=30", "-t", "40",
                            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-g", "9999", "-b:v", "800k",
                            "-x264-params", "bframes=0:weightp=0:slices=1", "-bsf:v", "h264_mp4toannexb",
                            "-f", "h264", src2], check=True)
        s2, p2, f2 = annexb_to_frames(src2)
        streams.append((s2, p2, f2, 332, 720))
    m.sendall(config_packet(sps, pps, w, h))
    t0 = time.time()
    sent = 0
    i = 0
    cur = 0
    fi = 0
    next_pause = t0 + rnd.uniform(3, 8)
    while time.time() - t0 < seconds:
        if rotate and cur == 0 and time.time() - t0 > seconds / 2:
            cur = 1
            fi = 0
            s2, p2, f2, w2, h2 = streams[1]
            log("rotating to", w2, "x", h2)
            m.sendall(config_packet(s2, p2, w2, h2))
        fr = streams[cur][2]
        if fi >= len(fr):
            break
        f = fr[fi]
        fi += 1
        payload = b"".join(struct.pack(">I", len(n)) + n for n in f)
        enc = ctr.update(payload)
        now = time.time()
        ntp_s = now + 2208988800
        ntp = (int(ntp_s) << 32) | int((ntp_s % 1) * (1 << 32))
        key = any(n[0] & 31 == 5 for n in f)
        m.sendall(header(len(enc), 0, 0x10 if key else 0, ntp) + enc)
        sent += len(enc)
        i += 1
        if i % 60 == 0:
            r.req("POST", "/feedback")
        if os.environ.get("MIRROR_JITTER") == "3":
            # steady 30 fps with an exact 0.8 s pause every 6 s
            if now >= next_pause:
                log("still screen: pause 0.8s")
                time.sleep(0.8)
                next_pause = time.time() + 6
            else:
                time.sleep(1 / 30)
        elif jitter:
            if now >= next_pause:
                gap = rnd.uniform(0.3, max_pause)
                log(f"still screen: pause {gap:.1f}s")
                time.sleep(gap)
                next_pause = time.time() + rnd.uniform(3, 8)
            else:
                time.sleep(rnd.choice([1 / 30, 1 / 30, 1 / 20, 1 / 12, 0.005]))
        else:
            time.sleep(max(0, t0 + i / fps - time.time()))
    log(f"mirror: sent {i} frames, {sent} bytes in {time.time() - t0:.1f}s")
    m.close()


def ebml_blocks(path):
    """Yield SimpleBlock payloads from an ffmpeg-written Matroska file."""
    d = open(path, "rb").read()

    def vint(o, keep_marker=False):
        b = d[o]
        l = 1
        while not b & (0x80 >> (l - 1)):
            l += 1
        v = b & ((0x80 >> (l - 1)) - 1) if not keep_marker else b
        for k in range(1, l):
            v = (v << 8) | d[o + k]
        return v, l

    def walk(o, end):
        while o < end:
            eid, il = vint(o, keep_marker=True)
            size, sl = vint(o + il)
            body = o + il + sl
            if size == (1 << (7 * sl)) - 1:
                size = end - body
            if eid in (0x18538067, 0x1F43B675):
                yield from walk(body, body + size)
            elif eid == 0xA3:
                yield d[body + 4:body + size]
            o = body + size
    yield from walk(0, len(d))


def alac_escape_frame(left, right):
    """One uncompressed ("escape") ALAC frame: stereo CPE, 16-bit, len(left) samples."""
    bits = []
    def put(v, n):
        for i in range(n - 1, -1, -1):
            bits.append((v >> i) & 1)
    put(1, 3); put(0, 4); put(0, 12); put(0, 1); put(0, 2); put(1, 1)
    for l, r in zip(left, right):
        put(l & 0xFFFF, 16); put(r & 0xFFFF, 16)
    put(7, 3)
    while len(bits) % 8:
        bits.append(0)
    return bytes(int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8))


def alac_test_frames(seconds, fl=523.25, fr=659.25):
    import math
    out = []
    n = 0
    for f in range(int(seconds * 44100 / 352) + 1):
        L = [int(12000 * math.sin(2 * math.pi * fl * (n + i) / 44100)) for i in range(352)]
        R = [int(12000 * math.sin(2 * math.pi * fr * (n + i) / 44100)) for i in range(352)]
        out.append(alac_escape_frame(L, R))
        n += 352
    return out


def do_audio(r, aeskey, shared, aesiv, seconds):
    blocks = alac_test_frames(seconds)
    code, hd, resp = r.req("SETUP", "rtsp://x/1", plist({"streams": [{"type": 96, "ct": 2, "spf": 352, "audioFormat": 0x40000,
                                                                      "controlPort": 61112, "isMedia": True}]}),
                           "application/x-apple-binary-plist")
    st = plistlib.loads(resp)["streams"][0]
    key, _, _ = stream_keys(aeskey, shared, 0)
    u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    r.req("RECORD", "rtsp://x/1")
    t0 = time.time()
    seq, ts = secrets.randbits(16), secrets.randbits(32)
    for i, blk in enumerate(blocks):
        if time.time() - t0 > seconds:
            break
        n = len(blk) // 16 * 16
        dec = Cipher(algorithms.AES(key), modes.CBC(aesiv)).encryptor()
        payload = (dec.update(blk[:n]) + dec.finalize() if n else b"") + blk[n:]
        hdr = struct.pack(">BBHII", 0x80, 0x60 | (0x80 if i == 0 else 0), seq & 0xFFFF, ts & 0xFFFFFFFF, 0x12345678)
        u.sendto(hdr + payload, (r.host, st["dataPort"]))
        seq += 1
        ts += 352
        delay = t0 + (i + 1) * 352 / 44100 - time.time()
        if delay > 0:
            time.sleep(delay)
    log(f"audio: sent {i + 1} ALAC packets in {time.time() - t0:.1f}s")


def main():
    host = sys.argv[1]
    what = sys.argv[2] if len(sys.argv) > 2 else "all"
    seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 20
    if what in ("discover", "all"):
        for name, qt in (("_airplay._tcp.local", 12), ("_raop._tcp.local", 12)):
            res = mdns_query(name, qt)
            mine = [(a, rr) for a, rr in res if a[0] == host]
            log(f"mDNS {name}: {len(res)} responses, {len(mine)} from {host}")
            for a, rr in mine:
                for x in rr:
                    log("   ", x)
        if what == "discover":
            return
    r = Rtsp(host)
    info = do_info(r)
    if what == "info":
        return
    shared = do_pair(r, info.get("pk"))
    if what == "pair":
        return
    do_fp(r)
    aeskey, aesiv = secrets.token_bytes(16), secrets.token_bytes(16)
    setup_session(r, aeskey, aesiv)
    if what in ("mirror", "all"):
        do_mirror(r, aeskey, shared, seconds)
    if what in ("audio", "all"):
        do_audio(r, aeskey, shared, aesiv, seconds)
    r.req("TEARDOWN", "rtsp://x/1", plist({}), "application/x-apple-binary-plist")


if __name__ == "__main__":
    main()
