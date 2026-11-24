#!/usr/bin/env python3
"""
sign-ota-manifest.py — produce a SIGNED update.json for Wander's in-app OTA updater.

The app (Wander/Services/WanderUpdater.swift, enum OTAIntegrity) refuses any manifest whose
Ed25519 signature doesn't verify against the public key compiled into it, and refuses any
downloaded IPA whose byte size or SHA-256 doesn't match the signed values. So whoever controls
the GitHub repo / release assets can no longer push a build to every device: they'd also need
the private key, which lives OFF GitHub on the publishing Mac.

Signed message (UTF-8, fields joined by a single "\\n", NO trailing newline):

    wander-ota-v1
    <build>        plain base-10 integer, e.g. 158
    <version>      e.g. 1.0
    <sha256>       64 lowercase hex chars of the IPA
    <size>         IPA byte count, plain base-10 integer
    <payloadURL>   must be https://

`notes` is DISPLAY-ONLY and NOT signed (it can be edited without re-signing; it never
influences what gets installed). Keep that in mind: it is shown in the app as release notes.

Usage:
  # sign (writes JSON to --out, or stdout)
  sign-ota-manifest.py --ipa Wander.ipa --build 158 --version 1.0 \\
      --payload-url https://github.com/faisal-nabulsi/Wander/releases/latest/download/Wander.ipa \\
      --notes "What's new" --out update.json \\
      --expect-pubkey-from Wander/Services/WanderUpdater.swift

  # preflight only: key loads and matches the public key compiled into the app
  sign-ota-manifest.py --check-key --expect-pubkey-from Wander/Services/WanderUpdater.swift

Key: env WANDER_OTA_KEY, default ~/.config/wander-secrets/wander-ota-signing.key
     (base64 of the raw 32-byte Ed25519 private key — same format as the license key).
Requires: the `cryptography` package.
"""
import argparse
import base64
import hashlib
import json
import os
import re
import stat
import sys

DOMAIN = "wander-ota-v1"
DEFAULT_KEY = "~/.config/wander-secrets/wander-ota-signing.key"
SWIFT_CONST = "otaSigningPublicKeyB64"
# Everything Swift's Character.isNewline accepts; the app rejects these in version/payloadURL too.
NEWLINES = "\n\r\x0b\x0c\x85\u2028\u2029"

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives import serialization
    from cryptography.exceptions import InvalidSignature
except ImportError:
    sys.exit("FATAL: the Python `cryptography` package is missing for " + sys.executable +
             "\n  install it:  " + sys.executable + " -m pip install cryptography")


def die(msg):
    sys.exit("FATAL: " + msg)


def canonical_message(build, version, sha256_hex, size, payload_url):
    """Byte-identical to OTAIntegrity.canonicalMessage in WanderUpdater.swift."""
    return "\n".join([DOMAIN, str(build), version, sha256_hex, str(size), payload_url]).encode("utf-8")


def load_key():
    path = os.path.expanduser(os.environ.get("WANDER_OTA_KEY", DEFAULT_KEY))
    if not os.path.isfile(path):
        die(f"OTA signing key not found at {path}\n"
            "  Every OTA manifest must be signed or the app refuses the update.\n"
            "  Restore the key from your backup, or point WANDER_OTA_KEY at it.")
    mode = os.stat(path).st_mode
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        sys.stderr.write(f"WARN: {path} is readable by group/others — run: chmod 600 {path}\n")
    try:
        raw = base64.b64decode(open(path).read().strip(), validate=True)
        if len(raw) != 32:
            raise ValueError(f"expected 32 bytes, got {len(raw)}")
        return Ed25519PrivateKey.from_private_bytes(raw)
    except Exception as e:  # never echo key material
        die(f"could not parse OTA signing key at {path} ({type(e).__name__}: {e})")


def pubkey_b64(priv):
    raw = priv.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return base64.b64encode(raw).decode()


def expected_pubkey(swift_path):
    try:
        src = open(swift_path, encoding="utf-8").read()
    except OSError as e:
        die(f"can't read {swift_path}: {e}")
    m = re.search(SWIFT_CONST + r'\s*=\s*"([A-Za-z0-9+/=]+)"', src)
    if not m:
        die(f"couldn't find `{SWIFT_CONST} = \"...\"` in {swift_path}")
    return m.group(1)


def check_pubkey(priv, args):
    if not args.expect_pubkey_from:
        return
    want = expected_pubkey(args.expect_pubkey_from)
    have = pubkey_b64(priv)
    if want != have:
        die("the OTA signing key does NOT match the public key compiled into the app\n"
            f"  app ({args.expect_pubkey_from}): {want}\n"
            f"  key ({os.environ.get('WANDER_OTA_KEY', DEFAULT_KEY)}): {have}\n"
            "  Publishing with this key would make every installed build refuse the update.")


def file_digest(path):
    h = hashlib.sha256()
    size = 0
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
            size += len(chunk)
    return h.hexdigest(), size


def main():
    ap = argparse.ArgumentParser(description="Sign Wander's OTA update.json (Ed25519).")
    ap.add_argument("--check-key", action="store_true", help="only verify the key loads (and matches the app)")
    ap.add_argument("--ipa")
    ap.add_argument("--build", type=int)
    ap.add_argument("--version")
    ap.add_argument("--payload-url")
    ap.add_argument("--notes", default=None, help="display-only, NOT signed")
    ap.add_argument("--out", help="write the manifest here (default: stdout)")
    ap.add_argument("--expect-pubkey-from", help="Swift file holding " + SWIFT_CONST + "; refuse on mismatch")
    args = ap.parse_args()

    priv = load_key()
    check_pubkey(priv, args)
    if args.check_key:
        print(f"OTA signing key OK (public key {pubkey_b64(priv)})")
        return

    missing = [n for n in ("ipa", "build", "version", "payload_url") if getattr(args, n) in (None, "")]
    if missing:
        die("missing required argument(s): " + ", ".join("--" + m.replace("_", "-") for m in missing))
    if args.build <= 0:
        die("--build must be a positive integer")
    for name, val in (("version", args.version), ("payload-url", args.payload_url)):
        if any(c in NEWLINES for c in val):
            die(f"--{name} must not contain a newline (it would make the signed message ambiguous)")
    if not args.payload_url.startswith("https://") or any(c.isspace() for c in args.payload_url):
        die("--payload-url must be an https:// URL with no whitespace (the app refuses anything else)")
    if not os.path.isfile(args.ipa):
        die(f"IPA not found: {args.ipa}")

    sha256_hex, size = file_digest(args.ipa)
    if size == 0:
        die(f"IPA is empty: {args.ipa}")

    msg = canonical_message(args.build, args.version, sha256_hex, size, args.payload_url)
    sig = priv.sign(msg)
    try:  # self-check before anything is written
        priv.public_key().verify(sig, msg)
    except InvalidSignature:
        die("self-verification of the fresh signature failed")

    manifest = {
        "build": args.build,
        "version": args.version,
        "payloadURL": args.payload_url,
        "notes": args.notes if args.notes is not None else "",
        "sha256": sha256_hex,
        "size": size,
        "sig": base64.b64encode(sig).decode(),
    }
    text = json.dumps(manifest, indent=2, ensure_ascii=False) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            f.write(text)
        sys.stderr.write(f"signed manifest -> {args.out}: build {args.build}, {size} bytes, sha256 {sha256_hex}\n")
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
