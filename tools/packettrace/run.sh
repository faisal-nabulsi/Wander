#!/bin/zsh
# Re-runnable proof for the tunnel packet trace (TunnelProv/PacketTrace.swift +
# Wander/Device/PacketTraceReport.swift). Compiles the REAL sources on the host — only the App Group
# container lookup is swapped for an env-var path, since App Groups do not exist on macOS — and
# drives them with synthetic IPv4/IPv6 batches to prove the
# writer -> mmap file -> reader -> verdict chain, including the (a)/(b)/(c) discrimination.
set -e
ROOT="${0:a:h}/../.."
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$ROOT/TunnelProv/PacketTrace.swift" "$ROOT/Wander/Device/PacketTraceReport.swift" "$WORK/"
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
swiftc -O "$WORK/PacketTrace.swift" "$WORK/PacketTraceReport.swift" "$WORK/main.swift" -o "$WORK/tracetest"
rc=0
for sc in layout disarmed-is-a-noop a-no-packets a-ambiguous a-ipv6-only b-no-match b-one-sided \
          c-full c-not-written ihl-and-short ring-wrap expiry disarm-stops-a-live-writer torn-record; do
  rm -f "$WORK/trace.bin"
  WANDER_TRACE_PATH="$WORK/trace.bin" "$WORK/tracetest" $sc || rc=1
done
rm -f "$WORK/trace.bin"; WANDER_TRACE_PATH="$WORK/trace.bin" "$WORK/tracetest" full-report
[ "$1" = "--bench" ] && { rm -f "$WORK/trace.bin"; WANDER_TRACE_PATH="$WORK/trace.bin" "$WORK/tracetest" bench; }
echo "=== overall: $([ $rc -eq 0 ] && echo ALL GREEN || echo FAILURES) ==="
exit $rc
