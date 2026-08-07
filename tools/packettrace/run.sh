#!/bin/zsh
# Re-runnable proof for the tunnel packet trace (TunnelProv/PacketTrace.swift +
# Wander/Device/PacketTraceReport.swift) AND for the provider's address rewrite
# (TunnelProv/PacketTunnelProvider.swift). Compiles the REAL sources on the host — only the App Group
# container lookup is swapped for an env-var path, since App Groups do not exist on macOS — and
# drives them with synthetic IPv4/IPv6 batches to prove the
# writer -> mmap file -> reader -> verdict chain, including the (a)/(b)/(c) discrimination.
#
# PacketTunnelProvider.swift is compiled here VERBATIM (NetworkExtension does have a macOS-host
# build, so it links; the provider is never instantiated — the rewrite is a static function). That
# means the v4-rewrite-* scenarios below test the SHIPPING rewrite rather than a transcription of it
# that could drift. See tools/packetmath for the checksum arithmetic behind those scenarios.
set -e
ROOT="${0:a:h}/../.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/TunnelProv/PacketTrace.swift" "$ROOT/TunnelProv/PacketTunnelProvider.swift" \
   "$ROOT/Wander/Device/PacketTraceReport.swift" "$WORK/"
cp "${0:a:h}/PacketTraceVerify.swift" "$WORK/main.swift"
python3 - "$WORK/PacketTrace.swift" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = """        for group in appGroupCandidates() {
            guard let container = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: group) else { continue }
            cachedGroup = group
            cachedPath = container.appendingPathComponent(fileName).path
            return cachedPath
        }
        return nil"""
new = """        if let override = ProcessInfo.processInfo.environment["WANDER_TRACE_PATH"] {
            cachedGroup = "harness"
            cachedPath = override
            return cachedPath
        }
        return nil"""
assert old in s, "container lookup moved — update run.sh"
open(p, "w").write(s.replace(old, new))
PY
swiftc -O "$WORK/PacketTrace.swift" "$WORK/PacketTunnelProvider.swift" \
       "$WORK/PacketTraceReport.swift" "$WORK/main.swift" -o "$WORK/tracetest"
rc=0
for sc in layout disarmed-is-a-noop a-no-packets a-ambiguous a-ipv6-only \
          v6-source-mismatch v6-full-swap v6-off-no-false-match b-no-match b-one-sided \
          c-full c-not-written ihl-and-short ring-wrap expiry disarm-stops-a-live-writer torn-record \
          v4-rewrite-both-match v4-rewrite-src-only v4-rewrite-dst-only v6-rewrite-strict; do
  rm -f "$WORK/trace.bin"
  WANDER_TRACE_PATH="$WORK/trace.bin" "$WORK/tracetest" $sc || rc=1
done
rm -f "$WORK/trace.bin"; WANDER_TRACE_PATH="$WORK/trace.bin" "$WORK/tracetest" full-report
[ "$1" = "--bench" ] && { rm -f "$WORK/trace.bin"; WANDER_TRACE_PATH="$WORK/trace.bin" "$WORK/tracetest" bench; }
echo "=== overall: $([ $rc -eq 0 ] && echo ALL GREEN || echo FAILURES) ==="
exit $rc
