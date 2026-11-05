# AirPlay receiver for Roku 2 XS (BrightScript)

An AirPlay screen-mirroring and audio receiver that runs entirely on a Roku
2 XS (model 3100X, Roku OS 9.1), written in BrightScript. No companion device
or server: discovery, pairing, FairPlay key exchange, decryption, muxing and
playback all happen on the Roku.

Architecture and protocol handling are adapted from
[UxPlay](../UxPlay), [RPiPlay](../RPiPlay), [PhairPlay](../PhairPlay) and the
[airplay-spec](https://openairplay.github.io/airplay-spec/).

## What works

| Feature | Status |
|---|---|
| Shows up in Screen Mirroring / AirPlay lists (mDNS `_airplay._tcp` + `_raop._tcp`) | yes |
| `/info`, legacy pairing (pair-setup / pair-verify, X25519 + Ed25519) | yes, ~2.1 s on device |
| FairPlay fp-setup + `ekey` decryption (playfair port) | see `test/fairplay` |
| Screen mirroring (H.264, AES-CTR) at 1280x720 / 30 fps | yes, ~2 s behind the phone |
| AirPlay music (ALAC over RTP/UDP, AES-CBC) | yes |
| Volume from the iPhone/Mac | mute only: the bottom of the slider (or mute) silences the Roku. The Roku OS 9.1 Audio node has a `mute` field but no volume control, and this model has no volume output of its own, so use the TV's volume |
| Audio while mirroring (AAC-ELD) | **no**: the Roku 2 XS has no AAC-ELD decoder and BrightScript is far too slow to decode it, so mirroring is video-only |
| AirPlay video (the sender passes a video URL; the Roku plays it itself, with sound) | implemented but **off by default** (`app/source/video.brs`, enable with launch param `urlvideo=1`): plays MP4/HLS/HTTPS links with sound from a test sender, but iOS 18 requires an unreversed FairPlay step (`/fp-setup2`) before it sends any link, so iPhones never use it |
| YouTube app AirPlay (sender-provided HLS playlists) | not yet (planned, following UxPlay's `-hls`) |
| Multiple simultaneous senders | no (one session at a time, like UxPlay) |

Mirroring runs about 2 s behind the phone. How that's achieved on a player
that wasn't built for it (measurements in `test/latency/` and the receiver log):

* **Live HLS of 0.4 s fMP4 segments**, cut by time (iOS sends one IDR).
  Progressive MKV needed 15-20 s on a still iPhone screen because the Roku
  player waits for ~450 KB *and* ~5 s of media.
* **Parked requests**: the playlist advertises the next two segments before
  they exist; the player requests them at once and the receiver answers each
  the moment it closes. The Roku reloads live playlists only once a second,
  which otherwise adds up to 1 s of hidden delay.
* **Rate steering**: the player always starts ~3.4 s behind. At every segment
  close the receiver compares the newest media time with the player's position
  and scales frame durations proportionally (75-115%), so the picture briefly
  runs up to 1.33x fast until it is ~1.8 s behind, then holds there. Holding
  depth steady matters more than minimising it: the Roku rebuffers once its
  buffer dips below ~1 s, even briefly.
* **Skip frames for still screens**: while the iPhone screen is still, iOS
  sends no video frames at all (it repeats the codec config ~30x/s instead),
  which used to run the player dry. When no frame has arrived for 100 ms the
  receiver inserts a generated picture that repeats the previous one: a
  non-reference P slice in which every macroblock is P_Skip (for the iOS
  stream, 945 macroblocks of CABAC that encode to 7 bytes, computed once per
  codec config). Later real frames get their `pic_order_cnt_lsb` shifted in
  place so display order stays increasing (`app/source/h264.brs`; reference
  implementation and ffmpeg verification in `test/h264/h264tool.py`). Streams
  it can't handle fall back to stretching the last frame.
* **Never block the receiver thread**: player position/state arrive as port
  events (reading Task fields is a blocking rendezvous with the UI thread),
  and console `print` is opt-in (a stale 8085 console session makes every
  print block for seconds). Logs go to a ring buffer at
  `http://ROKU_IP:8888/log`. One remaining stall source is outside our
  control: during a rebuffer the Roku's own video player can starve the
  receiver thread for ~5 s (never seen with the player off).

Rotating the phone, a landscape video, or an app with a different shape sends
a new codec configuration. The player is kept: segments already promised to
it are finished in the old format with skip frames, then an
`EXT-X-DISCONTINUITY` and a new init segment start at the next IDR.
(Restarting the player instead cost 4-7 s of black screen per change.)

## How it works on a Roku

The Roku can't take a raw H.264/ALAC elementary stream, and BrightScript costs
about 3 µs per byte touched in a loop, so the design keeps all media bytes in
native code:

```
iPhone/Mac ──TCP 7000── RTSP/HTTP control  (receiver.brs: info, pairing, fp-setup, SETUP...)
           ──TCP 7100── mirror stream ─ AES-CTR ─ fmp4.brs: 0.4 s fMP4 segments ─ live HLS ─┐
           ──UDP 6002── ALAC RTP      ─ AES-CBC ─ mkv.brs: live Matroska ──────────────────┤
           ──UDP 6010── NTP timing                                                       │
           ──UDP 5353── mDNS (mdns.brs)                                                  ▼
                                           HTTP :8888 (localhost) ──> Roku Video / Audio node
```

* **No per-byte work on media**: AirPlay mirror payloads are already AVCC
  (length-prefixed NALs) and the codec-config packet is an avcC record, which is
  what both fMP4 (`avc1`/`avcC`) and Matroska (`V_MPEG4/ISO/AVC`) want. Video
  goes into fMP4 segments (moof + mdat) and ALAC audio into live Matroska,
  both built from small headers plus `roByteArray.Append`. MPEG-TS would need
  per-188-byte packetisation, which is far too slow here. Segments are cut by
  time, not keyframes, because iOS sends a single IDR.
* **Crypto in 32-bit Integers**: on this CPU, BrightScript LongInteger/Double
  are 20-30x slower than Integer, so GF(2^255-19) uses 20 limbs x 13 bits with
  unrolled, generated code (`tools/gen_fe25519.py`), arranged so no intermediate
  ever exceeds 2^31 or goes negative (`>>` is logical on the device). Ed25519
  fixed-base multiplication uses a precomputed table of 2^i*B, and the signing
  nonce + ephemeral X25519 key are precomputed while idle, so pair-verify costs
  one X25519 (~1.9 s) plus a cheap signature.
* **Fast byte slicing**: `roByteArray` has no slice, so `ba_slice` goes through
  native base64 and string `Mid`.

## Files

```
app/                    the Roku channel
  source/receiver.brs   receiver core: sockets, RTSP handlers, mirror/audio pipelines, local media server
  source/mdns.brs       mDNS / DNS-SD responder
  source/plist.brs      binary plist reader/writer
  source/fe25519.brs    GENERATED field arithmetic (tools/gen_fe25519.py)
  source/curve25519.brs X25519, Ed25519 signing, scalar mod L
  source/fairplay.brs   playfair (FairPlay) port; tables in assets/fairplay/
  source/fmp4.brs       fragmented-MP4 writer for live HLS (mirroring)
  source/h264.brs       skip-frame generation and POC rewriting
  source/mkv.brs        live Matroska muxer (audio)
  components/           SceneGraph UI (MainScene) and the Receiver task
tools/                  deploy.sh, console.sh, table/code generators, local BrightScript interpreter
test/                   crypto/plist/fairplay differential tests, fake_sender.py, prototypes
spike/, spike2/         device feasibility probes (kept for reference)
```

## Install / remove (reversible)

Developer mode must be enabled on the Roku (Home x3, Up x2, Right, Left,
Right, Left, Right). Then:

```sh
export ROKU_DEV_PASS=...            # the developer installer password
tools/deploy.sh app                 # sideload (replaces only the single "dev" channel slot)
tools/console.sh 60                 # watch the BrightScript debug console
tools/deploy.sh --delete            # remove the channel again
```

Sideloading doesn't touch any installed store channels. Settings live in the
channel's own registry section `airplay` (an Ed25519 identity seed and a random
device ID), which is deleted along with the channel. Optional registry keys:
`name` (advertised name) and `nopair` (turn off feature bit 27 so clients skip
pairing, as UxPlay can).

The receiver only runs while the channel is open on screen; Roku channels can't
run in the background.

## Tests

```sh
python3 -I test/crypto/run.py 3     # X25519/Ed25519 vs pyca/cryptography (local interpreter)
python3 -I test/plist/run.py        # bplist reader/writer vs plistlib
python3 -I test/fmp4/run.py         # fmp4.brs byte-identical to test/fmp4_proto.py
python3 -I test/h264/h264tool.py selftest   # skip frames decode to the previous picture (ffmpeg)
python3 -I test/h264/run_brs.py     # h264.brs byte-identical to h264tool.py
test/fairplay/run.sh                # playfair port vs the original C
# on the device, with the channel launched in test mode:
curl -d '' "http://ROKU_IP:8060/launch/dev?testmode=1"
python3 -I test/fake_sender.py ROKU_IP all 20
MIRROR_RATE=6M MIRROR_NOISE=25 python3 -I test/fake_sender.py ROKU_IP mirror 30
# iPhone-like pacing (bursts + still-screen pauses), optional rotation:
MIRROR_RATE=1500k MIRROR_JITTER=1 MIRROR_ROTATE=1 python3 -I test/fake_sender.py ROKU_IP mirror 80
curl http://ROKU_IP:8888/log         # receiver log: stalls, depth steering, sender gaps
```

`fake_sender.py` is a complete AirPlay client (discovery, info, pairing with
signature verification, fp-setup, SETUP, encrypted mirror + ALAC streams). A
sender can't produce a real FairPlay-encrypted `ekey`, so in test mode only
the receiver accepts a plaintext `testAesKey` in SETUP. Test mode is off unless
the channel is launched with `testmode=1` (extra test-only launch params:
`hlstarget=<ms>`, `nofeedback=1`, `noplayer=1`). While a session runs, the live
streams can be pulled for inspection at `http://ROKU_IP:8888/hls/current/live.m3u8`
and `/audio/current.mka`.
