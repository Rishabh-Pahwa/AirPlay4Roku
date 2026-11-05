# Architecture

## The big picture

```
iPhone / iPad / Mac
   │  mDNS query            ┌───────────────────────── Roku 2 XS ─────────────────────────┐
   ├──────────────────────► │ :5353 UDP  mdns.brs      answers _airplay._tcp / _raop._tcp │
   │  RTSP/HTTP control     │                                                             │
   ├──────────────────────► │ :7000 TCP  receiver.brs  /info, pairing, fp-setup, SETUP... │
   │  mirror stream         │                                                             │
   ├──────────────────────► │ :7100 TCP  AES-CTR ─► h264.brs ─► fmp4.brs ─► HLS segments  │──┐
   │  ALAC audio (RTP)      │                                                             │  │
   ├──────────────────────► │ :6002 UDP  AES-CBC ─► mkv.brs ─► live Matroska              │──┤
   │  NTP replies           │                                                             │  │
   ◄──────────────────────► │ :6010 UDP  timing requests                                  │  │
                            │                                                             │  │
                            │ :8888 TCP  local media server (+ /log) ◄────────────────────┼──┘
                            │       ▲                                                     │
                            │       │ HTTP 127.0.0.1                                      │
                            │   Video node (HLS)    Audio node (MKV)    ← MainScene        │
                            └─────────────────────────────────────────────────────────────┘
```

Everything that touches the network runs in one SceneGraph **Task** (`components/Receiver.xml`, entry point `rx_main` in `source/receiver.brs`). The UI thread (`components/MainScene.*`) shows the idle screen and owns a `Video` node and an `Audio` node. The Roku's players can only fetch container formats over HTTP. So the receiver also runs a small HTTP server on port 8888, and the players fetch from `http://127.0.0.1:8888/...`.

## Threads and communication

| Thread | Code | Responsibilities |
|---|---|---|
| Main | `source/main.brs` | Creates the scene and reads launch parameters (`testmode`, `hlstarget`, `nofeedback`, `noplayer`) into `m.global`. |
| Render (UI) | `components/MainScene.brs` | Idle UI, `Video`/`Audio` playback, player state and position reporting, mute. |
| Receiver task | `source/receiver.brs` plus the libraries | All sockets, protocol, crypto, muxing and the media server. |

The receiver and the scene talk only through fields on the `Receiver` node:

| Field | Direction | Purpose |
|---|---|---|
| `info`, `status`, `client` | task → UI | Shown on the idle screen. |
| `mirrorUrl`, `mirrorSize` | task → UI | HLS URL to play, or `""` to stop. |
| `audioUrl` | task → UI | Matroska URL for music, or `""` to stop. |
| `volume` | task → UI | AirPlay volume in dB. The UI turns it into mute. |
| `playerPos`, `playerState` | UI → task | Feedback for delay steering. The task observes these into its message port. |
| `quit` | UI → task | Shutdown request. |
| `videoCmd` | task → UI | URL playback commands: `play` (url, format, start), `pause`, `resume`, `seek`, `stop`. |
| `playerDuration`, `playerNote` | UI → task | Duration of a URL video; player notes (errors, codecs) for the log. |

**The task never reads `m.top.*` or `m.global.*` in its loop.** On Roku, a Task reading node fields is a blocking rendezvous with the UI thread, and that froze the whole receiver for seconds (see [history.md](history.md)). Values the task needs arrive as `roSGNodeEvent`s on its port instead.

## The event loop

`rx_main` sets up all sockets, then runs:

```
loop:
    msg = wait(40 ms, port)
    socket event   → rx_dispatch(socket id)   (accept / read / write for that handler)
    node event     → cache playerPos / playerState / quit
    rx_timers()    → mDNS announcements, NTP requests, HLS gap filling (hls_tick),
                     idle pairing precompute, periodic GC, 10 s stats
```

`m.handlers` maps socket IDs to handler records (`kind` is one of `rtsp`, `mirror`, `http`, `mdns`, `audio-data`, `ntp`, and so on). All socket I/O is non-blocking and driven by `notifyReadable` / `notifyWritable`. The loop times itself and logs `slow wait`, `slow event <kind>` or `slow timers` whenever a step takes over 300 ms.

## Modules

| File | Role |
|---|---|
| `receiver.brs` | Socket setup, RTSP handlers, session state, mirror and audio pipelines, HLS segmenter and steering, local media server |
| `mdns.brs` | Minimal mDNS / DNS-SD responder: PTR/SRV/TXT/A records, multicast and legacy-unicast answers, announcements |
| `plist.brs` | Binary plist reader, and a writer that preserves key order |
| `fe25519.brs` | **Generated** field arithmetic for GF(2^255−19) (`tools/gen_fe25519.py`) |
| `curve25519.brs` | X25519, Ed25519 fixed-base multiplication and signing, scalars mod L |
| `fairplay.brs` | playfair port: fp-setup replies and `ekey` decryption, with tables in `assets/fairplay/` |
| `fmp4.brs` | Fragmented-MP4 init and media segments for live HLS |
| `h264.brs` | SPS/PPS parsing, skip-frame generation (CABAC/CAVLC), in-place POC rewriting |
| `mkv.brs` | Live Matroska muxer (ALAC audio; it originally handled video too) |
| `video.brs` | AirPlay video-URL playback: `/play`, `/rate`, `/scrub`, `/stop`, `/playback-info`, `/server-info`, the `/reverse` event channel |
| `util.brs` | Byte helpers (`ba_slice` via native base64), the log ring buffer (`dbg`) |

## Session lifecycle

1. **Startup.** The receiver loads or creates a persistent identity in registry section `airplay`: an Ed25519 seed and a random device ID. It computes the Ed25519 public key (~1.6 s), preloads the FairPlay tables, binds every socket and announces itself over mDNS. While idle, it precomputes an ephemeral X25519 key and an Ed25519 signing nonce (~1.9 s).
2. **Discovery.** The sender finds `<name>._airplay._tcp.local` and `<MAC>@<name>._raop._tcp.local`.
3. **Control connection.** The sender connects to :7000. It sends `GET /info`, `POST /pair-setup`, `POST /pair-verify` (two steps), then `POST /fp-setup` (two steps).
4. **SETUP 1.** Carries `ekey`/`eiv` and `timingPort`. The receiver decrypts the AES key with FairPlay, hashes it with the pairing secret and starts NTP requests. This creates `m.session`.
5. **SETUP 2.** Lists streams. Type 110 (mirroring) derives the stream key and IV and answers `dataPort 7100`. Type 96 (audio) sets up the CBC cipher and answers ports 6002/6003.
6. **Streaming.**
   - Mirror packets go: decrypt → skip-frame and POC handling → fMP4 segments. Once two segments exist, `mirrorUrl` is published and the UI starts the `Video` node on the HLS playlist.
   - Audio packets go: decrypt → Matroska. `audioUrl` is published on the first packet.
7. **TEARDOWN.**
   - With `streams` listed, it stops only those (audio, mirror, or both).
   - With no streams listed, or when the control connection closes, it ends the session and clears both URLs.

There is one session at a time, as in UxPlay. A new SETUP 1 ends the previous session.

## Persistent state

| Registry key (`airplay` section) | Meaning |
|---|---|
| `seed` | Ed25519 identity seed (hex). The public key goes in TXT `pk` and `/info`. |
| `devid` | Random locally-administered MAC used as the AirPlay device ID. |
| `name` (optional) | Overrides the advertised name (default: the Roku's model name). |
| `nopair` (optional) | Clears feature bit 27 so senders skip pairing. |
| `console` (optional) | Re-enables `print` to the 8085 debug console. |

Deleting the dev channel (`tools/deploy.sh --delete`) removes the registry section too.
