#!/usr/bin/env python3
"""Prototype of the live Matroska muxer the Roku receiver uses.

Input: an H.264 Annex-B elementary stream (what we get after decrypting
AirPlay mirror payloads is AVCC/length-prefixed, so the converter below only
exists to feed the prototype from ffmpeg output).

Output layout (matches what BrightScript will emit, byte for byte):
  EBML header
  Segment (unknown size)
    Info (TimecodeScale = 1ms)
    Tracks: one video track, V_MPEG4/ISO/AVC, CodecPrivate = avcC
    Cluster (unknown size) per keyframe or every ~1 s:
      Timecode
      SimpleBlock per access unit (track 1, relative timecode, flags)
"""
import struct
import sys


def vint(n):
    for length in range(1, 9):
        if n < (1 << (7 * length)) - 1:
            v = n | (1 << (7 * length))
            return v.to_bytes(length, "big")
    raise ValueError(n)


UNKNOWN = b"\x01\xff\xff\xff\xff\xff\xff\xff"


def el(id_bytes, payload):
    return id_bytes + vint(len(payload)) + payload


def uint(id_bytes, v):
    n = max(1, (v.bit_length() + 7) // 8)
    return el(id_bytes, v.to_bytes(n, "big"))


def header(width, height, avcc):
    ebml = el(b"\x1a\x45\xdf\xa3",
              uint(b"\x42\x86", 1) + uint(b"\x42\xf7", 1) + uint(b"\x42\xf2", 4) +
              uint(b"\x42\xf3", 8) + el(b"\x42\x82", b"matroska") +
              uint(b"\x42\x87", 4) + uint(b"\x42\x85", 2))
    info = el(b"\x15\x49\xa9\x66", uint(b"\x2a\xd7\xb1", 1000000) +
              el(b"\x4d\x80", b"rokuairplay") + el(b"\x57\x41", b"rokuairplay"))
    video = el(b"\xe0", uint(b"\xb0", width) + uint(b"\xba", height))
    track = el(b"\xae", uint(b"\xd7", 1) + uint(b"\x73\xc5", 1) + uint(b"\x83", 1) +
               uint(b"\x9c", 0) + el(b"\x86", b"V_MPEG4/ISO/AVC") +
               el(b"\x63\xa2", avcc) + video)
    tracks = el(b"\x16\x54\xae\x6b", track)
    return ebml + b"\x18\x53\x80\x67" + UNKNOWN + info + tracks


def cluster_start(tc_ms):
    return b"\x1f\x43\xb6\x75" + UNKNOWN + uint(b"\xe7", tc_ms)


def simple_block(rel_ms, key, data):
    hdr = b"\x81" + struct.pack(">h", rel_ms) + bytes([0x80 if key else 0x00])
    return el(b"\xa3", hdr + data)


def split_annexb(buf):
    i, starts = 0, []
    while True:
        j = buf.find(b"\x00\x00\x01", i)
        if j < 0:
            break
        starts.append(j + 3)
        i = j + 3
    nals = []
    for k, s in enumerate(starts):
        e = starts[k + 1] - 3 if k + 1 < len(starts) else len(buf)
        nal = buf[s:e]
        while nal.endswith(b"\x00"):
            nal = nal[:-1]
        nals.append(nal)
    return nals


def main(src, dst, W=640, H=360, fps=30):
    nals = split_annexb(open(src, "rb").read())
    sps = next(n for n in nals if n[0] & 0x1F == 7)
    pps = next(n for n in nals if n[0] & 0x1F == 8)
    avcc = bytes([1, sps[1], sps[2], sps[3], 0xFF, 0xE1]) + struct.pack(">H", len(sps)) + sps + \
        b"\x01" + struct.pack(">H", len(pps)) + pps
    out = bytearray(header(W, H, avcc))
    frames, cur = [], []
    for n in nals:
        t = n[0] & 0x1F
        if t in (1, 5):
            cur.append(n)
            frames.append(cur)
            cur = []
        elif t in (7, 8, 6, 9):
            cur.append(n)
    cluster_tc = None
    for idx, f in enumerate(frames):
        tc = idx * 1000 // fps
        key = any(n[0] & 0x1F == 5 for n in f)
        if cluster_tc is None or key or tc - cluster_tc > 1000:
            cluster_tc = tc
            out += cluster_start(tc)
        data = b"".join(struct.pack(">I", len(n)) + n for n in f)
        out += simple_block(tc - cluster_tc, key, data)
    open(dst, "wb").write(out)
    print(f"{len(frames)} frames -> {dst} ({len(out)} bytes)")


if __name__ == "__main__":
    a = sys.argv
    main(a[1], a[2], *(int(x) for x in a[3:5]))
