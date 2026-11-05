# Testing

Debugging on the device is slow. Every change needs a sideload, there is no try/catch, and a runtime error halts the Task in the debugger. So testing happens in three layers, with most bugs caught in the first.

## 1. Differential tests in the local interpreter

Each complex component has an independent reference implementation. A test runs the BrightScript in `brs-node` (Node 22) and compares its output byte for byte with the reference.

| Command | What it checks |
|---|---|
| `python3 -I test/crypto/run.py 3` | X25519 and Ed25519 against `pyca/cryptography`: keys, shared secrets, signatures. `NO_RUN=1` only writes `test_main.brs` for running on the device. |
| `python3 -I test/plist/run.py` | The binary plist reader and writer against Python's `plistlib`, including 64-bit integers and nested containers |
| `python3 -I test/fmp4/run.py` | `fmp4.brs` output against `test/fmp4_proto.py` |
| `python3 -I test/h264/h264tool.py selftest` | The Python skip-frame reference against **ffmpeg**: every generated frame decodes to exactly the previous picture, and POC-shifted real frames decode unchanged |
| `python3 -I test/h264/run_brs.py` | `h264.brs` output against `h264tool.py` |
| `test/fairplay/run.sh [N] [SEED]` | The playfair port against the original C, built from `../RPiPlay` into a harness, on N random inputs |

Because no code relies on Integer overflow ([design-decisions.md](design-decisions.md) #17), passing locally means the device gives the same results.

Compile-checking all receiver sources together is described in `CLAUDE.md` (a lint `Main` that prints `COMPILED_OK`).

## 2. On-device end to end with the fake sender

`test/fake_sender.py` is a complete AirPlay client written for this project. It performs:
- mDNS discovery (legacy unicast);
- `/info`;
- pair-setup and pair-verify, **verifying the Roku's Ed25519 signature**;
- fp-setup;
- SETUP with stream keys;
- encrypted mirror and ALAC streams.

The one thing it can't do is produce a real FairPlay `ekey`, so the channel has to be launched in test mode, which accepts a plaintext `testAesKey`:

```sh
curl -d '' "http://ROKU:8060/launch/dev?testmode=1"
python3 -I test/fake_sender.py ROKU discover|info|pair|mirror|audio|all [seconds]
```

| Environment variable | Effect |
|---|---|
| `MIRROR_RATE=2M` | Encode bitrate of the test video |
| `MIRROR_NOISE=25` | Noise added to the source so the encoder can't compress it away (stress test) |
| `MIRROR_JITTER=1` | iPhone-like pacing: bursts plus random still-screen pauses of up to 1.5 s |
| `MIRROR_JITTER=2` | Same, with pauses of up to 2.5 s |
| `MIRROR_JITTER=3` | Steady 30 fps with an exact 0.8 s pause every 6 s (reproducible) |
| `MIRROR_ROTATE=1` | Switch to a portrait stream halfway through, to test format changes |
| `VIDEO_FMT=hls` / `VIDEO_URL=<url>` / `VIDEO_END=1` | `video` mode: serve an HLS copy of the test clip, play any URL instead, or let the clip finish |
| `MIRROR_IOS_LAYOUT=1` (default) | Re-encode and renumber to match iOS's stream: High profile, CABAC, POC type 0, `frame_num` behaviour, no weighted prediction |

Test-mode launch parameters:

| Parameter | Effect |
|---|---|
| `hlstarget=<ms>` | Override the 1800 ms steering target |
| `nofeedback=1` | Don't observe player position, so steering is off (measures the raw player) |
| `noplayer=1` | Don't start the Video node (shows whether a freeze comes from the player) |

`video` mode needs no test mode, because URL playback doesn't use the FairPlay key. It serves a generated 40 s H.264 + AAC clip from this computer, sends `/play`, then pauses, resumes and seeks, polling `/playback-info` and printing the events received on the reverse channel. It ends with PASS/FAIL checks and the Roku's own ECP `query/media-player` report, which names the audio and video codecs the player is decoding.

Typical stress run:

```sh
MIRROR_RATE=1500k MIRROR_JITTER=1 MIRROR_ROTATE=1 python3 -I test/fake_sender.py ROKU mirror 80
curl -s http://ROKU:8888/log | grep -E "player buffering|hls depth|slow|stats 10s|format change"
```

### Inspecting the live output

While a session runs:
- `http://ROKU:8888/hls/current/live.m3u8` and its segments can be fetched.
- `test/h264/capture_hls.py` saves the live HLS for checking with `ffprobe`/`ffmpeg`, for example that there are no decode errors and that skip frames repeat the picture.
- `http://ROKU:8888/audio/current.mka` can be recorded and decoded.

## 3. Real-device testing with an iPhone

The only test that covers the real FairPlay key with a real stream. What to try:
- the home screen and Control Centre (mostly still);
- Photos (still images with sudden changes);
- a scrolling feed with landscape video, such as Reddit (format changes);
- Spotify or Apple Music (the audio path, mute).

Afterwards, read `/log`.

## Reading `/log`

| Line | Meaning |
|---|---|
| `rtsp connection from <ip>`, `pair-verify step 1 computed in N ms`, `fairplay decrypt ...`, `session from <name> model=...`, `mirror stream set up`, `audio stream ct=...` | Session progress and timings |
| `hls depth N ms -> rate S%` | Steering: depth behind the live edge and the current duration scale. Should settle near 1800 ms and 100 %. |
| `player buffering` | **A stall**. This is the number to drive to zero. |
| `player playing` | Playback (re)started |
| `format change -> WxH (discontinuity, player kept)` | Rotation or a new layout handled seamlessly |
| `skip frames ready (N MBs, cabac=1) in T ms` | Skip-frame support initialised for this codec config |
| `skip frames: unsupported stream layout ...` | Falling back to stretching held frames |
| `hls gap N ms -> holding frame` | The fallback path covering a sender gap |
| `slow wait / slow event <kind> / slow timers N ms` | The loop was blocked for more than 300 ms. Correlate with `player buffering` (the player starving the Task) and look for any other cause. |
| `stats 10s: video frames=… skip=… bytes=… audio pkts=…` | Throughput over the last 10 s, including skip frames inserted |
| `gc N ms orphaned=…` | A garbage collection that took over 50 ms |
| `unhandled <method> <path>` | A request the receiver doesn't implement (404) |
