#!/usr/bin/env python3
"""Prototype fragmented-MP4 (CMAF-style) writer for live HLS of AirPlay mirror
video. Segments are cut purely by time: iOS sends a single IDR, so segments
after the first don't start with a keyframe (legal for fMP4 HLS when played
sequentially)."""
import struct

TS = 90000  # media timescale


def box(t, *parts):
    p = b"".join(parts)
    return struct.pack(">I", 8 + len(p)) + t + p


def fbox(t, ver, flags, *parts):
    return box(t, struct.pack(">I", (ver << 24) | flags), *parts)


MATRIX = struct.pack(">9I", 0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000)


def init_segment(w, h, avcc):
    ftyp = box(b"ftyp", b"iso5", struct.pack(">I", 512), b"iso5iso6mp41")
    mvhd = fbox(b"mvhd", 0, 0, struct.pack(">IIII", 0, 0, 1000, 0), struct.pack(">IH", 0x10000, 0x100), bytes(10), MATRIX, bytes(24), struct.pack(">I", 2))
    tkhd = fbox(b"tkhd", 0, 3, struct.pack(">IIIII", 0, 0, 1, 0, 0), bytes(8), struct.pack(">HHHH", 0, 0, 0, 0), MATRIX, struct.pack(">II", w << 16, h << 16))
    mdhd = fbox(b"mdhd", 0, 0, struct.pack(">IIII", 0, 0, TS, 0), struct.pack(">HH", 0x55C4, 0))
    hdlr = fbox(b"hdlr", 0, 0, struct.pack(">I", 0), b"vide", bytes(12), b"VideoHandler\x00")
    vmhd = fbox(b"vmhd", 0, 1, bytes(8))
    dinf = box(b"dinf", fbox(b"dref", 0, 0, struct.pack(">I", 1), fbox(b"url ", 0, 1)))
    avc1 = box(b"avc1", bytes(6), struct.pack(">H", 1), bytes(16), struct.pack(">HH", w, h),
               struct.pack(">II", 0x480000, 0x480000), bytes(4), struct.pack(">H", 1), bytes(32),
               struct.pack(">Hh", 0x18, -1), box(b"avcC", avcc))
    stbl = box(b"stbl", fbox(b"stsd", 0, 0, struct.pack(">I", 1), avc1), fbox(b"stts", 0, 0, bytes(4)),
               fbox(b"stsc", 0, 0, bytes(4)), fbox(b"stsz", 0, 0, bytes(8)), fbox(b"stco", 0, 0, bytes(4)))
    minf = box(b"minf", vmhd, dinf, stbl)
    trak = box(b"trak", tkhd, box(b"mdia", mdhd, hdlr, minf))
    mvex = box(b"mvex", fbox(b"trex", 0, 0, struct.pack(">IIIII", 1, 1, 0, 0, 0)))
    return ftyp + box(b"moov", mvhd, trak, mvex)


def media_segment(seq, base_dts, samples):
    """samples: list of (duration_ticks, is_key, avcc_bytes)"""
    n = len(samples)
    trun_len = 8 + 4 + 4 + 4 + n * 12
    # moof = 8 + mfhd(16) + traf(8 + tfhd(16) + tfdt(20) + trun)
    moof_len = 8 + 16 + 8 + 16 + 20 + trun_len
    entries = b"".join(struct.pack(">III", d, len(s), 0x02000000 if k else 0x01010000) for d, k, s in samples)
    trun = fbox(b"trun", 0, 0x000701, struct.pack(">Ii", n, moof_len + 8), entries)
    traf = box(b"traf", fbox(b"tfhd", 0, 0x020000, struct.pack(">I", 1)), fbox(b"tfdt", 1, 0, struct.pack(">Q", base_dts)), trun)
    moof = box(b"moof", fbox(b"mfhd", 0, 0, struct.pack(">I", seq)), traf)
    assert len(moof) == moof_len
    data = b"".join(s for _, _, s in samples)
    return moof + struct.pack(">I", 8 + len(data)) + b"mdat" + data
