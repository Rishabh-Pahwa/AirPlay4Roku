#!/usr/bin/env python3
"""Extract the playfair (FairPlay) lookup tables from the RPiPlay C sources into
binary files under app/assets/fairplay/, for app/source/fairplay.brs.

Usage: tools/gen_fairplay_tables.py [--out DIR] [path/to/RPiPlay/lib]
       (defaults: ../RPiPlay/lib next to this repo, app/assets/fairplay)

Format (one file per C array, no header):
  *.bin           -- raw bytes, same order as the C initializer (multi-dim arrays
                     flattened row-major).
  table_s5..s9, md5_k -- uint32 values, 4 bytes each, LITTLE-endian.
  md5_shift, sap_i0_index -- small C int arrays, one byte per entry.
md5_k is not in the C source as a table: it is the expression
(int)(long long)((1LL << 32) * fabs(sin(i + 1))) from modified_md5.c, i = 0..63.
"""
import math, os, re, struct, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
args = sys.argv[1:]
OUT = os.path.join(ROOT, "app", "assets", "fairplay")
if args[:1] == ["--out"]:
    OUT, args = args[1], args[2:]
LIB = args[0] if args else os.path.join(os.path.dirname(ROOT), "RPiPlay", "lib")


def src(name):
    with open(os.path.join(LIB, name)) as f:
        return f.read()


def c_array(text, name):
    """Numbers in the initializer of `<type> name[..]... = { ... };` (flattened)."""
    m = re.search(r"\b%s\s*(\[[^\]]*\]\s*)+=\s*\{" % re.escape(name), text)
    if not m:
        raise SystemExit("array %s not found" % name)
    depth, i = 1, m.end()
    while depth:
        depth += {"{": 1, "}": -1}.get(text[i], 0)
        i += 1
    body = re.sub(r"/\*.*?\*/|//[^\n]*", "", text[m.end():i - 1], flags=re.S)
    return [int(tok, 0) for tok in re.findall(r"0[xX][0-9a-fA-F]+|\d+", body)]


# (source file, C array name, output file, element count, element width)
SPECS = [
    ("playfair/omg_hax.h", "message_key", "message_key", 4 * 144, 1),
    ("playfair/omg_hax.h", "message_iv", "message_iv", 4 * 16, 1),
    ("playfair/omg_hax.h", "z_key", "z_key", 16, 1),
    ("playfair/omg_hax.h", "x_key", "x_key", 16, 1),
    ("playfair/omg_hax.h", "t_key", "t_key", 16, 1),
    ("playfair/omg_hax.h", "table_s1", "table_s1", 40 * 256, 1),
    ("playfair/omg_hax.h", "table_s2", "table_s2", 144 * 256, 1),
    ("playfair/omg_hax.h", "table_s3", "table_s3", 16 * 256, 1),
    ("playfair/omg_hax.h", "table_s4", "table_s4", 144 * 256, 1),
    ("playfair/omg_hax.h", "table_s5", "table_s5", 256, 4),
    ("playfair/omg_hax.h", "table_s6", "table_s6", 256, 4),
    ("playfair/omg_hax.h", "table_s7", "table_s7", 256, 4),
    ("playfair/omg_hax.h", "table_s8", "table_s8", 256, 4),
    ("playfair/omg_hax.h", "table_s9", "table_s9", 4 * 256, 4),
    ("playfair/omg_hax.h", "table_s10", "table_s10", 16 * 256, 1),
    ("playfair/omg_hax.c", "index_mangle", "index_mangle", 11, 1),
    ("playfair/omg_hax.c", "initial_session_key", "initial_session_key", 16, 1),
    ("playfair/omg_hax.c", "static_source_1", "static_source_1", 17, 1),
    ("playfair/omg_hax.c", "static_source_2", "static_source_2", 47, 1),
    ("playfair/omg_hax.c", "default_sap", "default_sap", 276, 1),
    ("playfair/modified_md5.c", "shift", "md5_shift", 64, 1),
    ("playfair/sap_hash.c", "buffer0", "sap_buffer0", 20, 1),
    ("playfair/sap_hash.c", "buffer2", "sap_buffer2", 35, 1),
    ("playfair/sap_hash.c", "buffer4", "sap_buffer4", 21, 1),
    ("playfair/sap_hash.c", "i0_index", "sap_i0_index", 11, 1),
    ("fairplay_playfair.c", "reply_message", "fp_reply_message", 4 * 142, 1),
    ("fairplay_playfair.c", "fp_header", "fp_header", 12, 1),
]


def pack(vals, width):
    if width == 1:
        assert all(0 <= v <= 0xFF for v in vals)
        return bytes(vals)
    assert all(0 <= v <= 0xFFFFFFFF for v in vals)
    return b"".join(struct.pack("<I", v) for v in vals)


def main():
    os.makedirs(OUT, exist_ok=True)
    cache = {}
    for fname, cname, out, count, width in SPECS:
        text = cache.setdefault(fname, src(fname))
        vals = c_array(text, cname)
        if len(vals) != count:
            raise SystemExit("%s: expected %d values, got %d" % (cname, count, len(vals)))
        with open(os.path.join(OUT, out + ".bin"), "wb") as f:
            f.write(pack(vals, width))
    k = [int((1 << 32) * abs(math.sin(i + 1))) & 0xFFFFFFFF for i in range(64)]
    assert k[0] == 0xD76AA478 and k[63] == 0xEB86D391  # RFC 1321 T[1], T[64]
    with open(os.path.join(OUT, "md5_k.bin"), "wb") as f:
        f.write(pack(k, 4))
    print("wrote %d files to %s" % (len(SPECS) + 1, OUT))


if __name__ == "__main__":
    main()
