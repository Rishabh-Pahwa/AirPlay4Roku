# Platform notes: BrightScript on a Roku 2 XS (OS 9.1)

These are the facts about the platform that shaped the implementation. Almost every one was found by hitting it.

## Performance (measured on the 3100X)

| Operation | Cost |
|---|---|
| Integer multiply-add | ~1 µs |
| LongInteger or Double arithmetic | ~20–30× slower than Integer |
| Touching one byte in a BrightScript loop | ~3 µs |
| fe25519 field multiplication (generated, unrolled) | ~0.7 ms |
| X25519 scalar multiplication (ladder) | ~1.85–1.9 s |
| Ed25519 public key from seed | ~1.6 s |
| Ed25519 signature with a precomputed nonce | ~0.27 s |
| FairPlay `ekey` decrypt | ~210 ms |
| Mirror stream throughput handled (native decrypt plus append) | ≥ 6 Mbit/s at 30 fps |
| Original pairing estimate with LongInteger arithmetic | ~25 s, too slow for iOS |

## The language

- **Integer is signed 32-bit and wraps on overflow on the device.** The local `brs` interpreter doesn't wrap, so code that depends on wrapping behaves differently in tests. All arithmetic is kept below 2^31.
- **`>>` is a logical shift**, even for negative values. Floor division of signed values is written by hand.
- **No XOR.** Use `(a or b) − (a and b)`, which can never overflow.
- **Mixing types in `and`/`or`.** Combining a LongInteger with an Integer truncates to 32 bits. In 64-bit code, build values with `* 256&` and take them apart with `\` and `mod`. `/` always produces a float and loses precision above 2^53, and sometimes below that.
- **Associative array keys are case-insensitive.** `{r: 1, R: 2}` is a single key, so the Ed25519 nonce fields `r` and `R` overwrote each other (see [history.md](history.md)). Comparing AAs with `=` is a runtime error.
- **Reserved or built-in names** that can't be used as identifiers and caused compile errors or crashes: `log`, `tab`, `pos`, `as`, `next`, and also `run`, `stop`, `line_num` and similar.
- **Not available on OS 9.1:** try/catch, `FindMemberFunction`, `String.Replace` (use `Split().Join()`).
- **`roByteArray` has no slice or sub-array.** `ba_slice` encodes to base64, takes `Mid` of the string at 4/3 offsets and decodes. For large buffers this is far faster than a loop.
- **Garbage.** Collection of circular references is lazy. The receiver calls `RunGarbageCollector()` every 2 s, because frequent small collections avoid occasional multi-second ones.

## SceneGraph threads

- A **Task** reading `m.top.field` or `m.global.field` does a synchronous rendezvous with the render thread. When the render thread is busy, for example while the `Video` node starts or rebuffers, that read blocks for up to about 5 s. Use `observeField(field, port)` and handle `roSGNodeEvent`s instead.
- **Writing** fields from a Task is also a rendezvous, but a short one in practice. The receiver only writes on state changes: URLs, status and volume.
- During its own rebuffering, the `Video` node can starve every other thread for about 5 s. That appears as a `slow wait` in the receiver log with no other cause.

## Media players

- **Start delay.** The `Video` node won't start an HTTP progressive stream (MKV or MP4) until it has about 450 KB **and** about 5 s of media. With HLS it starts on a couple of segments, but always about 3.4 s behind the live edge. `EXT-X-START` is ignored.
- **Rebuffering.** The HLS player rebuffers as soon as its forward buffer falls below about 1 s, even briefly. A rebuffer takes 5–15 s to recover.
- **Playlist reload.** Live playlists are reloaded about once a second, whatever the target duration says.
- **Discontinuities.** `EXT-X-DISCONTINUITY` with a new `EXT-X-MAP` (fMP4 init) is handled without a visible restart. Restarting the node costs 4–7 s of black.
- **Matroska.** Void elements in Matroska are skipped and don't count as progress. H.264 filler NALs (type 12) broke playback.
- **Position reporting.** `notificationInterval = 0.1` gives 100 ms position updates, which are enough for delay steering.
- **Audio.** The `Audio` node plays ALAC in Matroska. It has `mute` but no volume.

## Sockets

- A channel can bind any port above 1024 (7000, 7100, 8888, 6002 and others), and also 5353, joining 224.0.0.251 with `JoinGroup`.
- Use non-blocking sockets with `notifyReadable`/`notifyWritable` on one port. `getCountRcvBuf() = 0` on a readable socket means the peer closed it.

## Tooling

- **Developer installer.** Port 80, HTTP digest auth, user `rokudev`. Only one sideloaded channel (`dev`) exists at a time, and installing replaces it.
- **ECP (:8060).** `keypress/<key>`, `launch/dev?param=value` (launch parameters reach `Main(args)`), `query/apps`, `query/device-info`, `query/icon/dev`.
- **Debug console (:8085).** One client at a time. A client that dies without closing can keep it "in use", and every `print` then blocks the printing thread. That is why printing is opt-in.
- **Local interpreter.** `brs-node` works on Node 22, not Node 18. `--root` must be given, and file arguments must be relative to it. It doesn't wrap Integers.
- **Reboots.** The Roku once rebooted on its own while a test channel was stopped in the debugger, and once because of a power cut. Neither was caused by the receiver.
