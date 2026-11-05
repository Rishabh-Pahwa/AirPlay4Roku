# Development history: problems and fixes

This records the problems in the order they were found, and how each was solved. The git history has only four snapshots: `beta-version`, then skip frames and format changes, then the `.gitignore` cleanup, then the rename and artwork. So most of the stages below are not separate commits.

---

## Stage 0: finding and reaching the Roku

| Problem | Fix |
|---|---|
| Where is the device? | SSDP discovery (`roku:ecp`) found a Roku 2 XS 3100X at `192.168.1.16`, OS 9.1.0. ECP `query/device-info` confirmed the model. |
| The developer installer rejected the password (401). The Developer Settings key sequence sent over ECP didn't open the screen. A reset to a password with a `^` still failed, and the uptime showed the device hadn't rebooted, so the reset had not happened. | The user reset developer mode on the physical remote and set a plain password. `tools/deploy.sh` reads it from `ROKU_DEV_PASS`. Password variants are never guessed. |

## Stage 1: feasibility spikes (`spike/`, `spike2/`, `spike3/`)

Before writing the receiver, small probe channels answered the questions everything else depended on:
- Can a channel listen on 7000 and 7100 and join mDNS multicast? **Yes.**
- Do `roEVPCipher` (AES-CTR/CBC) and `roEVPDigest` (SHA-512) behave like OpenSSL? **Yes.**
- How fast is 64-bit arithmetic? **Very slow** (see Stage 3).
- Can the players play from an HTTP server inside the same channel? **Yes**, at `127.0.0.1`.
- Which audio containers carry ALAC? **Matroska works** (`spike2`).
- What does the HLS player's latency look like? **About 3.4 s at start, then steerable** (`spike3`, media from `test/latency/gen.py`).

| Problem | Fix |
|---|---|
| ffmpeg ignores `frame_size=352` for ALAC, so no realistic test files could be made | Wrote ALAC "escape" (uncompressed) frames by hand, in `spike2` and `fake_sender.py` |
| A spike crashed on index −1 in a step callback, and an `isHls` name check was wrong | Fixed in the spike. These were test-harness bugs, not platform behaviour. |

## Stage 2: protocol core (mDNS, `/info`, plist, RTSP)

| Problem | Fix |
|---|---|
| Compile errors and crashes from identifiers that are reserved or built-in in BrightScript: `log`, `tab`, `pos`, `as`, `next` | Renamed everywhere. The list is kept in `CLAUDE.md` and [platform-notes.md](platform-notes.md). |
| Binary plist integers above 2^31 came out wrong | `or` between a LongInteger and an Integer truncates to 32 bits. 64-bit values are now built with `* 256&` and added. |
| `streamConnectionID` (an unsigned 64-bit value, often above 2^63) printed wrongly, so the stream keys were wrong | `/` goes through a float. `u64_str` uses `\` and `mod` with the sign bit handled. |
| The plist writer needed stable key order and distinct keys | AAs are case-insensitive and unordered, so the writer uses `pl_dict`/`pl_set` ordered lists. |

## Stage 3: making pairing fast enough

| Problem | Fix |
|---|---|
| A straightforward field implementation used LongInteger and was estimated at **~25 s per pair-verify**, far beyond iOS's timeout. | 20 × 13-bit limbs in plain Integers, generated and fully unrolled by `tools/gen_fe25519.py`, with proven bounds below 2^31. |
| Negative intermediates are corrupted by logical `>>` | Subtraction adds a large multiple of p (`SUBP`), so limbs never go negative. |
| Tests passed locally but couldn't be trusted to match the device, which wraps Integers while the emulator doesn't | Designed so nothing ever overflows. The results are then identical by construction. |
| Ed25519 signatures failed verification | The nonce record had fields `r` and `R`, and AA keys are case-insensitive, so one overwrote the other. They were renamed `scalar` and `point`. |
| X25519 plus nonce generation still took about 4 s | Ed25519 fixed-base table (`2^i·B`, niels form), X25519 public keys through the Edwards map, a **randomized Ed25519 nonce**, and an idle precompute pool. **Result: ~2.1 s.** |
| Node 18 couldn't run the local interpreter, and absolute paths failed | Use Node 22, and give paths relative to `--root`. |

## Stage 4: FairPlay

| Problem | Fix |
|---|---|
| playfair is about 180 KB of C tables and uint32 arithmetic | The tables are extracted to binary assets (`gen_fairplay_tables.py`). uint32 values are kept as signed bit patterns, with 16-bit-half additions and masked shifts. It was verified byte-identical with the C on 1000+ random inputs (`test/fairplay/run.sh`), plus 12/12 checks on the device. 210 ms per key. |

## Stage 5: first full pipeline, with progressive MKV (`beta-version`)

The first complete receiver muxed mirroring into **live Matroska** and music into Matroska ALAC. Every part passed on the device with the fake sender: a 6 Mbit/s mirror stream, and audio captured from the Roku that decoded to exactly the tones sent.

| Problem | Fix |
|---|---|
| One live run logged "malformed data" for audio | Not reproduced later. Retransmissions are now unwrapped properly, and timestamps are forced to never go backwards. |
| A fake sender can't produce a real FairPlay `ekey` | Test-only `testAesKey` in SETUP, enabled only with the `testmode=1` launch parameter. |

## Stage 6: first real iPhone test. Music works; volume and mirroring delay don't.

**Report:** "Music works flawlessly, but adjusting volume on my iPhone doesn't affect the device … mirroring is way too laggy and delayed."

| Problem | Cause | Fix |
|---|---|---|
| iPhone volume has no effect | OS 9.1 `Audio` has no volume level, and the 3100X has no system volume | **Mute-only**: −30 dB or below, or −144, mutes. |
| 15–20 s mirroring delay | The MKV player waits for about 450 KB **and** about 5 s of media before starting. A still iPhone screen produces very little data, so start-up took ages and the buffered amount stayed as permanent delay. Void padding was skipped by the player, and filler NALs broke playback. | **Switched mirroring to live HLS with 0.5 s fMP4 segments** (`fmp4.brs`, a port of `fmp4_proto.py`), cut by time. |
| HLS started 3.9 s behind | The Roku HLS player always starts about 3.4 s behind live | **Rate steering**: play up to 1.25× fast until about 1.5 s behind. A fake-sender test then held 1.48 s with no stalls. |
| The debug console got stuck "in use", so no logs came through | A single-client console with a stale client | Added the **`/log` HTTP endpoint** (a 2000-line ring buffer). |

## Stage 7: second iPhone test. About 2 s delay and mute work, but there are hidden stalls.

**Report:** the delay is "way better now around 2 secs", and the audio gets muted. A Roku reboot turned out to be a power cut. The log showed what the user hadn't noticed: **the picture stalled every 10–20 s**, each stall pushed the delay back up to 4–6 s, and catching up took about 10 s.

| Problem | Cause | Fix |
|---|---|---|
| Up to 1 s of hidden delay | The Roku reloads the playlist once a second | **Parked future segments**: advertise the next two, and answer each request the moment its segment closes. |
| Receiver freezes of up to 5 s (`slow wait` / `slow event`) | The Task read `m.top` and `m.global` fields, a blocking rendezvous with a busy UI thread | Player position and state now arrive as **port events**. The Task never reads fields in its loop. |
| More freezes | `print` blocked on the stale 8085 console session | **Printing is opt-in** (registry key `console`). Logs go to the ring buffer. |
| Stalls on still screens and bursts | iOS sends frames in bursts and almost none on a still screen, so the player ran dry | The held frame is stretched to fill gaps, as a first fix. |
| Delay oscillated and stalled | **Bang-bang** steering (fast or normal) dipped the buffer below the player's ~1 s rebuffer threshold | **Proportional** steering, 75–115 %, target 1.8 s. |
| A ~5 s `slow wait` remained during stalls | Shown to be the Roku video player itself starving the Task while it rebuffers: it never happened with `noplayer=1` or while idle | Can't be fixed in code. **Strategy: prevent stalls.** |

Result: with the fake sender imitating the iPhone, stalls went from every 10–20 s to one every 40–80 s.

## Stage 8: third iPhone test. Freezes in Photos, black screens in Reddit.

**Report:** Spotify good; Photos fine "but the video froze in between"; Reddit "appeared and then the screen went black … a couple of times the screen became completely black."

| Problem | Cause | Fix |
|---|---|---|
| **Black screens** | The log showed the phone switching between 332×720 (portrait) and 1280×720 (landscape video) at 462.5 s and back at 473.5 s. Each switch sent a new avcC, and the receiver restarted the player, giving 4–7 s of black. | **`hls_switch_format`**: keep the player, finish the promised segments in the old format, then `EXT-X-DISCONTINUITY` and a new `initN.mp4` at the next IDR. |
| After the change, mirror frames were all dropped | A leftover guard on `vs.header`, a field from the MKV days that HLS no longer sets | Removed the stale guard. |
| Crash on the first config of a new session | A `waiters` cleanup block had been inserted into `mux_video_config`, where `vs.waiters` was still invalid | Moved it to `hls_close_segment` and guarded it. |
| Freezes on still screens (Photos) | Stretching durations still had to guess how long a gap would last, and a wrong guess drained the buffer. iOS sends **no frames at all** on a still screen, only about 30 repeated codec configs a second. | **Skip frames**: after 100 ms with no frame, insert a non-reference all-P_Skip P slice and shift the POC of later frames (`h264.brs`). Repeated configs are deduplicated. |
| Skip frames decoded with corruption in the first version | A `rangeTabLPS` row recalled from memory was wrong (row 62) | Copied the table from FFmpeg's `cabac.c`. `test/h264/h264tool.py selftest` now checks against ffmpeg. |
| Test streams didn't look like iOS's | libx264 used weighted prediction and different `frame_num` numbering | Test encodes use `weightp=0`, and the fake sender renumbers `frame_num` and converts to iOS's layout (`MIRROR_IOS_LAYOUT`). |
| CAVLC and other stream layouts | Only CABAC streams with POC type 0 had been designed for | CAVLC skip slices are supported too. Anything unsupported falls back to stretching the held frame. |

Result: in the iPhone-like stress test (bursts, pauses, a rotation halfway through), stalls went from **4 per 80 s run to 0**, in two runs. A captured live stream decoded without errors, and the skip frames were pixel-identical to the frame before them. **A retest on a real iPhone is pending.**

## Stage 9: repository and presentation

| Problem | Fix |
|---|---|
| The first commits tracked ~7,700 `node_modules` files, scratch captures, build output and a downloaded FFmpeg source file | Added `.gitignore` and untracked them (441 files tracked, down from ~8,300). They remain in earlier history. |
| The channel showed as a blank tile in the home grid | Added `mm_icon_focus_hd`/`_sd` and a splash screen from `tools/gen_icons.py`. |
| A request for the Apple TV logo | Declined, as a trademark. An original phone-to-TV glyph in a similar minimal black and graphite style, with "AirPlay4Roku" under it. |
| The channel name | Renamed to **AirPlay4Roku** in the manifest and the idle screen. |

## Stage 10: AirPlay video from a link (inspired by trimeplay)

[trimeplay](../../trimeplay), a 2013 BrightScript receiver that stopped working with iOS 8, never mirrored. It implemented the *video URL* side of AirPlay: the sender passes a link and the Roku's own player plays it, with sound. It broke because it had no FairPlay or pairing, which AirPlay4Roku already has. The protocol is now taken from UxPlay's current implementation, and the code is new (`app/source/video.brs`).

| Problem | Fix |
|---|---|
| Replies from the sender on the `/reverse` channel would have been parsed as requests and answered with 404s | Connections upgraded with `/reverse` are marked, and messages on them are ignored |
| A second video with the same duration as the first never reported its duration, because the field only notifies on change, so `/playback-info` stayed "not ready" | `playerDuration` is `alwaysNotify`, is reset on each `play`, and is re-sent when playback starts |
| The Video node is shared with mirroring: tearing down a mirror could stop a URL video, and vice versa | The scene tracks which mode owns the node (`m.mode`). Starting one mode stops the other, and the sender gets a `stopped` event. |
| Back on the Roku remote exited the channel during a video | Back stops the video and returns to the idle screen. The sender is told through the `stopped` event. |

Verified on the device with `fake_sender.py video`: local MP4 and HLS, and Apple's public HTTPS test stream. The Roku's ECP `query/media-player` reports `audio="aac"` / `"aac_adts"` while these play. A test with a real iPhone is pending.

### Result with a real iPhone (iOS 18.7.8): blocked by `fp-setup2`

| Problem | Finding |
|---|---|
| The iPhone said "playing on Roku" but the TV stayed on the idle screen | It never sent `/play`. On every new connection it does pair-verify, fp-setup, then `POST /fp-setup2` (FPLY version 1). Answered 404, it retried and gave up. |
| Answering 421, as UxPlay does | The iPhone carries on (it sends the media's audio and subtitle choices through `/setProperty`), but still closes each connection after `fp-setup2` without sending `/play`, then sends `playlistRemove` and `/stop`. Same for NDTV and for Apple's own test stream. |
| Clearing feature bit 2 ("video protected with FairPlay DRM") | No change: `fp-setup2` is still requested |
| Each new connection took ~4 s to pair | The pairing pool now holds 3 precomputes and refills only after 4 s without control requests, because refilling while the sender computes its half of pair-verify delayed our reply by ~2 s |

`fp-setup2` is a FairPlay variant no open-source receiver implements. A PhairPlay fork reports the same block for the YouTube app on iOS 27. Link playback is therefore **off by default**: feature bits 0 and 4 are advertised only after launching with `urlvideo=1`. The code stays, for senders that don't require the step.
