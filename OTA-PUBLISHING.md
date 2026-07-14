# Pushing an update to everyone (OTA)

Wander updates itself over the tunnel using each user's Apple ID — no computer. Every install
checks `update.json` on launch; if you've published a higher `build`, the app downloads that
IPA, re-signs it with the user's Apple ID, and installs it (the app relaunches).

## To release a new version

1. **Bump the build number** in Xcode before building: raise `CURRENT_PROJECT_VERSION`
   (CFBundleVersion) — e.g. `1` → `2`. The installed copy must report the new number or it
   will keep offering the update.

2. **Build the unsigned IPA** the usual way (the app is signed on-device by each user, so ship
   it unsigned):
   ```
   # your normal build → ~/Desktop/Wander.ipa
   ```

3. **Upload** `Wander.ipa` to a GitHub Release (e.g. tag `v1.1`).

4. **Edit `update.json`** in the repo root and push it:
   ```json
   {
     "build": 2,
     "version": "1.1",
     "payloadURL": "https://github.com/faisal-nabulsi/Wander/releases/download/v1.1/Wander.ipa",
     "notes": "What's new in 1.1…"
   }
   ```

That's it. Within a launch or two, every user on an older build sees **Settings › Software
Update → Download & install**, or auto-notices it. Requirements to install mirror self-refresh:
the user must be **signed in to their Apple ID** and **connected to the tunnel**.

## Notes
- `payloadURL` must be the **unsigned** IPA (AltSign re-signs it per device).
- Updates are **pull** (iOS can't force-install); the app checks on launch and offers it.
- Same bundle id (`com.stik.stikdebug`) → it upgrades in place, keeping the user's data,
  license, and trial state (those live in the Keychain).
