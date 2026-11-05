# AirPlay protocol as implemented

This is the "AirPlay 2 receiver with legacy pairing" flavour that UxPlay and RPiPlay speak: iOS and macOS mirroring plus RAOP audio. The receiver identifies as an `AppleTV3,2` with source version `220.68`, using the same feature set as UxPlay.

## 1. Discovery (mDNS, `mdns.brs`)

Two services point at port 7000 on host `roku-airplay-<last 6 hex of device id>.local`:

| Service | Instance name | Key TXT entries |
|---|---|---|
| `_airplay._tcp` | `<name>` | `deviceid`, `features=0x5A7FFEE6,0x0`, `flags=0x4`, `model`, `pk` (Ed25519 public key, hex), `pi`, `srcvers`, `vv=2`, `pw=false` |
| `_raop._tcp` | `<MACHEX>@<name>` | `ch=2`, `cn=0,1,2,3`, `et=0,3,5`, `ft`, `md=0,1,2`, `sr=44100`, `ss=16`, `tp=UDP`, `vn=65537`, `pk`, ... |

How the responder behaves:
- **Queries:** it answers for either service type, either instance name, its host name and `_services._dns-sd._udp`.
- **Multicast answers:** sent to 224.0.0.251:5353, and also unicast to the asker if the QU bit is set.
- **Legacy unicast:** queries from a source port other than 5353 get a reply echoing the query ID and questions. `test/fake_sender.py discover` uses this.
- **Announcements:** at startup (0, 1, 3 and 6 s) and then every 60 s. A goodbye (TTL 0) is sent on a clean exit.

**Feature bit 27 ("supports legacy pairing")** is set, matching UxPlay's default. With it cleared (registry `nopair`), senders skip pair-setup and pair-verify, and the AES key is used unhashed.

## 2. `GET /info`

- **With a bplist body** `{qualifier: ["txtAirPlay"]}`: the reply is just `{txtAirPlay: <TXT record bytes>}`.
- **Without a body:** the full dictionary: `deviceID`, `macAddress`, `pk`, `features` (64-bit), `name`, `pi`, `vv`, `statusFlags=68`, `model`, `sourceVersion`, `initialVolume`, `audioFormats`, `audioLatencies`, and one `displays` entry (1280×720, maxFPS 30).

The advertised display size is what makes iOS encode at 1280×720 in landscape, or 332×720 for a portrait phone screen.

## 3. Pairing (legacy, transient)

- **`POST /pair-setup`**: the body is the client's 32-byte Ed25519 key. The reply is the receiver's 32-byte Ed25519 public key.
- **`POST /pair-verify` step 1**: the body is `01 00 00 00 ‖ client X25519 public (32) ‖ client Ed25519 public (32)`. The receiver:
  1. takes the precomputed ephemeral X25519 key pair and Ed25519 nonce;
  2. computes `shared = X25519(our_priv, client_pub)` (~1.9 s on the device);
  3. signs `our_x25519_pub ‖ client_x25519_pub` with Ed25519 using the precomputed nonce;
  4. encrypts the 64-byte signature with AES-128-CTR, using key `SHA-512("Pair-Verify-AES-Key" ‖ shared)[0:16]` and IV `SHA-512("Pair-Verify-AES-IV" ‖ shared)[0:16]`;
  5. replies `our_x25519_pub ‖ encrypted signature`.

  Step 1 takes about 2.1 s end to end.
- **`POST /pair-verify` step 2**: the client's encrypted signature. It is accepted without verification, because this is transient pairing with no PIN, as in UxPlay.

## 4. FairPlay (`POST /fp-setup`, `fairplay.brs`)

- **Phase 1 (16 bytes).** Byte 4 must be `03`. Byte 14 selects one of four canned 142-byte replies.
- **Phase 2 (164 bytes).** The message is stored as `keymsg`. The reply is a fixed 12-byte header plus bytes 144–163 of the request.
- **Later, in SETUP.** `aeskey = playfair_decrypt(keymsg, ekey)` (72-byte `ekey`, ~210 ms on the device).

## 5. `SETUP`

**First SETUP**: the plist contains `ekey`, `eiv`, `timingPort` and the sender's `name` and `model`. The receiver then:

1. derives `aeskey = FairPlay_Decrypt(keymsg, ekey)`;
2. if pairing happened, sets `aeskey = SHA-512(aeskey ‖ shared)[0:16]`;
3. replies `{eventPort: 0, timingPort: 6010}` and starts sending NTP timing requests to the sender every 3 s.

In test mode only, a plaintext `testAesKey` in the plist replaces step 1 (see [testing.md](testing.md)).

**Stream SETUP**: `streams` is a list of `{type, ...}`.

| type | Meaning | Receiver action | Reply |
|---|---|---|---|
| 110 | Screen mirroring. `streamConnectionID` is an unsigned 64-bit value that can exceed 2^63. | key = `SHA-512("AirPlayStreamKey" + decimal(id) ‖ aeskey)[0:16]`, IV = `SHA-512("AirPlayStreamIV" + decimal(id) ‖ aeskey)[0:16]`, AES-128-CTR | `{type: 110, dataPort: 7100}` |
| 96 | Audio. `ct` = 2 for ALAC (music) or 8 for AAC-ELD (mirroring audio); `spf` is samples per frame. | AES-128-CBC with `aeskey`/`eiv`, reset for every packet. Only ALAC is played. | `{type: 96, dataPort: 6002, controlPort: 6003}` |

## 6. The mirror stream (TCP 7100)

Each packet is a **128-byte header** followed by a payload.

| Offset | Field |
|---|---|
| 0–3 | payload size, little-endian |
| 4 | type: 0 = video, 1 = codec config, others ignored (2 = heartbeat, 5 = streaming report) |
| 5 | `0x10` on IDR video packets |
| 6–7 | option (`0x16 0x01` normal config; `0x56 0x01` config repeated while the sender "sleeps") |
| 8–15 | NTP timestamp, little-endian: fraction in bytes 8–11, seconds in bytes 12–15 |
| 40/44, 56/60 | source and display width and height, float32 |

- **Type 0 payloads** are AES-CTR encrypted. One keystream runs continuously across all type-0 packets: a packet that ends mid-block continues the same block in the next packet. `roEVPCipher.Update` preserves that state natively. The plaintext is AVCC, NAL units with 4-byte length prefixes.
- **Type 1 payloads** are an unencrypted avcC record holding SPS and PPS.

What the iPhone actually sends:
- High profile, level 3.0/3.1, CABAC, `pic_order_cnt_type 0` (13-bit LSB), 12-bit `frame_num`, up to 4 reference frames, a single IDR at the start, then P frames only.
- Frames arrive at 12–30 fps and in bursts.
- On a still screen it sends no frames at all and repeats the codec config about 30 times a second instead.
- Rotation, landscape video or a different app shape sends a new avcC, for example a switch from 332×720 to 1280×720.

## 7. Audio (UDP 6002/6003)

The RTP header is 12 bytes; payload type `0x60` is audio data. In the payload, every whole 16-byte block is AES-128-CBC encrypted with a fresh IV (`eiv`) for each packet, and the trailing `len mod 16` bytes are plaintext. For ALAC each packet is one 352-sample frame. Packets of type `0x56` on the control port are retransmissions wrapping an original RTP packet, and are fed through the same path.

## 8. Other requests

| Request | Handling |
|---|---|
| `OPTIONS` | `Public:` list |
| `RECORD` | `Audio-Latency: 11025`, `Audio-Jack-Status: connected; type=analog` |
| `GET_PARAMETER volume` | `volume: 0.000000` |
| `SET_PARAMETER` | `text/parameters`: `volume: <dB>` (−30…0, −144 = mute) is forwarded to the UI, `progress:` is logged. Metadata (DMAP) and artwork are accepted and ignored. |
| `FLUSH`, `POST /feedback` (every ~2 s), `/audioMode`, `/command` | 200 OK |
| `TEARDOWN` | The plist `streams` lists types: 96 stops audio, 110 stops mirroring; with no streams, the session ends. The reply carries `Connection: close`. |
| anything else | 404, logged as `unhandled` |

## 9. AirPlay video (URL playback, `video.brs`)

Advertised only when enabled (launch param `urlvideo=1`): feature bits 0 and 4 (`features=0x5A7FFEF7`). Off by default, because iOS 18 sends `POST /fp-setup2` (FPLY version 1, 120 bytes) on every new connection before `/play`. It's answered `421 Misdirected Request` as in UxPlay, and the iPhone then closes the connection without sending `/play`. It still sends `/setProperty` (media selection) and finally `/action` `playlistRemove` and `/stop`. Clearing bit 2 doesn't avoid it. These are `HTTP/1.1` requests on the same :7000 connections, usually after pair-verify and fp-setup:

| Request | Handling |
|---|---|
| `GET /server-info` | XML plist: `deviceid`, `features`, `macAddress`, `model`, `osBuildVersion`, `protovers`, `srcvers`, `vv` |
| `POST /reverse` | `101 Switching Protocols`, `Upgrade: PTTH/1.0`. This connection becomes the receiver → sender channel. The sender's replies on it are ignored. |
| `POST /play` | bplist `Content-Location` (URL), `Start-Position-Seconds` (or `Start-Position` as a fraction), `uuid`, `clientProcName`; older senders use `text/parameters`. http(s) URLs are played (`streamFormat` guessed from the URL: `.m3u8` → HLS, otherwise MP4); anything else gets 400. Replaces screen mirroring on the Video node. |
| `POST /rate?value=0` / `1` | pause / resume |
| `POST /scrub?position=s`, `GET /scrub` | seek; `duration: … position: …` as `text/parameters` |
| `GET /playback-info` | XML plist `duration`, `position`, `rate`, `readyToPlay`, buffer flags, `loadedTimeRanges`, `seekableTimeRanges`. Empty while loading. After the video ends: an empty reply, then the connection is closed, which is how UxPlay signals the end. |
| `POST /stop` | stop and return to the idle screen |
| `PUT /setProperty?…` | `{errorCode: 0}` |

Events go to the sender as `POST /event` with an XML plist `{category: video, state: loading|playing|paused|stopped, uuid}` whenever the player's state changes, including changes made with the Roku remote.

Not handled yet: the YouTube app's playlists, which the receiver has to request from the sender (FCUP `unhandledURLRequest` events, answered with `POST /action`), and `/photo`.

## 10. Timing

The receiver acts as the NTP client: it sends a 32-byte `0x80 0xD2` request with its transmit time to the sender's `timingPort` every 3 s and ignores the replies. The mirror timeline uses frame timestamps and the receiver's own clock rather than synchronised NTP time, so clock offset estimation isn't needed.
