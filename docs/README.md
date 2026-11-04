# AirPlay4Roku documentation

AirPlay4Roku is an AirPlay receiver written in BrightScript. It runs entirely on a Roku 2 XS (model 3100X, Roku OS 9.1), with no helper device or server: discovery, pairing, FairPlay key exchange, decryption, repackaging and playback all happen on the Roku.

| Document | What it covers |
|---|---|
| [architecture.md](architecture.md) | Components, threads, sockets, data flow, session lifecycle |
| [protocol.md](protocol.md) | The AirPlay protocol as this receiver implements it, message by message |
| [media-pipeline.md](media-pipeline.md) | How mirrored video and AirPlay music reach the Roku's player: HLS/fMP4, delay steering, skip frames, format changes, live Matroska audio |
| [crypto.md](crypto.md) | X25519, Ed25519, FairPlay (playfair) and AES on a CPU where 64-bit maths is very slow |
| [design-decisions.md](design-decisions.md) | Each significant design decision, the alternatives, and why it was made |
| [capabilities-and-limitations.md](capabilities-and-limitations.md) | What the receiver can and can't do, and which limits come from the Roku itself |
| [platform-notes.md](platform-notes.md) | Measured BrightScript / Roku OS 9.1 behaviour and performance on this device |
| [history.md](history.md) | Problems found at each stage of development and how each was fixed |
| [testing.md](testing.md) | Test strategy, the local interpreter, differential tests, the fake sender, on-device diagnostics |

Status at the time of writing:
- **Tested on a real iPhone:** discovery, pairing, FairPlay, music, mute, and mirroring at about 2 s delay.
- **Tested with the fake sender only:** skip frames and seamless format changes, which address the remaining freezes and black screens. They have not yet been confirmed on a real iPhone.
