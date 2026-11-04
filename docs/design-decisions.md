# Design decisions

Each entry gives the decision, the alternatives considered, and the reason for the choice, with measurements where there are any. The measurements were taken on this device: a Roku 2 XS 3100X running OS 9.1.

---

### 1. Everything runs on the Roku, in BrightScript

- **Decision.** No companion device, proxy or transcoding server.
- **Alternatives.** A Raspberry Pi or PC running UxPlay, transcoding to HLS for the Roku. This is how most "AirPlay to Roku" setups work.
- **Why.** It was the project's requirement. It also means the receiver is just a channel: install it, and remove it cleanly. The cost is that every component had to fit the Roku's slow interpreter and fixed media stack, and that shaped every decision below.

### 2. One Task thread with a single event loop

- **Decision.** All sockets live in one SceneGraph Task, driven by `wait(40, port)` and non-blocking I/O.
- **Alternatives.** Several Tasks, for example one for mirroring, one for audio and one for HTTP.
- **Why.** Tasks share nothing except node fields, and passing media bytes between them through fields would copy them through the render thread. One loop keeps the state of every part of a session (keys, segment list, players waiting for data) directly reachable, and makes the order of events easy to reason about. The loop is cheap: it runs nothing heavier than native cipher and append calls, plus pairing math that happens once per session.

### 3. Keep media bytes out of BrightScript loops

- **Decision.** Decrypt with `roEVPCipher`, and build containers from small headers plus `roByteArray.Append`. Slice arrays with `ba_slice`, which goes through native base64 and string `Mid`.
- **Why.** A BrightScript byte loop costs about 3 µs per byte. A 2 Mbit/s mirror stream is 250 KB/s, which would be about 0.75 s of CPU for every second of video. With native operations, the receiver handled a 6 Mbit/s stress stream.

### 4. Mirroring as live HLS of fMP4, not progressive MKV, MP4 or MPEG-TS

- **Decision.** Write 0.4 s fMP4 segments into a sliding live playlist served from localhost.
- **Alternatives tried.**
  - *Progressive live Matroska*, the first working version. It played, but 15–20 s behind on a still iPhone screen. The Roku player won't start an HTTP stream until it has buffered about 450 KB **and** about 5 s of media. Padding with Void elements didn't help (the player skips them), and padding with H.264 filler NALs broke playback.
  - *MPEG-TS HLS.* The Roku supports it best, but each frame would have to be cut into 188-byte packets with headers in BrightScript, too slow per byte.
  - *Progressive MP4.* It needs a `moov` up front, which a live stream can't provide.
- **Why fMP4 HLS.** It keeps AVCC samples as they are, starts on a couple of segments, and lets the player's position be steered (decision 6). Delay went from 15–20 s to 3.9 s, then to about 2 s with steering and parking.

### 5. Segments cut by time (0.4 s), not by keyframe

- **Why.** iOS sends one IDR at the start of a stream and P frames after that. Cutting at keyframes would mean one endless segment. HLS players only need a keyframe where they start, and the Roku always starts at the first segment here, because the URL is published once two segments exist. Shorter segments reduce delay, but every segment costs a request and a playlist entry. 0.5 s was used for the first latency measurements and 0.4 s is the current setting.

### 6. Steer the delay by scaling sample durations

- **Decision.** At every segment close, compare the newest media time with the player's reported position. Scale the next samples' durations to between 75 % and 115 %, proportionally to the error from a 1.8 s target.
- **Alternatives.**
  - `EXT-X-START` or a shorter target duration: ignored by the Roku player.
  - Seeking the player forward: causes a rebuffer.
  - Dropping frames: P-frame-only streams can't drop frames safely.
  - A bang-bang controller (110 % or 100 %): oscillated and caused stalls.
- **Why.** The Roku player always starts about 3.4 s behind live, whatever the playlist says. Changing durations changes nothing in the bitstream; the picture just plays up to 1.33× fast for a few seconds until it catches up. Proportional control settles smoothly. The target sits well above the minimum, because the player rebuffers as soon as its buffer goes below about 1 s, even for an instant, and a rebuffer costs 5–15 s.

### 7. Advertise future segments and park the requests

- **Decision.** The playlist lists the next two segments before they exist. A request for one of them is held open until that segment closes.
- **Why.** The Roku reloads a live playlist only about once a second. Without parking, a new segment waited on average 0.5 s, and up to 1 s, before the player even knew about it. Parking cuts that to zero and also makes delivery smooth: each segment goes out the instant it is finished.

### 8. Player feedback through port events; the Task never reads node fields

- **Decision.** The scene pushes `playerPos` and `playerState` into Receiver fields, and the Task observes them into its message port. The Task never reads `m.top.x` or `m.global.x` inside the loop.
- **Why.** A Task reading a node field is a synchronous rendezvous with the render thread. When the render thread was busy, for example while the video player was starting or rebuffering, each read blocked for up to about 5 s, freezing every socket. That was the cause of the first "video froze" reports.

### 9. Logging to a ring buffer served over HTTP; console printing opt-in

- **Decision.** `dbg()` appends to a 2000-line ring buffer served at `http://ROKU:8888/log`. `print` to the 8085 debug console only happens if the registry key `console` is set.
- **Why.** The 8085 console accepts one client. If that client stops reading, for example a dead `nc` that the Roku still believes is connected, every `print` blocks until the send buffer drains, freezing the receiver for seconds. HTTP logging can't block the loop, and can be fetched at any time without a stale connection.

### 10. Skip frames instead of stretching durations on still screens

- **Decision.** If the sender is silent for 100 ms, insert a generated all-P_Skip, non-reference P slice, and shift the POC of later real frames.
- **Alternatives tried.**
  - *Stretch the last frame's duration when the sender is silent.* This is still the fallback. A segment can't close until the next frame arrives, so a parked request has to be answered with a segment whose length was guessed. That caused stalls when the guess was wrong.
  - *Duplicate the last frame.* A copied P frame applies its motion and residual again on top of the current picture, which corrupts it.
  - *Repeat the last IDR.* There is only one, from long ago.
  - *Ask the sender for frames.* There is no such message.
- **Why.** A skip frame is a valid picture that decodes to exactly the previous image and costs about 7 bytes of slice data. It never becomes a reference, so later real frames decode unchanged. Media time then advances exactly as real time does, whatever the sender does. In the iPhone-pacing stress test (`MIRROR_JITTER`), stalls fell from 4 to 0.
- **Why POC rewriting.** Inserted pictures take display-order slots. Real frames that follow need their `pic_order_cnt_lsb` raised, or the decoder would show them before the skip frames. Only the POC field in the slice header changes; slice data is copied untouched.

### 11. Format changes through `EXT-X-DISCONTINUITY`, keeping the player alive

- **Decision.** On a new avcC with a new resolution: finish the two promised segments in the old format with skip frames, then start a new init segment with a discontinuity at the next IDR.
- **Alternative.** Stop the Video node and start a new HLS session, the original behaviour.
- **Why.** A restart cost 4–7 s of black screen, and the reports of Reddit going black came from exactly that. iOS changes format often: on rotation, landscape video, and apps with different layouts.

### 12. Music as live Matroska with ALAC, not HLS

- **Why.**
  - The Roku 2 XS decodes ALAC natively in Matroska (tested in `spike2`), so audio data passes through untouched.
  - Music delay barely matters: there is no picture on the TV to lag behind, and the sender's own buffering hides it.
  - A single long-lived HTTP response is simpler than segmenting audio.
  - Matroska's unknown-size Segment and Clusters let the stream be written forward forever.

### 13. Mute-only volume

- **Why.** The OS 9.1 `Audio` node has `mute` but no volume level, and the 3100X has no system volume, since the TV controls it. Re-encoding PCM at a different gain in BrightScript would be impossibly slow. So the bottom of the iPhone slider, or mute (−144 dB), mutes the stream, and the TV sets the level.

### 14. Legacy transient pairing (feature bit 27), as in UxPlay

- **Why.** This is UxPlay's default and the combination iOS is known to accept from an `AppleTV3,2`-class receiver. Legacy transient pairing is the cheapest form: one X25519 and one Ed25519 signature, with no SRP and no persistent pairing database. HomeKit pairing (SRP-6a with a 3072-bit group, plus ChaCha20-Poly1305) would need big-integer modular exponentiation and a cipher with no native support, which is far beyond what BrightScript can do in time. The `nopair` registry key turns the bit off, as UxPlay's `-nopair` option does.

### 15. Precompute the slow parts of pairing while idle

- **Why.** X25519 key generation and the Ed25519 nonce point add about 1.9 s. Doing them before a sender connects halves the time pair-verify takes, keeping it under iOS's limit with room to spare. A randomized Ed25519 nonce is what makes `R` computable in advance (see [crypto.md](crypto.md)).

### 16. 20 × 13-bit limbs and a generated, unrolled field implementation

- **Why.**
  - `Integer` is the only fast numeric type.
  - 13-bit limbs are the widest size whose 39 column sums cannot pass 2^31. That rules out the common 25.5-bit (ref10) and 51-bit representations.
  - Unrolling removes array indexing in the hot path, which measurably affects BrightScript performance.
  - Generating the code lets the generator prove the bounds instead of trusting hand-written code.

### 17. Never rely on Integer overflow

- **Why.** The device wraps 32-bit Integers, but the local `brs` interpreter doesn't. Code that never overflows behaves the same in both, so differential tests run locally in seconds are meaningful for the device. This applies to the field arithmetic, FairPlay and the H.264 bit writer.

### 18. Differential testing against reference implementations

- **Why.** On-device debugging is slow: every change needs a zip and sideload, there is no try/catch, and a crash halts the Task. Every complex component therefore has a Python or C reference, and a local test proves the BrightScript produces identical output:

  | BrightScript | Reference |
  |---|---|
  | crypto | pyca/cryptography |
  | plist | plistlib |
  | fMP4 | Python prototype |
  | H.264 | Python tool verified with ffmpeg |
  | FairPlay | the original C |

  See [testing.md](testing.md).

### 19. A test-only plaintext key path

- **Why.** A test sender can't produce a real FairPlay-encrypted `ekey`, because that would require Apple's client-side FairPlay. With the `testmode=1` launch parameter, and only then, SETUP accepts `testAesKey` in plaintext. This lets `fake_sender.py` exercise everything else on the device end to end. In normal launches the path is disabled.

### 20. Original artwork, not Apple's

- **Why.** The channel icon and splash show an original phone-to-TV design with the text "AirPlay4Roku", generated by `tools/gen_icons.py`. Apple's AirPlay and Apple TV logos are trademarks and are deliberately not reproduced.

### 21. Safe and reversible by construction

- **Decision.** Sideload into the single developer slot, keep state in the channel's own registry section, and make no system changes. `tools/deploy.sh --delete` removes everything. Spikes and probes live in their own directories, apart from the channel.
