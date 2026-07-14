<div align="center">

<a href="https://wanderspoofer.com">
  <img src="https://wanderspoofer.com/wander-logo.png" width="120" alt="Wander logo"/>
</a>

# Wander

### Set your iPhone's location to anywhere on Earth — free, open-source, no jailbreak.

Teleport with a tap, roam with a live on-screen joystick, or drive a real road route at realistic speed. The free alternative to paid apps like **iMyFone AnyTo** and **Tenorshare iAnyGo**.

<br/>

[![Website](https://img.shields.io/badge/🌐_Website-wanderspoofer.com-4C8BF5?style=for-the-badge)](https://wanderspoofer.com)
[![Download](https://img.shields.io/badge/⬇️_Download-Free-22C55E?style=for-the-badge)](https://wanderspoofer.com/#download)
[![Discord](https://img.shields.io/badge/💬_Discord-Join-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/gfHdsRXUVA)

[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg?style=flat-square)](LICENSE)
![Platform](https://img.shields.io/badge/platform-iOS_·_Android_·_macOS_·_Windows-lightgrey?style=flat-square)
[![GitHub stars](https://img.shields.io/github/stars/faisal-nabulsi/Wander?style=flat-square&label=Stars)](https://github.com/faisal-nabulsi/Wander/stargazers)
[![No jailbreak](https://img.shields.io/badge/jailbreak-not_required-success?style=flat-square)](https://wanderspoofer.com)

<br/>

### 👉 [**⬇️ Download at wanderspoofer.com**](https://wanderspoofer.com/#download) &nbsp;·&nbsp; [**⭐ Star this repo**](https://github.com/faisal-nabulsi/Wander)

**Everything — the app, all downloads, and the 2-minute setup guide — lives at [wanderspoofer.com](https://wanderspoofer.com).**

<br/>

<img src="https://wanderspoofer.com/og-image.png" width="80%" alt="Wander — teleport, joystick, and route modes on iPhone"/>

</div>

---

## ✨ Features

- 📍 **Teleport** — search an address or drop a pin and set your location instantly.
- 🕹️ **Joystick** — a live on-screen stick that walks, runs, or drives your location in real time.
- 🛣️ **Routes** — multi-stop trips that follow the real road with realistic **speed & ETA** (paces to the real arrival time, slows for turns).
- 🎮 **PoGo jump-teleport** — long-distance hops with a built-in **cooldown timer** so you play it safe.
- 📂 **GPX import** — bring your own tracks and replay them.
- 🌫️ **Realistic GPS jitter** — subtle random drift so a fixed spot never looks robotic.
- 📶 **Works on cellular** — no Wi-Fi required.
- 🔓 **No jailbreak** — runs on a normal, up-to-date iPhone.
- 🔄 **Over-the-air self-updates** — set it up once; it refreshes itself, no computer needed again.

Start with a **free trial**. **Wander Pro** unlocks the movement modes (joystick, routes, and more).

---

## ⚖️ Wander vs. the paid apps

| | **Wander** | iMyFone AnyTo | Tenorshare iAnyGo |
|---|:---:|:---:|:---:|
| **Price** | ✅ **Free** | 💰 Paid | 💰 Paid |
| **Open source** | ✅ AGPL-3.0 | ❌ | ❌ |
| **No jailbreak** | ✅ | ✅ | ✅ |
| **Teleport** | ✅ | ✅ | ✅ |
| **Live joystick** | ✅ | ✅ | ✅ |
| **Multi-stop routes** | ✅ | ✅ | ✅ |
| **GPX import** | ✅ | ⚠️ | ⚠️ |
| **Works on cellular (no Wi-Fi)** | ✅ | ⚠️ | ⚠️ |
| **iOS · Android · macOS · Windows** | ✅ | ⚠️ | ⚠️ |
| **Over-the-air self-updates** | ✅ | ❌ | ❌ |

---

## ⬇️ Get Wander — in 2 minutes

Wander isn't on the App Store, but installing it is quick and needs **no jailbreak and no paid developer account**.

### 👉 [**Get it in ~2 minutes at wanderspoofer.com**](https://wanderspoofer.com/#download)

The site walks you through the whole thing with the free **Wander Installer** and always has the latest build. Prefer to grab the raw app? [`Wander.ipa`](https://github.com/faisal-nabulsi/Wander/releases/latest) is on the Releases page.

> ⚠️ **First launch — trust the developer.** The first time you tap Wander, iPhone shows **"Untrusted Developer"** and won't open it (normal for any sideloaded app). Fix it once: **Settings → General → VPN & Device Management** → tap your **Apple ID email** under *Developer App* → **Trust**. Then enable **Settings → Privacy & Security → Developer Mode** when prompted (it only appears after Wander is installed). Wander opens normally from then on.

> 💻 **Prefer to spoof straight from your computer?** **Wander Desktop** (Mac & Windows) teleports, joysticks, and drives routes right from your desktop — [download it at wanderspoofer.com](https://wanderspoofer.com/#download).

---

## 💬 Community & support

- 🌐 **Website & downloads:** [wanderspoofer.com](https://wanderspoofer.com)
- 💬 **Discord:** [join the server](https://discord.gg/gfHdsRXUVA) — setup help, updates, and requests.
- 🐛 **Bugs / feature requests:** open an [issue](https://github.com/faisal-nabulsi/Wander/issues).

---

## 🤔 Why Wander?

The other location spoofers work, but they lock movement modes behind a subscription and ship closed-source binaries. Wander is **free and open under AGPL-3.0**: teleport, joystick, and routes on iPhone, Android, Mac, and Windows — no jailbreak, no monthly bill. You can read every line, build it yourself, and see exactly what runs on your phone.

---

## 🛠️ Build from source

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

## 📜 Credits & License

Wander is an AGPL-3.0 fork of [StikDebug](https://github.com/StephenDev0/StikDebug) and is powered by jkcoxson's [`idevice`](https://github.com/jkcoxson/idevice) library — huge thanks to those projects.

Licensed under the **GNU AGPL-3.0**. See [LICENSE](LICENSE). If you distribute a modified version, you must make your source available under the same license.

*Use responsibly and legally. Spoofing your location may violate the Terms of Service of some apps and games.*

---

<div align="center">

### ⭐ Star this repo if it saved you from paying for AnyTo or iAnyGo.

**[🌐 wanderspoofer.com](https://wanderspoofer.com)** &nbsp;·&nbsp; **[⬇️ Download](https://wanderspoofer.com/#download)** &nbsp;·&nbsp; **[💬 Discord](https://discord.gg/gfHdsRXUVA)**

</div>
