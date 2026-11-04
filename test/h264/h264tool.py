#!/usr/bin/env python3
"""H.264 helpers for the receiver's "skip frame" gap filling (reference
implementation for app/source/h264.brs).

While an iPhone's screen is still, iOS sends no video frames (it repeats the
codec config ~30x/s instead). The Roku player then runs dry and rebuffers. The
receiver fills such gaps with generated frames that repeat the previous
picture: a non-reference P slice in which every macroblock is P_Skip.

For the iOS stream layout (High profile, CABAC, pic_order_cnt_type 0) this
needs:
  * skip_slice_data(): the CABAC payload. It depends only on the macroblock
    count and slice QP, so the receiver computes it once per codec config.
  * skip_nal(): slice header (frame_num = prevRefFrameNum + 1, a POC between
    the previous frame and the next real one) + that payload.
  * shift_poc(): real frames that follow inserted frames get their
    pic_order_cnt_lsb shifted so display order stays increasing. The field is
    fixed-width, so it is rewritten in place.

Also: convert_x264(), which rewrites libx264 output (POC type 2 without
B-frames) into the iOS layout so the fake sender and tests are realistic.

usage: h264tool.py selftest
"""
import json, os, struct, subprocess, sys, hashlib

HERE = os.path.dirname(os.path.abspath(__file__))
RANGE_LPS = json.load(open(os.path.join(HERE, "range_tab_lps.json")))


# ------------------------------------------------------------------ bits

def unescape(nal):
    out, z = bytearray(), 0
    for x in nal:
        if z >= 2 and x == 3:
            z = 0
            continue
        out.append(x)
        z = z + 1 if x == 0 else 0
    return bytes(out)


def escape(rbsp):
    out, z = bytearray(), 0
    for x in rbsp:
        if z >= 2 and x <= 3:
            out.append(3)
            z = 0
        out.append(x)
        z = z + 1 if x == 0 else 0
    return bytes(out)


class R:
    def __init__(self, b, p=0):
        self.b, self.p = b, p

    def u(self, n):
        v = 0
        for _ in range(n):
            v = (v << 1) | ((self.b[self.p >> 3] >> (7 - (self.p & 7))) & 1)
            self.p += 1
        return v

    def ue(self):
        z = 0
        while self.u(1) == 0:
            z += 1
        return (1 << z) - 1 + self.u(z)

    def se(self):
        k = self.ue()
        return (k + 1) // 2 if k & 1 else -(k // 2)


class W:
    def __init__(self):
        self.bits = []

    def u(self, v, n):
        for i in range(n - 1, -1, -1):
            self.bits.append((v >> i) & 1)

    def ue(self, v):
        v += 1
        n = v.bit_length()
        self.u(0, n - 1)
        self.u(v, n)

    def se(self, v):
        self.ue(2 * v - 1 if v > 0 else -2 * v)

    def align_ones(self):
        while len(self.bits) % 8:
            self.bits.append(1)

    def trailing(self):
        self.bits.append(1)
        while len(self.bits) % 8:
            self.bits.append(0)

    def bytes(self):
        assert len(self.bits) % 8 == 0
        return bytes(int("".join(map(str, self.bits[i:i + 8])), 2) for i in range(0, len(self.bits), 8))


# ------------------------------------------------------------------ parameter sets

def parse_sps(nal):
    r = R(unescape(nal[1:]))
    d = {"profile": r.u(8), "constraints": r.u(8), "level": r.u(8), "sps_id": r.ue()}
    if d["profile"] in (100, 110, 122, 244, 44, 83, 86, 118, 128):
        d["chroma_format_idc"] = r.ue()
        if d["chroma_format_idc"] == 3:
            r.u(1)
        r.ue(); r.ue(); r.u(1)
        if r.u(1):
            raise ValueError("scaling matrices not supported")
    d["prefix_end_before_fn"] = r.p
    d["log2_max_frame_num"] = r.ue() + 4
    d["poc_type"] = r.ue()
    if d["poc_type"] == 0:
        d["log2_max_poc_lsb"] = r.ue() + 4
    elif d["poc_type"] == 1:
        raise ValueError("poc type 1 not supported")
    d["rest_bitpos"] = r.p
    d["max_num_ref_frames"] = r.ue()
    r.u(1)
    d["width_mbs"] = r.ue() + 1
    d["height_mbs"] = r.ue() + 1
    d["frame_mbs_only"] = r.u(1)
    return d


def parse_pps(nal):
    r = R(unescape(nal[1:]))
    d = {"pps_id": r.ue(), "sps_id": r.ue(), "cabac": r.u(1), "bottom_field_pic_order": r.u(1)}
    d["num_slice_groups"] = r.ue() + 1
    if d["num_slice_groups"] != 1:
        raise ValueError("slice groups not supported")
    d["num_ref_idx_l0"] = r.ue() + 1
    d["num_ref_idx_l1"] = r.ue() + 1
    d["weighted_pred"] = r.u(1)
    d["weighted_bipred"] = r.u(2)
    d["pic_init_qp"] = 26 + r.se()
    r.se()
    r.se()
    d["deblocking_control"] = r.u(1)
    d["constrained_intra"] = r.u(1)
    d["redundant_pic_cnt"] = r.u(1)
    return d


# ------------------------------------------------------------------ slice header (full, for conversion)

def parse_slice_header(nal, sps, pps):
    """Returns (fields, bitpos of slice_data start before CABAC alignment) on the RBSP."""
    rb = unescape(nal[1:])
    r = R(rb)
    f = {"nal_ref_idc": (nal[0] >> 5) & 3, "nal_type": nal[0] & 31}
    f["first_mb"] = r.ue()
    f["slice_type"] = r.ue()
    f["pps_id"] = r.ue()
    f["frame_num"] = r.u(sps["log2_max_frame_num"])
    idr = f["nal_type"] == 5
    if idr:
        f["idr_pic_id"] = r.ue()
    if sps["poc_type"] == 0:
        f["poc_lsb"] = r.u(sps["log2_max_poc_lsb"])
    st = f["slice_type"] % 5
    if st == 1:
        raise ValueError("B slices not supported")
    if st == 0:
        f["override"] = r.u(1)
        if f["override"]:
            f["num_ref_idx_l0_minus1"] = r.ue()
        f["rplm"] = []
        if r.u(1):
            while True:
                idc = r.ue()
                f["rplm"].append((idc, r.ue() if idc != 3 else None))
                if idc == 3:
                    break
    if pps["weighted_pred"] and st == 0:
        raise ValueError("weighted prediction not supported")
    if f["nal_ref_idc"]:
        if idr:
            f["no_output_prior"] = r.u(1)
            f["long_term_ref"] = r.u(1)
        else:
            f["adaptive"] = r.u(1)
            f["mmco"] = []
            if f["adaptive"]:
                while True:
                    op = r.ue()
                    args = []
                    if op in (1, 3):
                        args.append(r.ue())
                    if op == 2:
                        args.append(r.ue())
                    if op in (3, 6):
                        args.append(r.ue())
                    if op == 4:
                        args.append(r.ue())
                    f["mmco"].append((op, args))
                    if op == 0:
                        break
    if pps["cabac"] and st != 2:
        f["cabac_init_idc"] = r.ue()
    f["qp_delta"] = r.se()
    if pps["deblocking_control"]:
        f["dbk_idc"] = r.ue()
        if f["dbk_idc"] != 1:
            f["alpha"] = r.se()
            f["beta"] = r.se()
    return f, rb, r.p


def write_slice_header(w, f, sps, pps):
    w.ue(f["first_mb"]); w.ue(f["slice_type"]); w.ue(f["pps_id"])
    w.u(f["frame_num"], sps["log2_max_frame_num"])
    if f["nal_type"] == 5:
        w.ue(f["idr_pic_id"])
    if sps["poc_type"] == 0:
        w.u(f["poc_lsb"], sps["log2_max_poc_lsb"])
    st = f["slice_type"] % 5
    if st == 0:
        w.u(f["override"], 1)
        if f["override"]:
            w.ue(f["num_ref_idx_l0_minus1"])
        w.u(1 if f["rplm"] else 0, 1)
        for idc, v in f["rplm"]:
            w.ue(idc)
            if v is not None:
                w.ue(v)
    if f["nal_ref_idc"]:
        if f["nal_type"] == 5:
            w.u(f["no_output_prior"], 1); w.u(f["long_term_ref"], 1)
        else:
            w.u(f["adaptive"], 1)
            for op, args in f["mmco"]:
                w.ue(op)
                for a in args:
                    w.ue(a)
    if pps["cabac"] and st != 2:
        w.ue(f["cabac_init_idc"])
    w.se(f["qp_delta"])
    if pps["deblocking_control"]:
        w.ue(f["dbk_idc"])
        if f["dbk_idc"] != 1:
            w.se(f["alpha"]); w.se(f["beta"])


# ------------------------------------------------------------------ CABAC skip slice

CABAC_MN_SKIP_P = {0: (23, 33), 1: (22, 25), 2: (29, 16)}   # ctxIdx 11 (mb_skip_flag, P)


def skip_slice_data(num_mbs, slice_qp, cabac_init_idc=0):
    """CABAC-coded slice_data for an all-P_Skip slice (after header alignment),
    including the rbsp trailing bits. Every mb_skip_flag uses ctxIdx 11 (all
    neighbours are skipped, so ctxIdxInc = 0)."""
    m, n = CABAC_MN_SKIP_P[cabac_init_idc]
    pre = max(1, min(126, ((m * max(0, min(51, slice_qp))) >> 4) + n))
    if pre <= 63:
        state, mps = 63 - pre, 0
    else:
        state, mps = pre - 64, 1
    assert mps == 1, "skip flag context would code skip as LPS"
    bits = []
    low, rng, outstanding, first = 0, 510, 0, True

    def put(b):
        nonlocal outstanding, first
        if first:
            first = False
        else:
            bits.append(b)
        while outstanding:
            bits.append(1 - b)
            outstanding -= 1

    def renorm():
        nonlocal low, rng, outstanding
        while rng < 256:
            if low < 256:
                put(0)
            elif low >= 512:
                low -= 512
                put(1)
            else:
                low -= 256
                outstanding += 1
            rng <<= 1
            low <<= 1

    for i in range(num_mbs):
        # mb_skip_flag = 1 (MPS)
        rng -= RANGE_LPS[state][(rng >> 6) & 3]
        state = min(state + 1, 62)
        renorm()
        # end_of_slice_flag: terminate bin
        rng -= 2
        if i == num_mbs - 1:
            low += rng
            # EncodeFlush
            rng = 2
            renorm()
            put((low >> 9) & 1)
            bits.append((low >> 8) & 1)
            bits.append(1)          # rbsp_stop_one_bit (as the 2nd written bit)
        else:
            renorm()
    while len(bits) % 8:
        bits.append(0)
    return bytes(int("".join(map(str, bits[i:i + 8])), 2) for i in range(0, len(bits), 8))


def skip_nal(sps, pps, frame_num, poc_lsb, data):
    """Non-reference all-skip P slice (nal_unit_type 1, nal_ref_idc 0)."""
    w = W()
    w.ue(0)                      # first_mb_in_slice
    w.ue(5)                      # slice_type P (all slices)
    w.ue(pps["pps_id"])
    w.u(frame_num, sps["log2_max_frame_num"])
    if sps["poc_type"] == 0:
        w.u(poc_lsb, sps["log2_max_poc_lsb"])
    w.u(0, 1)                    # num_ref_idx_active_override_flag
    w.u(0, 1)                    # ref_pic_list_modification_flag_l0
    if pps["cabac"]:
        w.ue(0)                  # cabac_init_idc
    w.se(0)                      # slice_qp_delta
    if pps["deblocking_control"]:
        w.ue(1)                  # disable deblocking (nothing changes anyway)
    w.align_ones()               # cabac_alignment_one_bit
    return b"\x01" + escape(w.bytes() + data)


def slice_poc_field(nal, sps):
    """Bit offset (in the RBSP after the NAL header byte) and width of
    pic_order_cnt_lsb, plus frame_num and nal_ref_idc."""
    rb = unescape(nal[1:])
    r = R(rb)
    r.ue(); r.ue(); r.ue()
    fn = r.u(sps["log2_max_frame_num"])
    if nal[0] & 31 == 5:
        r.ue()
    pos = r.p
    poc = r.u(sps["log2_max_poc_lsb"])
    return rb, pos, sps["log2_max_poc_lsb"], fn, poc


def shift_poc(nal, sps, delta):
    rb, pos, width, fn, poc = slice_poc_field(nal, sps)
    newp = (poc + delta) % (1 << width)
    b = bytearray(rb)
    for i in range(width):
        bit = (newp >> (width - 1 - i)) & 1
        k = pos + i
        if bit:
            b[k >> 3] |= 0x80 >> (k & 7)
        else:
            b[k >> 3] &= ~(0x80 >> (k & 7)) & 0xFF
    return bytes([nal[0]]) + escape(bytes(b))


# ------------------------------------------------------------------ x264 -> iOS layout

def split_annexb(buf):
    i, starts = 0, []
    while True:
        j = buf.find(b"\x00\x00\x01", i)
        if j < 0:
            break
        starts.append(j + 3)
        i = j + 3
    out = []
    for k, s in enumerate(starts):
        e = starts[k + 1] - 3 if k + 1 < len(starts) else len(buf)
        n = buf[s:e]
        while n.endswith(b"\x00"):
            n = n[:-1]
        out.append(n)
    return out


def rewrite_sps_ios(nal):
    """Set log2_max_frame_num=12 and pic_order_cnt_type=0 with 13-bit lsb."""
    rb = unescape(nal[1:])
    d = parse_sps(nal)
    r = R(rb)
    w = W()
    for _ in range(d["prefix_end_before_fn"]):
        w.bits.append(r.u(1))
    w.ue(12 - 4)
    w.ue(0)
    w.ue(13 - 4)
    r.p = d["rest_bitpos"]
    # copy the rest up to (excluding) the rbsp trailing bits
    total = len(rb) * 8
    last1 = total - 1
    while ((rb[last1 >> 3] >> (7 - (last1 & 7))) & 1) == 0:
        last1 -= 1
    while r.p < last1:
        w.bits.append(r.u(1))
    w.trailing()
    return bytes([nal[0]]) + escape(w.bytes())


def convert_x264(nals):
    """Re-express a libx264 (bframes=0, POC type 2) stream in the iOS layout."""
    out, sps0, sps1, pps = [], None, None, None
    pic = 0
    for n in nals:
        t = n[0] & 31
        if t == 7:
            sps0 = parse_sps(n)
            n = rewrite_sps_ios(n)
            sps1 = parse_sps(n)
        elif t == 8:
            pps = parse_pps(n)
        elif t in (1, 5):
            f, rb, p = parse_slice_header(n, sps0, pps)
            if t == 5:
                pic = 0
            f["poc_lsb"] = (2 * pic) % (1 << 13)
            # every libx264 picture here is a reference picture, so frame_num is
            # simply the picture index since the IDR
            assert f["nal_ref_idc"] != 0
            f["frame_num"] = pic % (1 << 12)
            w = W()
            write_slice_header(w, f, sps1, pps)
            # original slice data starts after CABAC alignment ones
            while p % 8:
                p += 1
            w.align_ones()
            n = bytes([n[0]]) + escape(w.bytes() + rb[p // 8:])
            if f["first_mb"] == 0:
                pass
            pic += 1 if f["first_mb"] == 0 else 0
        out.append(n)
    return out


def to_annexb(nals):
    return b"".join(b"\x00\x00\x00\x01" + n for n in nals)


def frames_of(nals):
    """Group NALs into access units (SPS/PPS/SEI attach to the next picture)."""
    frames, cur = [], []
    for n in nals:
        t = n[0] & 31
        if t in (1, 5):
            if cur and any((x[0] & 31) in (1, 5) for x in cur) and parse_first_mb(n) == 0:
                frames.append(cur)
                cur = []
            cur.append(n)
        else:
            if cur and any((x[0] & 31) in (1, 5) for x in cur):
                frames.append(cur)
                cur = []
            cur.append(n)
    if cur:
        frames.append(cur)
    return frames


def parse_first_mb(n):
    return R(unescape(n[1:])).ue()


# ------------------------------------------------------------------ self test

def decode_md5s(path):
    out = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "framemd5", "-"], capture_output=True, text=True)
    md5s = [l.split(",")[-1].strip() for l in out.stdout.splitlines() if l and not l.startswith("#")]
    return md5s, out.stderr.strip()


def selftest():
    scr = os.path.join(HERE, "build")
    os.makedirs(scr, exist_ok=True)
    src = os.path.join(scr, "x264.h264")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=332x720:rate=30", "-t", "4",
                    "-c:v", "libx264", "-profile:v", "high", "-pix_fmt", "yuv420p",
                    "-x264-params", "bframes=0:ref=3:keyint=9999:scenecut=0:slices=1:weightp=0",
                    "-bsf:v", "h264_mp4toannexb", "-f", "h264", src], check=True)
    nals = split_annexb(open(src, "rb").read())
    conv = convert_x264(nals)
    ios = os.path.join(scr, "ios_like.h264")
    open(ios, "wb").write(to_annexb(conv))
    sps = parse_sps(next(n for n in conv if n[0] & 31 == 7))
    pps = parse_pps(next(n for n in conv if n[0] & 31 == 8))
    print("converted SPS:", {k: sps[k] for k in ("log2_max_frame_num", "poc_type", "log2_max_poc_lsb", "width_mbs", "height_mbs")},
          "PPS cabac:", pps["cabac"])
    ref, err = decode_md5s(src)
    got, err2 = decode_md5s(ios)
    assert ref == got, "conversion changed decoded pictures"
    assert not err2, err2
    print(f"conversion OK: {len(got)} frames decode identically, no decoder errors")

    # insert 3 skip frames after every 10th frame
    data = skip_slice_data(sps["width_mbs"] * sps["height_mbs"], pps["pic_init_qp"])
    print("skip slice data:", len(data), "bytes for", sps["width_mbs"] * sps["height_mbs"], "MBs:", data.hex())
    out, shift, last_ref_fn, last_poc, expect = [], 0, 0, 0, []
    for i, fr in enumerate(frames_of(conv)):
        new = []
        for n in fr:
            t = n[0] & 31
            if t in (1, 5):
                if t == 5:
                    shift = 0
                rb, pos, width, fn, poc = slice_poc_field(n, sps)
                n = shift_poc(n, sps, shift)
                last_poc = (poc + shift) % (1 << width)
                if (n[0] >> 5) & 3:
                    last_ref_fn = fn
            new.append(n)
        out += new
        expect.append(("real", i))
        if i % 10 == 9:
            for k in range(3):
                last_poc = (last_poc + 2) % (1 << sps["log2_max_poc_lsb"])
                shift += 2
                out.append(skip_nal(sps, pps, (last_ref_fn + 1) % (1 << sps["log2_max_frame_num"]), last_poc, data))
                expect.append(("skip", i))
    ins = os.path.join(scr, "with_skips.h264")
    open(ins, "wb").write(to_annexb(out))
    got2, err3 = decode_md5s(ins)
    assert not err3, err3
    assert len(got2) == len(expect), (len(got2), len(expect))
    for (kind, i), md in zip(expect, got2):
        assert md == ref[i], f"{kind} frame after real frame {i} differs"
    print(f"skip insertion OK: {len(got2)} frames ({expect.count(('skip', 0)) and sum(1 for e in expect if e[0]=='skip')} skip), "
          "every skip frame decodes to exactly the previous picture, real frames unchanged, no decoder errors")


if __name__ == "__main__":
    if sys.argv[1:] == ["selftest"]:
        selftest()
    else:
        print(__doc__)
