#!/usr/bin/env python3
"""Decode SPS/PPS from an avcC hex string (as logged by the receiver)."""
import sys

class Bits:
    def __init__(self, b):
        # strip emulation prevention bytes
        out, z = bytearray(), 0
        for x in b:
            if z >= 2 and x == 3:
                z = 0
                continue
            out.append(x)
            z = z + 1 if x == 0 else 0
        self.b, self.p = bytes(out), 0
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

def sps(b):
    r = Bits(b[1:])
    d = {"profile": r.u(8), "constraints": r.u(8), "level": r.u(8), "sps_id": r.ue()}
    if d["profile"] in (100, 110, 122, 244, 44, 83, 86, 118, 128):
        d["chroma_format_idc"] = r.ue()
        d["bit_depth_luma"] = r.ue() + 8
        d["bit_depth_chroma"] = r.ue() + 8
        d["qpprime_y_zero"] = r.u(1)
        d["seq_scaling_matrix_present"] = r.u(1)
    d["log2_max_frame_num"] = r.ue() + 4
    d["poc_type"] = r.ue()
    if d["poc_type"] == 0:
        d["log2_max_poc_lsb"] = r.ue() + 4
    elif d["poc_type"] == 1:
        d["delta_pic_order_always_zero"] = r.u(1)
    d["max_num_ref_frames"] = r.ue()
    d["gaps_in_frame_num_allowed"] = r.u(1)
    d["width_mbs"] = r.ue() + 1
    d["height_map_units"] = r.ue() + 1
    d["frame_mbs_only"] = r.u(1)
    if not d["frame_mbs_only"]:
        d["mb_adaptive"] = r.u(1)
    d["direct_8x8"] = r.u(1)
    d["cropping"] = r.u(1)
    if d["cropping"]:
        d["crop"] = [r.ue() for _ in range(4)]
    d["vui_present"] = r.u(1)
    if d["vui_present"]:
        v = {}
        if r.u(1):
            ar = r.u(8)
            v["aspect"] = ar
            if ar == 255:
                r.u(16); r.u(16)
        if r.u(1):
            v["overscan_appropriate"] = r.u(1)
        if r.u(1):
            v["video_format"] = r.u(3); v["full_range"] = r.u(1)
            if r.u(1):
                r.u(8); r.u(8); r.u(8)
        if r.u(1):
            r.ue(); r.ue()
        if r.u(1):
            v["num_units_in_tick"] = r.u(32); v["time_scale"] = r.u(32); v["fixed_frame_rate"] = r.u(1)
        nal_hrd = r.u(1)
        v["nal_hrd"] = nal_hrd
        if nal_hrd:
            v["hrd"] = "present (not parsed further)"
        else:
            vcl = r.u(1)
            v["vcl_hrd"] = vcl
            if not vcl:
                v["pic_struct_present"] = r.u(1)
                v["bitstream_restriction"] = r.u(1)
                if v["bitstream_restriction"]:
                    v["mv_over_pic_boundaries"] = r.u(1)
                    v["max_bytes_per_pic_denom"] = r.ue()
                    v["max_bits_per_mb_denom"] = r.ue()
                    v["log2_max_mv_length_h"] = r.ue()
                    v["log2_max_mv_length_v"] = r.ue()
                    v["max_num_reorder_frames"] = r.ue()
                    v["max_dec_frame_buffering"] = r.ue()
        d["vui"] = v
    return d

def pps(b):
    r = Bits(b[1:])
    d = {"pps_id": r.ue(), "sps_id": r.ue(), "entropy_coding_mode (1=CABAC)": r.u(1),
         "bottom_field_pic_order_in_frame_present": r.u(1)}
    d["num_slice_groups"] = r.ue() + 1
    d["num_ref_idx_l0_default"] = r.ue() + 1
    d["num_ref_idx_l1_default"] = r.ue() + 1
    d["weighted_pred"] = r.u(1)
    d["weighted_bipred_idc"] = r.u(2)
    d["pic_init_qp"] = 26 + r.se()
    d["pic_init_qs"] = 26 + r.se()
    d["chroma_qp_index_offset"] = r.se()
    d["deblocking_filter_control_present"] = r.u(1)
    d["constrained_intra_pred"] = r.u(1)
    d["redundant_pic_cnt_present"] = r.u(1)
    return d

def avcc(h):
    b = bytes.fromhex(h)
    n = b[5] & 31
    o = 6
    out = {}
    for _ in range(n):
        l = int.from_bytes(b[o:o + 2], "big"); out["sps"] = sps(b[o + 2:o + 2 + l]); o += 2 + l
    n = b[o]; o += 1
    for _ in range(n):
        l = int.from_bytes(b[o:o + 2], "big"); out["pps"] = pps(b[o + 2:o + 2 + l]); o += 2 + l
    return out

if __name__ == "__main__":
    import json
    print(json.dumps(avcc(sys.argv[1]), indent=1))
