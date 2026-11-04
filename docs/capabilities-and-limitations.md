# Capabilities and limitations

## What AirPlay4Roku can do

| Feature | Status | Notes |
|---|---|---|
| Appears in iOS Screen Mirroring and the AirPlay audio picker | ✅ | mDNS `_airplay._tcp` and `_raop._tcp` with UxPlay's TXT records |
| Legacy transient pairing (no PIN) | ✅ | About 2.1 s on the device |
| FairPlay key exchange | ✅ | playfair port, about 210 ms |
| Screen mirroring, H.264 | ✅ | Up to 1280×720 at 30 fps, as advertised in `/info`. Portrait phone screens arrive as 332×720. |
| Mirroring delay | ✅ ~2 s | Steered to 1.8 s behind the newest data |
| Still screens (Photos, home screen) | ✅* | Skip frames keep the player fed. *Verified with the fake sender; a retest on a real iPhone is pending. |
| Rotation and format changes | ✅* | `EXT-X-DISCONTINUITY` with no player restart. *Same pending status as still screens. |
| AirPlay music (Spotify, Apple Music, and so on) | ✅ | ALAC 44.1 kHz/16-bit over RTP, AES-CBC |
| Mute from the sender | ✅ | Bottom of the volume slider, or mute |
| Logs without the debug console | ✅ | `http://ROKU:8888/log` |
| Clean install and removal | ✅ | Developer slot plus the channel's own registry section |

## Limitations of this receiver

| Limitation | Why | Could it be fixed? |
|---|---|---|
| **No audio while mirroring** | Mirroring audio is AAC-ELD (`ct=8`). The Roku 2 XS has no AAC-ELD decoder, and decoding it in BrightScript would be hundreds of times too slow. | Not on this hardware. A newer Roku might decode AAC-ELD natively, but that hasn't been tested. |
| **Volume is mute-only** | The OS 9.1 `Audio` node has `mute` but no gain control, and the 3100X has no system volume. Scaling PCM would mean decoding ALAC in BrightScript. | No. Use the TV's volume. |
| **About 2 s mirroring delay** | Limits of the Roku player: it starts about 3.4 s behind live, rebuffers when its buffer falls below about 1 s, and reloads playlists only once a second. The rest is iPhone bursts plus segment duration. | A little might come off by tuning the target lower, at a higher risk of stalls. Sub-second delay would need a lower-level player API, which BrightScript doesn't have. |
| **A rare ~5 s freeze if the player rebuffers anyway** | While the Roku video player rebuffers, it can starve the receiver task for about 5 s. It was never seen with the player off, and isn't controllable from the channel. | Only by preventing stalls, which skip frames and steering do. |
| **Only while the channel is open** | Roku channels can't run in the background or start on an incoming connection. | No. The channel can be started remotely with ECP: `curl -d '' http://ROKU:8060/launch/dev`. |
| **One sender at a time** | Single-session design, like UxPlay. A new sender ends the current session. | Possible, but there is only one player to show it on. |
| **No "AirPlay video URL" casting** (`/play`, `/scrub`, `/rate`), photos or slideshows | Not implemented. YouTube-style "AirPlay a URL" uses a separate HTTP API. | Partly: the Roku could play many HLS URLs directly. This is the most promising future feature. |
| **No AirPlay 2 buffered audio, PTP timing or multi-room** | Needs HomeKit pairing (SRP-6a, ChaCha20-Poly1305) and stream type 103. iOS falls back to realtime ALAC for this receiver. | Impractical in BrightScript. |
| **DRM-protected video shows black** | iOS itself blanks protected content (Netflix and others) when mirroring to non-Apple receivers. | No. This is sender-side policy. |
| **No access control** | Transient pairing with no PIN: anyone on the LAN can mirror while the channel is open. | A PIN-based (SRP) pairing would be too slow. Registry `nopair` makes it even more open, not less. |
| **Crypto is not constant-time** | The keys are ephemeral and the device is single-user, so timing side channels were considered out of scope. | Possible, at a speed cost. |
| **Untested senders** | Developed and tested with an iPhone and the fake sender. macOS and iPadOS mirroring should work, since the protocol is the same, but haven't been tried. | Needs testing. |
| **Sideloaded developer channel only** | One developer slot per device, and it is removed if developer mode is turned off. Publishing to the Roku store wasn't a goal, and the "AirPlay" name is Apple's trademark. | — |

## What the Roku 2 XS / OS 9.1 platform allows and doesn't

### What the platform provides
- Raw TCP and UDP sockets, including multicast join (`roStreamSocket`, `roDataGramSocket`), so the channel can be a network server on any port above 1024. That includes 5353, 7000, 7100 and 8888.
- Native AES (CBC, CTR, ECB) through `roEVPCipher`, with CTR state kept across calls, and native SHA-1, SHA-256, SHA-512 and MD5 through `roEVPDigest`.
- Native base64, hex and ASCII conversions on `roByteArray`, which are the only fast way to slice byte arrays.
- Hardware H.264 decoding (High profile) through the `Video` node, from HLS (TS or fMP4), MP4 or MKV over HTTP, including `http://127.0.0.1`.
- ALAC, AAC-LC, MP3, FLAC and PCM through the `Audio` node, including ALAC in Matroska.
- A persistent registry per channel, and ECP for remote control and launch with parameters.

### What it doesn't provide
- **No raw media path.** There is no way to give the decoder elementary streams or samples. Everything goes through a URL and a container, and the player's own buffering rules (start thresholds, rebuffering) can't be configured.
- **No AAC-ELD**, and no control over audio gain.
- **Slow interpreter.**
  - About 1 µs per Integer operation, LongInteger 20–30× slower, about 3 µs per byte in loops.
  - No XOR, no arithmetic right shift, no unsigned types.
  - No SIMD, native bignums or elliptic-curve APIs.
- **No exceptions** (no try/catch on OS 9.1). A runtime error stops the Task in the debugger.
- **No background execution** and no autostart.
- **Thread model quirks.** Task-to-node field reads are blocking rendezvous with the UI thread. The 8085 debug console takes one client, and a stale one blocks `print`.

See [platform-notes.md](platform-notes.md) for the measured details.
