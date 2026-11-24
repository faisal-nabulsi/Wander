# Pushing an update to everyone (OTA)

Wander updates itself over the tunnel using each user's Apple ID — no computer. Every install
checks `update.json` on launch; if you've published a higher `build`, the app downloads that
IPA, re-signs it with the user's Apple ID, and installs it (the app relaunches).

## To release a new version

```
./publish-ota.sh "What's new in this build"
```

then push this repo (the script prints the exact command). The script bumps the build number,
builds the unsigned IPA, **signs** the manifest, uploads the IPA to the GitHub release, and writes
`update.json` + `apps.json`. Push promptly: between the upload and the push, the old manifest's
hash no longer matches the re-uploaded IPA, so updates attempted in that gap are refused (safe).

## Signed manifests (since 2026-10-12)

The app only installs an update whose manifest is Ed25519-signed with the OTA key, and only if the
downloaded IPA matches the signed SHA-256, byte size and build number. An unsigned or tampered
`update.json` is ignored, as if there were no update. Write access to GitHub alone can no longer
push code to users.

- **Private key:** `~/.config/wander-secrets/wander-ota-signing.key` (override with
  `WANDER_OTA_KEY`). It's base64 of the raw 32-byte Ed25519 key. Keep it off GitHub and **back it
  up**. If it's lost, installed apps refuse every future OTA until users reinstall manually.
- **Public key:** `OTAIntegrity.otaSigningPublicKeyB64` in `Wander/Services/WanderUpdater.swift`.
  `publish-ota.sh` refuses to run when the private key is missing or doesn't match this constant.
- **Signer:** `tools/sign-ota-manifest.py` (needs Python `cryptography`; the script finds a
  `python3` that has it, or set `WANDER_PYTHON`). It adds `sha256`, `size` and `sig` to the manifest.
- **Signed message** (UTF-8, `\n`-separated, no trailing newline):
  `wander-ota-v1`, build, version, sha256 (lowercase hex), size, payloadURL. The payloadURL must be
  `https://`.
- **`notes` is NOT signed.** It's display-only, so you can fix a typo in `notes` without re-signing.
  Never hand-edit `build`, `version`, `payloadURL`, `sha256` or `size`. The signature covers them.
- **Rotating the key:** ship one more update signed with the OLD key whose build embeds the NEW
  public key. After that, sign with the new key.

## Notes
- `payloadURL` must be the **unsigned** IPA (AltSign re-signs it per device).
- Updates are **pull** (iOS can't force-install); the app checks on launch and offers it.
- Same bundle id (`com.stik.stikdebug`) → it upgrades in place, keeping the user's data,
  license, and trial state (those live in the Keychain).
- Builds from before the signing change don't verify anything. They install whatever the manifest
  names until they update to a signed-manifest build.
