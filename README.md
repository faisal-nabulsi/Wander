# Wander

### Set your iPhone's location to anywhere in the world — free, no jailbreak.

Teleport with a tap, roam with an on‑screen joystick, or drive a real road route at realistic speed. 100% on‑device. A free, open‑source alternative to **iMyFone AnyTo** and **Tenorshare iAnyGo**.

**🌐 Official site: [wanderspoofer.com](https://wanderspoofer.com)  ·  ⬇️ [Download](https://wanderspoofer.com/#download)  ·  💬 [Discord](https://discord.gg/gfHdsRXUVA)**

<p align="center">
  <img src="docs/screenshots/teleport.png" width="30%" alt="Teleport — tap the map and go"/>
  &nbsp;
  <img src="docs/screenshots/joystick.png" width="30%" alt="Joystick — move in real time"/>
  &nbsp;
  <img src="docs/screenshots/route.png" width="30%" alt="Route — drive a real road at realistic speed"/>
</p>

## Get Wander

Wander isn't on the App Store — you install it in a few minutes with the free **Wander Installer** for Mac. No jailbreak, no paid developer account.

1. **[Download from wanderspoofer.com](https://wanderspoofer.com/#download)** — grab the **Wander Installer (Mac)**. *(Prefer the raw app? Download [`Wander.ipa`](https://github.com/faisal-nabulsi/Wander/releases/latest) and sideload it your own way.)*
2. Plug in your iPhone, open the **Wander Installer**, sign in with your **free Apple ID**, and click **Install**. It signs and installs Wander onto your phone for you.
3. Turn on **Developer Mode** and install the free **LocalDevVPN** tunnel (full steps below).
4. Open Wander — it **refreshes itself over the air**, so you won't need the computer again.

👉 First time sideloading? Follow the **[Full setup guide](#full-setup-guide)** — about 10 minutes, once.

> 💻 **Prefer to spoof straight from your computer?** **Wander Desktop** (Mac) does everything from your Mac — teleport, joystick, routes, no phone install needed. **[Download it here](https://wanderspoofer.com/#download).**

---

## Features

- **Teleport** — search an address (or drop a pin on the map) and set your location instantly.
- **Joystick** — a live on‑screen stick that moves your location in real time; walk / run / drive speeds.
- **Route** — set a start, stops, and an end; Wander follows the real road route and plays it back. Choose **Realistic** (paces to the real ETA, slows for turns), **Speed limit**, or **Manual** speed.
- **Places** — save favourite spots, jump back to recent ones, or pick a famous landmark.
- **Natural jitter** — optional small random drift so a fixed location looks less robotic.
- **km/h ⇄ mph**, background keep‑alive, and a **Setup checklist** that tells you exactly what's missing before you spoof.

---

## Full setup guide

*First-time setup takes about **10 minutes** and needs a Mac once. After that, everyday use is just: **turn on the tunnel → open Wander**. Wander keeps itself refreshed, so you won't need the computer again. Do the steps in order — each one matters.*

**What you need**
- An iPhone on **iOS 17 or newer**, with a passcode set.
- A **Mac** — used once, for setup. *(Windows support is on the way — [ask on Discord](https://discord.gg/gfHdsRXUVA).)*
- A **free Apple ID** (your normal Apple account works fine).

### Step 1 — Install Wander on your iPhone (one time)
1. On the iPhone, install **LocalDevVPN** from the App Store (free). This is the secure "tunnel" Wander uses to talk to your phone.
2. On your Mac, download the **[Wander Installer](https://wanderspoofer.com/#download)** and open it.
3. Plug the iPhone into the Mac with a cable. On the iPhone, tap **Trust** and enter your passcode.
4. In the Wander Installer, sign in with your **free Apple ID** and click **Install Wander**. It creates the pairing file, signs, and installs everything automatically — just wait for it to finish.
5. On the iPhone: **Settings → General → VPN & Device Management →** tap your Apple ID under *Developer App* **→ Trust**.

### Step 2 — Turn on Developer Mode (one time)
This option stays **hidden until Wander is installed**, so do it now, after Step 1:
1. **Settings → Privacy & Security →** scroll to the very **bottom → Developer Mode →** turn it **On**.
2. Tap **Restart**.
3. **After the phone reboots and you unlock it**, a second popup appears — tap **Turn On** and enter your passcode. *(People miss this second step and think it failed — without it, Developer Mode isn't actually on.)*

### Step 3 — Switch it on and go
1. Open **LocalDevVPN → Connect** (keep it on whenever you use Wander).
2. Open **Wander**. Its built-in **Setup checklist** shows a ✓ or ✗ for each requirement. When they're all green, pick a mode and set your location. 🎉
   - **Pairing file not green?** In Wander: **Settings → Import pairing file** — or run `./tools/wander-pair.sh` from your Mac with the phone plugged in.

### ⚠️ The things people get wrong
1. **A free Apple ID signature lasts 7 days.** Wander **refreshes itself** — just open it (with the tunnel on) before the timer runs out. No computer needed.
2. **LocalDevVPN must be ON** every time you install, refresh, or spoof — not only the first time.
3. A free Apple ID allows only **3 sideloaded apps** at once.
4. **Installing Wander and turning on Developer Mode are two separate things** — you need both.
5. **Work- or school-managed iPhones** can block Developer Mode; use a personal phone.

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

- **"Tunnel connected" is red** → open LocalDevVPN and connect.
- **"Developer Disk Image" won't mount** → make sure the tunnel is connected and Developer Mode is on, then Re‑check.
- **Location won't set / pairing errors** → re‑import the pairing file (Settings → Import pairing file, or `./tools/wander-pair.sh`). Reinstalling the app clears the pairing.
- **Location reverts after ~2 hours** → that's an iOS background limit; reopen Wander to resume.

---

## Contact

- **Website:** [wanderspoofer.com](https://wanderspoofer.com)
- **Discord:** [join the server](https://discord.gg/gfHdsRXUVA)
- **Bugs / feature requests:** open an [issue](https://github.com/faisal-nabulsi/Wander/issues).
- **Email:** faisalnab25@gmail.com

Wander is free and open‑source. ⭐ the repo to follow along.

---

## Credits & License

Wander is an AGPL‑3.0 fork of [StikDebug](https://github.com/StephenDev0/StikDebug) and is powered by jkcoxson's [`idevice`](https://github.com/jkcoxson/idevice) library — huge thanks to those projects.

Licensed under the **GNU AGPL‑3.0**. See [LICENSE](LICENSE). If you distribute a modified version, you must make your source available under the same license.

*Use responsibly and legally. Spoofing your location may violate the Terms of Service of some apps and games.*
