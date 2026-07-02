# Wander

**Free location spoofing for iPhone — no jailbreak, no paid software.**

Wander sets your iPhone's GPS to anywhere in the world. Drop a pin and teleport, walk around with an on‑screen joystick, or drive a real road route at realistic speed. It runs entirely on‑device.

> Wander is a free, open‑source alternative to paid tools like iMyFone AnyTo and Tenorshare iAnyGo.

---

## Features

- **Teleport** — search an address (or drop a pin on the map) and set your location instantly.
- **Joystick** — a live on‑screen stick that moves your location in real time; walk / run / drive speeds.
- **Route** — set a start, stops, and an end; Wander follows the real road route and plays it back. Choose **Realistic** (paces to the real ETA, slows for turns), **Speed limit**, or **Manual** speed.
- **Places** — save favourite spots, jump back to recent ones, or pick a famous landmark.
- **Natural jitter** — optional small random drift so a fixed location looks less robotic.
- **km/h ⇄ mph**, background keep‑alive, and a **Setup checklist** that tells you exactly what's missing before you spoof.

---

## Requirements

- An iPhone on **iOS 17 or later** (built and tested against iOS 26).
- A Mac or PC once, to install the app and create a pairing file.
- **Developer Mode** enabled on the iPhone (*Settings → Privacy & Security → Developer Mode*).
- A way to sideload an unsigned app (a free **Apple ID** works).

Location simulation on iOS 17+ works by talking to the device's own developer services over a small on‑device tunnel. Wander needs three things in place: **the app**, **a tunnel**, and **a pairing file**. The in‑app *Setup checklist* checks all of them.

---

## Setup

The whole flow is: **install → connect a tunnel → add a pairing file → open Wander.**

### 1. Install Wander
Sideload `Wander.ipa` with **[SideStore](https://sidestore.io)** or **AltStore** using your Apple ID. (SideStore is recommended — it refreshes the app automatically so you don't have to reinstall every 7 days.)

### 2. Connect a tunnel
Wander needs a loopback tunnel to reach the device's developer services.

- **Free Apple ID:** install the free **[LocalDevVPN](https://apps.apple.com/us/app/localdevvpn/id6755608044)** app and tap Connect. (Apple only allows the *built‑in* tunnel on paid developer accounts.)
- **Paid Apple Developer account ($99/yr):** enable Wander's own **built‑in tunnel** in *Settings → Wander Tunnel* and skip LocalDevVPN entirely.

### 3. Add a pairing file
Wander needs a pairing file for your device (the same kind SideStore/AltStore use).

- Easiest: run the included helper from your computer with the iPhone plugged in:
  ```bash
  ./tools/wander-pair.sh
  ```
  It grabs the pairing file and drops it into Wander for you.
- Or, in the app: **Settings → Import pairing file** and pick your pairing file.

### 4. Enable Developer Mode
*Settings → Privacy & Security → Developer Mode → On*, then restart the iPhone.

### 5. Open Wander
The **Setup checklist** appears on first launch and shows a ✓ or ✗ for each requirement. Once everything is green, pick a mode and go.

---

## Usage

| Mode | How to use |
|------|-----------|
| **Teleport** | Search an address, or move the map so the crosshair is on your spot, tap **Set pin here**, then **Simulate**. Tap **Move here** to reposition, **Stop** to end. |
| **Joystick** | Set a start point, then drag the stick — direction steers, distance sets speed. |
| **Route** | Add points (search or crosshair), tap **Preview**, then **Drive**. Pause / resume and change playback speed while driving. |
| **Places** | Tap any saved, recent, or landmark location to jump there and start simulating. |

The global **Stop** (in any mode and in Settings) clears the simulated location and returns you to your real GPS. iOS pauses a background simulation after about 2 hours — the optional reminder nudges you to reopen the app, but only while you're actively simulating.

---

## Build from source

```bash
git clone https://github.com/faisal-nabulsi/Wander.git
cd Wander
open Wander.xcodeproj
```
Build the **Wander** scheme in Xcode 16+. For an unsigned IPA:
```bash
xcodebuild -project Wander.xcodeproj -scheme Wander -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
# then wrap the built .app in a Payload/ folder and zip it to Wander.ipa
```

---

## Troubleshooting

- **"Tunnel connected" is red** → open LocalDevVPN (or the built‑in tunnel) and connect.
- **"Developer Disk Image" won't mount** → make sure the tunnel is connected and Developer Mode is on, then Re‑check.
- **Location won't set / pairing errors** → re‑import the pairing file (Settings → Import pairing file, or `./tools/wander-pair.sh`). Reinstalling the app clears the pairing; a SideStore *refresh* does not.
- **Location reverts after ~2 hours** → that's an iOS background limit; reopen Wander to resume.

---

## Contact

- **Bugs / feature requests:** open an [issue](https://github.com/faisal-nabulsi/Wander/issues).
- **Email:** faisalnab25@gmail.com
- **Discord:** `naboosie`

Wander is free. If it helps you, a donation link will be added here soon. ⭐ the repo to follow along.

---

## Credits & License

Wander is an AGPL‑3.0 fork of [StikDebug](https://github.com/StephenDev0/StikDebug) and is powered by jkcoxson's [`idevice`](https://github.com/jkcoxson/idevice) library — huge thanks to those projects.

Licensed under the **GNU AGPL‑3.0**. See [LICENSE](LICENSE). If you distribute a modified version, you must make your source available under the same license.

*Use responsibly and legally. Spoofing your location may violate the Terms of Service of some apps and games.*
