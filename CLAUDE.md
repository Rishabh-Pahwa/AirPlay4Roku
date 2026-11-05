# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

AirPlay4Roku: an AirPlay screen-mirroring and music receiver written in BrightScript that runs entirely on a Roku 2 XS (model 3100X, Roku OS 9.1). No companion device. Protocol handling is adapted from UxPlay, RPiPlay, PhairPlay (sibling directories `../UxPlay`, `../RPiPlay`, `../PhairPlay`) and the airplay-spec. `README.md` has the feature status, design rationale and measurements; read it before changing the media pipeline.

## Commands

Device: the Roku is at `192.168.1.16` (override with `ROKU_IP`). Sideloading needs developer mode and the installer password in `ROKU_DEV_PASS` (user `rokudev`). Ask the user for it rather than guessing.

```sh
tools/deploy.sh app                  # zip + sideload app/ (only replaces the single "dev" channel slot; auto-launches)
tools/deploy.sh --delete             # remove the dev channel
curl -d '' "http://192.168.1.16:8060/launch/dev?testmode=1"   # relaunch in test mode (needed for fake_sender)
curl -d '' "http://192.168.1.16:8060/launch/dev?debuglog=1"     # make /log readable from the network (remembered; debuglog=0 turns it off)
curl http://192.168.1.16:8888/log    # receiver log ring buffer (2000 lines) - primary debugging channel; 403 unless debuglog or testmode
tools/console.sh 60                  # BrightScript debug console (port 8085); see caveats below
```

Local BrightScript interpreter (brs-node; Node 18 does NOT work, use Node 22). `pkg:` paths resolve against `--root`, and file arguments must be relative to that root (absolute paths fail with "Invalid or inexistent file(s)"):

```sh
~/.nvm/versions/node/v22.23.3/bin/node tools/node/node_modules/brs-node/bin/brs.cli.js --root <dir> source/a.brs source/b.brs
cd tools/node && npm install         # if node_modules is missing (it is gitignored)
```

Compile check of the receiver sources (there is no lint script; this is the established way):

```sh
T=test/build/lint; rm -rf $T; mkdir -p $T/source
for f in util plist fe25519 curve25519 fairplay mdns mkv fmp4 h264 video receiver; do cp app/source/$f.brs $T/source/; done
printf 'sub Main()\n print "COMPILED_OK"\nend sub\n' > $T/source/lintmain.brs
(cd $T && ~/.nvm/versions/node/v22.23.3/bin/node ../../../tools/node/node_modules/brs-node/bin/brs.cli.js --root . source/lintmain.brs $(cd source && ls *.brs | grep -v lintmain | sed 's|^|source/|'))
```

Tests are differential (BrightScript in the local interpreter vs a Python/C reference). Each is run on its own:

```sh
python3 -I test/crypto/run.py 3      # X25519 / Ed25519 vs pyca/cryptography (NO_RUN=1 only writes test_main.brs for the device)
python3 -I test/plist/run.py         # bplist reader/writer vs plistlib
python3 -I test/fmp4/run.py          # fmp4.brs byte-identical to test/fmp4_proto.py
python3 -I test/h264/h264tool.py selftest   # skip frames decode to the previous picture (ffmpeg)
python3 -I test/h264/run_brs.py      # h264.brs byte-identical to h264tool.py
test/fairplay/run.sh [N] [SEED]      # playfair port vs the original C (builds harness from ../RPiPlay)
```

On-device end-to-end with the fake sender (channel launched with `testmode=1`):

```sh
python3 -I test/fake_sender.py 192.168.1.16 discover|info|pair|mirror|audio|all|video [seconds]
MIRROR_RATE=1500k MIRROR_JITTER=1 MIRROR_ROTATE=1 python3 -I test/fake_sender.py 192.168.1.16 mirror 80
```

`video` tests AirPlay video-URL playback and needs no test mode (it serves a generated H.264+AAC clip from this machine; `VIDEO_FMT=hls`, `VIDEO_URL=<url>`, `VIDEO_END=1` to let it finish) and prints PASS/FAIL checks plus the Roku's ECP `query/media-player` report (shows the audio/video codecs the player decodes). `MIRROR_JITTER=1|2|3` gives iPhone-like bursty pacing with still-screen pauses, and `MIRROR_ROTATE=1` switches to a portrait stream halfway through. Test-mode launch params: `hlstarget=<ms>`, `nofeedback=1`, `noplayer=1`. While a session runs, `http://ROKU:8888/hls/current/live.m3u8` and `/audio/current.mka` can be pulled for inspection, and `test/h264/capture_hls.py` saves the live HLS for ffmpeg checks. Judge mirroring changes by the `/log` lines `player buffering` (stalls), `hls depth ... -> rate`, `slow wait` and `stats 10s`.

Generators (outputs are committed): `tools/gen_fe25519.py` writes `app/source/fe25519.brs` and self-checks its overflow bounds, `tools/gen_ed25519_table.py` writes `app/assets/ed25519_base.bin`, `tools/gen_fairplay_tables.py` writes `app/assets/fairplay/`, and `tools/gen_icons.py` writes `app/images/`. Never hand-edit `fe25519.brs`.

## Architecture

`app/` is the channel. `MainScene` (render thread) holds the UI plus a `Video` node and an `Audio` node. The `Receiver` Task runs `rx_main` in `source/receiver.brs`, a single event loop (`wait(40, port)`) over every socket:

- **Control, :7000 TCP.** RTSP/HTTP: `/info`, `pair-setup`/`pair-verify` (legacy transient pairing: X25519 + Ed25519, `curve25519.brs`), `fp-setup` (FairPlay, `fairplay.brs` = playfair port), `SETUP`/`RECORD`/`TEARDOWN`. The AES key is `FairPlay_Decrypt(ekey)`, hashed with the ECDH secret when pairing happened. Stream keys come from `sha512("AirPlayStreamKey"+streamConnectionID ‖ key)`, as in UxPlay.
- **Mirror, :7100 TCP.** Packets are a 128-byte header plus payload. Type 0 is AES-CTR video in AVCC form (one continuous keystream across packets); type 1 is an unencrypted avcC codec config.
- **Audio, :6002/:6003 UDP.** RTP ALAC, with AES-CBC applied per packet over whole 16-byte blocks only.
- **Other sockets.** NTP client on :6010, mDNS responder on :5353 (`mdns.brs`).
- **Local media server, :8888.** It feeds the Roku player, which can only take container formats over HTTP. It also serves `/log`. Access control in `http_serve`: streams only to `127.0.0.1` (the Roku's own players) unless test mode; `/log` only with registry `debuglog` (launch param `debuglog=1`) or test mode; everything else gets 403 and a `refused` log line. Leave `debuglog` off when done: the log names the user's devices and what they played.

The media pipelines keep bytes out of BrightScript loops: decryption is `roEVPCipher`, and muxing is small headers plus `roByteArray.Append`.

- **Mirroring becomes live HLS of 0.4 s fMP4 segments** (`fmp4.brs`), cut by time, not keyframes, because iOS sends one IDR. Things that interact (all in `receiver.brs`, `hls_*` / `mux_video_*`):
  - **Parked requests.** The playlist advertises the next two segments before they exist, and requests for them are held until each closes. This removes the Roku's once-per-second playlist reload from the delay.
  - **Rate steering.** `hls_steer` reads the player position (pushed by the scene as port events) and scales sample durations by 75–115% to hold about 1.8 s behind live. The Roku player starts about 3.4 s behind and rebuffers if its buffer dips below about 1 s.
  - **Skip frames.** `h264.brs` handles still screens, when iOS sends no frames and repeats the codec config about 30 times a second. After 100 ms without a frame it inserts a non-reference all-P_Skip slice (CABAC payload computed once per config) and shifts `pic_order_cnt_lsb` of later real frames in place. The newest unit is always held back one step (`vs.pend`) so its duration is known.
  - **Format changes.** Rotation or a resolution change does not restart the player. The promised segments are finished in the old format, then come `EXT-X-DISCONTINUITY` and a new `initN.mp4` at the next IDR (`hls_switch_format`).
- **AirPlay video (URL playback)** is `source/video.brs`, reached from `rtsp_handle` via `vid_handle`. HTTP/1.1 requests on :7000: `/server-info`, `/play` (bplist `Content-Location`), `/rate`, `/scrub`, `/stop`, `/playback-info` (polled by the sender), `/setProperty`. `POST /reverse` upgrades a second connection to PTTH; state events go to the sender over it as `POST /event`. The scene plays the URL on the same Video node as mirroring (`videoCmd` field task -> scene; `m.mode` in MainScene says who owns the node), so starting one stops the other. Only direct http(s) locations are handled; YouTube's FCUP/`/action` flow (see `../UxPlay/lib/http_handlers.h`) is not. Feature bits 0 + 4 (video, HLS) are **off by default**: iOS 18 demands `POST /fp-setup2` (an unreversed FairPlay variant, answered 421 as UxPlay does) before every `/play`, never sends the URL, and shows "playing" while nothing plays. Launch with `urlvideo=1` (stored in registry key `urlvideo`; `urlvideo=0` clears it) to advertise them for testing.
- **Music goes into live Matroska** (`mkv.brs`, unknown-size Segment and Clusters, A_ALAC), served to the `Audio` node. Mirroring audio (AAC-ELD, ct=8) is not playable on this hardware and is ignored. Volume control is mute only: the Audio node has no volume field.

`spike*/` are standalone feasibility probes kept for reference. `test/latency/gen.py` generates spike3's media.

## Device and BrightScript constraints (learned the hard way)

- **Integer arithmetic.** Integer is 32-bit and wraps on the device, but the local interpreter does not wrap, so never rely on overflow. `>>` is a logical shift, even on negatives. There is no xor (use `(a or b) - (a and b)`).
- **Speed.** LongInteger and Double are about 20–30× slower than Integer. Hot math must be Integer (that is why fe25519 uses 20 × 13-bit limbs).
- **64-bit values.** Mixing `and`/`or` between LongInteger and Integer truncates to 32 bits. Use `* 256&`, `\` and `mod` for 64-bit values; `/` produces a float and loses precision.
- **Per-byte loops** cost about 3 µs per byte. Slice byte arrays with `ba_slice` (native base64 + `Mid`).
- **Reserved words** that have bitten: `log`, `tab`, `pos`, `as`, `next` (also `run`, `stop`, `line_num`, etc.).
- **Associative arrays** have case-insensitive keys (`{r:..., R:...}` is one key). The plist writer therefore uses ordered `pl_dict`/`pl_set`. Comparing AAs with `=` is a runtime error.
- **Missing features.** There is no try/catch on OS 9.1; a runtime error halts the Task in the debugger (port 8085) and `/log` stops answering. Avoid `FindMemberFunction` and `String.Replace` (use `Split().Join()`).
- **Never block the Receiver thread.** Reading `m.top.*` or `m.global.*` from the Task is a blocking rendezvous with the UI thread, so observe fields into the port instead (`playerPos`, `playerState`, `quit`). Console `print` is opt-in (registry key `console`) because a stale 8085 session that stops reading makes every print block for seconds. The 8085 console accepts one client and can stay "in use" after a client dies.
- **Player-caused freezes.** During a rebuffer the Roku video player itself can starve the Task for about 5 s (`slow wait` in the log); this was never seen with the player off. Prevent stalls instead of trying to recover from them.
- **Test mode.** `testmode=1` lets the fake sender pass a plaintext `testAesKey` in SETUP, since FairPlay can't be emulated client-side. Keep that path test-only.
