# TalkMode

A small macOS menu-bar app that keeps your AirPods in **headset (mic) mode** while you talk to a voice agent, so there's no switching delay and the sound quality doesn't jump around.

```
         talk mode OFF                          talk mode ON
 ┌──────────────────────────────┐     ┌──────────────────────────────┐
 │ agent opens mic → switch to  │     │ TalkMode holds the AirPods   │
 │ headset (delay, cut-off)     │     │ mic open the whole time      │
 │ agent closes mic → switch    │     │ agent opens/closes mic →     │
 │ back to stereo (quality jump)│     │ no switch, no delay          │
 └──────────────────────────────┘     └──────────────────────────────┘
```

## Why

When an app opens a Bluetooth mic, macOS switches AirPods from stereo (A2DP, 48 kHz) to the two-way headset profile (HFP, 24 kHz). That switch takes a moment, so the first words get lost. When the mic closes, they switch back. TalkMode holds the mic open for as long as you want, so the AirPods stay in one mode.

## How it works

- While talk mode is on, it opens the AirPods input with a Core Audio IOProc and **throws the audio away**. Nothing is recorded, stored, or sent anywhere.
- It listens for Core Audio device changes and checks again every 5 s. If the AirPods disconnect, it waits (slashed-mic icon). When they reconnect, it grabs the mic again.
- Turning it off releases the mic, and macOS returns to stereo once no other app is using the mic.

## Install

Requirements: macOS 14 or later on Apple silicon, and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh
```

This builds `~/Applications/TalkMode.app` and links the `talkmode` command into `~/.local/bin`. On first use, macOS asks for microphone access. Click **Allow**.

## Use

| Action | How |
|---|---|
| Toggle | **⌃⌥⌘T**, or click the menu-bar icon |
| Terminal | `talkmode on` · `talkmode off` · `talkmode toggle` |
| Status | `talkmode status`, or the menu-bar icon (🎙 on · 🎧 off · slashed mic = waiting for AirPods) |

```
$ talkmode status
talk mode: ON  mic held: Jonathan’s AirPods  input rate: 24000 Hz
```

State lives in `~/Library/Application Support/TalkMode/` (`desired`, `status.json`).

## Trade-offs while on

- All audio through the AirPods plays at headset quality.
- The orange mic-in-use dot stays visible.
- AirPods battery drains a little faster.

## Uninstall

```bash
pkill -f TalkMode.app; rm -rf ~/Applications/TalkMode.app ~/.local/bin/talkmode "$HOME/Library/Application Support/TalkMode"
```

Then remove TalkMode from System Settings → Privacy & Security → Microphone if you like.

## Tested

Tested on macOS 27.0 with AirPods (product ID 0x201B). Measured with Core Audio's nominal sample rate:

| Check | Result |
|---|---|
| On | Input and output at 24 kHz (headset) |
| Steady for 18 s | 6 of 6 samples at 24 kHz |
| Off | Back to 48 kHz stereo within about 4 s |
| AirPods in the case, then back in | Waiting, then on again with the mic re-held automatically |

## Related

Most AirPods tools go the other way: they force a different mic so the AirPods stay in stereo (for example [airpodssoundqualityfixer](https://github.com/milgra/airpodssoundqualityfixer)). [MicWarm](https://github.com/alexanderjmontague/micwarm) uses the same keep-the-mic-warm idea for dictation apps. TalkMode adds an on/off toggle, a hotkey, and a command-line interface.

## License

MIT
