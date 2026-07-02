#!/usr/bin/env python3
"""
wander-license.py — mint a Wander license key.

A license key is an Ed25519-signed token the app verifies offline against the
public key embedded in Wander. Only the holder of the private key can create
valid keys, so they can't be forged.

Setup (one time):
    pip install cryptography

Usage:
    ./wander-license.py buyer@example.com
    WANDER_KEY=/path/to/wander-license-private.key ./wander-license.py buyer@example.com

The private key defaults to ~/Desktop/wander-license-private.key.
KEEP THE PRIVATE KEY SECRET — never commit it. Anyone with it can mint keys.

To go paid: set "locked": true in config.json (and push it). Every installed copy
locks on next launch; customers unlock by pasting the key you mint here.
"""
import sys, os, json, base64, time
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

keyfile = os.environ.get("WANDER_KEY", os.path.expanduser("~/Desktop/wander-license-private.key"))
who = sys.argv[1] if len(sys.argv) > 1 else "customer"

try:
    raw = base64.b64decode(open(keyfile).read().strip())
except FileNotFoundError:
    sys.exit(f"Private key not found at {keyfile}. Set WANDER_KEY to its path.")

priv = Ed25519PrivateKey.from_private_bytes(raw)
payload = json.dumps({"e": who, "t": int(time.time())}, separators=(",", ":")).encode()
sig = priv.sign(payload)

def b64u(b):
    return base64.urlsafe_b64encode(b).decode().rstrip("=")

print(b64u(payload) + "." + b64u(sig))
