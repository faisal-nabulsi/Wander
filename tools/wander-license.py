#!/usr/bin/env python3
"""
wander-license.py — RETIRED. Keyless lifetime license minting is deprecated.

Lifetime (and all Pro) now flows through the ACCOUNT: a Lemon Squeezy purchase
sets the account's plan to "pro", which the app validates online and which is
subject to the per-account DEVICE CAP (max devices per account). Keyless
Ed25519 tokens minted by this tool bypass that cap (whoever holds the key
unlocks unlimited devices) — exactly the account-sharing hole we closed, so we
no longer mint them.

To grant Pro now (comps, support, refunds-reversal), use an ACCOUNT path:
  - Preferred: a 100%-off Lemon Squeezy order/coupon for their email, OR
  - set licenses/{uid}.plan = "pro" in Firestore for their account uid/email.
Both honor the device cap.

Existing keyless keys already in the wild KEEP WORKING (the app still verifies
them via the embedded Ed25519 public key) — we only stop MINTING new ones.
This script refuses by default; pass --force-legacy for a documented one-off
that you accept BYPASSES the device cap (not recommended).
"""
import sys, os, json, base64, time

if "--force-legacy" not in sys.argv:
    sys.exit(
        "wander-license.py is RETIRED — keyless lifetime keys bypass the account device cap.\n"
        "Grant Pro via the account instead: a 100%-off Lemon Squeezy order, or set\n"
        "licenses/{uid}.plan='pro' in Firestore. Pass --force-legacy to override (not recommended)."
    )

# --- Legacy path (only with --force-legacy). Mints a keyless Ed25519 token that
#     bypasses the device cap. Kept solely for rare documented emergencies. ---
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

args = [a for a in sys.argv[1:] if a != "--force-legacy"]
keyfile = os.environ.get("WANDER_KEY", os.path.expanduser("~/Desktop/wander-license-private.key"))
who = args[0] if args else "customer"

try:
    raw = base64.b64decode(open(keyfile).read().strip())
except FileNotFoundError:
    sys.exit(f"Private key not found at {keyfile}. Set WANDER_KEY to its path.")

priv = Ed25519PrivateKey.from_private_bytes(raw)
payload = json.dumps({"e": who, "t": int(time.time())}, separators=(",", ":")).encode()
sig = priv.sign(payload)

def b64u(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")

sys.stderr.write("WARNING: minted a LEGACY keyless key that BYPASSES the account device cap.\n")
print(b64u(payload) + "." + b64u(sig))
