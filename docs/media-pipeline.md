# Media pipeline

The Roku cannot be handed raw H.264 or ALAC. Its `Video` and `Audio` nodes play containers (HLS, MP4, MKV and so on) fetched over HTTP. BrightScript, meanwhile, costs about 3 µs for every byte touched in a loop, so a 2 Mbit/s mirror stream would take most of the CPU if it were handled byte by byte. The whole pipeline is therefore built around one rule:

> **Media bytes never pass through a BrightScript loop.** Decryption is native (`roEVPCipher`). Containers are built from small generated headers plus `roByteArray.Append` of the payload exactly as received. The only per-byte work is on a few header bytes of each H.264 slice, and on generated frames that are a few dozen bytes long.

This works because AirPlay already sends video in the form both MP4 and Matroska store: AVCC length-prefixed NAL units, with an avcC record as the codec config. MPEG-TS, by contrast, would need every frame cut into 188-byte packets with headers, which is far too slow here.

## Screen mirroring: live HLS with fMP4 segments

```
TCP 7100 ─► 128-byte header + payload
              │ type 1 (avcC) ─► mux_video_config ─► init<N>.mp4 (moov), h264_params, skip-frame setup
              │ type 0 (video) ─► AES-CTR ─► mux_video_frame
              │                                 │ h264_process_frame (shift POC in place if needed)
              │                                 ▼
              │                            mux_video_push ── holds the newest unit (vs.pend)
              │                                 │ duration = next.ms − pend.ms, scaled by steering
              ▼                                 ▼
        hls_tick (every loop)  ─────►  hls_add_sample ─► 0.4 s reached? ─► hls_close_segment
        (inserts skip frames)                                              │ moof+mdat (fmp4.brs)
                                                                           │ answers parked requests
                                                                           │ hls_steer
                                                                           ▼
                                             http://127.0.0.1:8888/hls/<gen>/live.m3u8, s<N>.m4s, init<N>.mp4
```

### Segments (`fmp4.brs`)

- `mp4_init(w, h, avcc)` writes `ftyp` plus a `moov` with one `avc1` track. The avcC is copied straight from the sender. The track uses a 90 kHz timescale and an `mvex/trex` for fragmented playback.
- `mp4_segment(seq, baseDts, samples)` writes `styp`, then `moof` (`mfhd`, `tfhd`, `tfdt` with the base decode time, and `trun` with per-sample duration, size and sync flags), then `mdat` holding the sample bytes appended unchanged.
- Segments are **0.4 s, cut by time** (`HLS_SEG_TICKS() = 36000` ticks). Cutting at keyframes is impossible because iOS sends a single IDR at the start and only P frames after it. Only the first segment holds a keyframe, which is legal for fMP4 HLS as long as the player starts at the beginning of the stream. It always does here, because the URL is published once two segments exist.

### Playlist (`hls_playlist`)

- It is a sliding live window of the last 8 closed segments, with `#EXT-X-TARGETDURATION:1`, `EXT-X-MEDIA-SEQUENCE`, `EXT-X-DISCONTINUITY-SEQUENCE` and an `EXT-X-MAP` per init segment.
- **Two future segments are advertised**: `s<nextSeq>` and `s<nextSeq+1>` are listed with `#EXTINF:0.400` before they exist.
- A request for a segment that isn't there yet, between `nextSeq` and `nextSeq+2`, is **parked** in `vs.waiters`. `hls_close_segment` answers it the moment that segment closes.

  Why: the Roku reloads a live playlist about once a second. Without parking, each segment would wait up to a second after being written before the player even learned it existed. With parking, the player has always already asked for the next segment, and gets it as soon as it closes.

- Up to 14 segments are kept in memory, so a player slightly behind the window can still fetch.

### Delay steering (`hls_steer`)

The Roku HLS player always starts about **3.4 s behind** the live edge, whatever the playlist says (`EXT-X-START` and short target durations are ignored). Steering then moves it closer:

1. **Reporting.** The scene sets `Video.notificationInterval = 0.1` and pushes `position` and `state` to the receiver's `playerPos` and `playerState` fields. The receiver observes those fields into its message port, so it never reads them (see [architecture.md](architecture.md)).
2. **Measuring.** At every segment close, `depth = newest media time − player position`.
3. **Proportional correction.** The sample-duration scale is `100 − (depth − target) / 40` percent, clamped to **75–115 %**. Being 1 s too far behind gives 75 % durations, so the picture plays at 1.33×. Being 0.6 s too close gives 115 %, so it plays slower.
4. **Target.** The default is **1800 ms** (`HLS_TARGET_MS`), which the `hlstarget` launch parameter overrides in test mode. In practice this gives about 2 s of glass-to-glass delay.

Holding a steady depth matters more than making it small, because the Roku player **rebuffers as soon as its buffer dips below about 1 s**, even briefly, and a rebuffer costs 5–15 s. An earlier bang-bang controller (fast or normal) oscillated and caused exactly those stalls (see [history.md](history.md)).

Playing faster or slower than real time just means presenting frames for a little less or more time than they took on the phone. Durations are timestamps in the container; nothing is re-encoded.

### Pending unit and durations (`mux_video_push`)

A frame's duration is only known when the next frame arrives. So the newest access unit is always held back one step (`vs.pend`). When the next one arrives, the held unit is emitted with duration `next.ms − pend.ms`, taken from the sender's NTP timestamps and falling back to 33 ms if the value is out of range. The steering scale is then applied.

### Still screens: skip frames (`h264.brs`, `hls_tick`)

**Problem.** When the iPhone screen doesn't change, iOS stops sending video frames altogether, sometimes for seconds, and repeats the codec config about 30 times a second instead. With no new media, the segment can't close, the player's buffer drains below 1 s, and it rebuffers.

**Fix.** `hls_tick` runs every loop iteration. If no frame has arrived for 100 ms, it inserts a generated **skip frame**: a picture that decodes to exactly the previous one, so segments keep closing at the normal rate.

How a skip frame is built:
- It is a P slice with `nal_ref_idc = 0` (non-reference), so it never changes the decoder's reference picture state.
- Every macroblock is **P_Skip**. In CABAC that means encoding `mb_skip_flag = 1` for all of them, then `end_of_slice_flag` and the flush.
  - A portrait iPhone stream (332×720, coded as 21×45 macroblocks) has 945 of them; 1280×720 has 3600.
  - The 945 encode to **7 bytes** of slice data, because once the context adapts, each skip flag costs almost nothing.
  - The CABAC payload is computed once per codec config. Context 11 (`mb_skip_flag`) is initialised from `m, n = 23, 33` (`cabac_init_idc 0`) at the PPS's initial QP, which is what makes the iOS stream start at state 6 with MPS 1. Encoding also needs the `rangeTabLPS` table copied from FFmpeg's `cabac.c`.
  - The header writes `slice_qp_delta = 0` and turns the deblocking filter off for the slice. That doesn't matter, because skipped blocks have no residual to filter.
- The slice header reuses the stream's parameters, parsed from the SPS and PPS by `h264_params`:
  - `frame_num = lastRefFrameNum + 1`, as required for a non-reference picture that follows a reference one;
  - `pic_order_cnt_lsb = lastPoc + 2`.
- **Display order of later real frames.** Inserting pictures would make display order go backwards, so `h264_process_frame` adds the accumulated shift to `pic_order_cnt_lsb` in each later real slice header. It parses the header, rewrites the POC field, and re-escapes the edited region, taking care with emulation prevention at the region boundary. The shift resets at an IDR.
- **Supported streams.** POC type 0, `frame_mbs_only`, a single slice group, CABAC or CAVLC. That covers everything iOS sends.
- **Fallback.** For any other stream, `h264_params` returns `invalid` and `hls_tick` instead stretches the held frame's duration to cover the gap.

`test/h264/h264tool.py` is the Python reference and checks with ffmpeg that every generated frame decodes to the previous picture and that real frames decode unchanged. `test/h264/run_brs.py` checks that `h264.brs` produces byte-identical output to the Python reference.

### Format changes without a black screen (`hls_switch_format`)

Rotating the phone, playing landscape video or opening an app with a different shape makes iOS send a new avcC, for example a switch from 332×720 to 1280×720. Restarting the player for a new stream cost 4–7 s of black screen. Instead:

1. The held frame is flushed and the current segment closed.
2. The two segments already promised in the playlist are filled in the **old** format with skip frames, because the player has already requested them.
3. A new `init<N+1>.mp4` is generated, and the next segment carries `EXT-X-DISCONTINUITY` plus the new `EXT-X-MAP`. Frames are dropped until the next IDR, which iOS sends with the new config.
4. The player keeps playing through the discontinuity. The playlist keeps `EXT-X-DISCONTINUITY-SEQUENCE` correct as old discontinuities slide out of the window.

Repeated identical configs (the ~30 per second during still screens) are deduplicated by comparing the avcC hex.

## Music: live Matroska audio

```
UDP 6002 RTP (PT 0x60) ─► AES-CBC on whole 16-byte blocks (fresh IV for each packet) + plaintext tail
                       ─► mkv_simple_block (timestamp from RTP time / 44100)
                       ─► stream_push ─► every connected player plus the replay cache
                                         http://127.0.0.1:8888/audio/<gen>.mka
```

- **Container.** Matroska with an unknown-size Segment and unknown-size Clusters, so the stream can be written forward forever without seeking or patching sizes. A new Cluster starts every 1000 ms of audio.
- **Codec.** `A_ALAC` with a 24-byte `ALACSpecificConfig` as `CodecPrivate` (352 samples per frame, 44.1 kHz, 16-bit, stereo). The Roku 2 XS decodes ALAC natively in Matroska, as verified with `spike2`.
- **Timestamps** come from the RTP timestamp relative to the first packet (with 32-bit wrap handling), and are forced to never go backwards.
- **Replay cache.** The Audio node opens the URL, sometimes more than once or with a `Range` header. The server replays the header plus the cached clusters from the requested offset. The cache resets at a cluster boundary once it passes 4 MB.
- **Retransmissions** arriving on the control port (type `0x56`) are unwrapped and fed in the same way.
- **Volume.** `SET_PARAMETER volume` (in dB) arrives at the scene. At −30 dB or below, which is the bottom of the slider or the mute value −144, it sets `Audio.mute = true`; any other value unmutes. The OS 9.1 Audio node has no volume level, and the 3100X has no volume control of its own, so the TV remote sets the level.
- **Mirroring audio** (`ct=8`, AAC-ELD) is ignored, because the hardware cannot decode it (see [capabilities-and-limitations.md](capabilities-and-limitations.md)).

## The local media server (port 8888)

| Path | Content |
|---|---|
| `/hls/<gen>/live.m3u8` (or `/hls/current/...`) | live playlist |
| `/hls/<gen>/init<N>.mp4` | init segment for each format |
| `/hls/<gen>/s<N>.m4s` | media segment, served immediately or parked if it is one of the next three |
| `/audio/<gen>.mka` (or `/audio/current.mka`) | live Matroska audio, held open and streamed |
| `/log` | the receiver's ring-buffer log (last 2000 lines); only with `debuglog=1` or test mode |

Access: the stream paths answer only connections from `127.0.0.1`, which is where the Roku's own Video and Audio nodes connect from. Requests from other devices get `403 Forbidden` and a `refused …` log line. Test mode lifts that, for `fake_sender.py` and `test/h264/capture_hls.py`. This keeps someone else on the network from watching a mirrored screen or reading the log, which names the user's devices and what they played.

`<gen>` is a counter that increases with every new mirror or audio stream, so a player still holding a URL from an earlier session gets a 404 rather than the wrong stream. All sockets are non-blocking. A player that falls more than 4000 chunks behind is disconnected rather than allowed to grow memory without limit.
