#!/usr/bin/env bash
#
# Summarise the simulator crash reports left behind by a failed iOS test run.
#
# xcodebuild reports a host-app crash only as "Crash: KnotQMobile (<pid>)
# <external symbol>", which names neither the signal nor a frame. The simulator
# writes a full .ips report for the crashed process to the *host's*
# DiagnosticReports directory; this prints the part of it that identifies the
# bug — the exception, the termination reason, the Apple "additional
# information" string (which carries Swift runtime failure messages) and the
# faulting thread's backtrace. Dumping the raw .ips instead is useless: a single
# report is hundreds of kilobytes of per-thread register state and the faulting
# thread is rarely in the first few.
set -uo pipefail

shopt -s nullglob
reports=("$HOME/Library/Logs/DiagnosticReports"/KnotQMobile*.ips)
if [ "${#reports[@]}" -eq 0 ]; then
  echo "No KnotQMobile crash report was written; the failure was not a host-app crash."
  exit 0
fi

for report in "${reports[@]}"; do
  echo "::group::$report"
  python3 - "$report" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8", errors="replace") as handle:
    text = handle.read()

# An .ips is a one-line JSON header followed by a JSON body.
header, _, body = text.partition("\n")
try:
    crash = json.loads(body)
except json.JSONDecodeError as error:
    print(f"could not parse {path}: {error}")
    print(text[:4000])
    sys.exit(0)

print("header:", header.strip())
for key in ("exception", "termination", "asi", "asiBacktraces", "isCorpse", "vmregioninfo"):
    if key in crash:
        print(f"{key}: {json.dumps(crash[key])[:4000]}")

threads = crash.get("threads", [])
faulting = crash.get("faultingThread")


def show(index, thread):
    name = thread.get("name") or thread.get("queue") or ""
    print(f"\n-- thread {index} {name}".rstrip())
    for frame in thread.get("frames", [])[:40]:
        symbol = frame.get("symbol", f"<image {frame.get('imageIndex')}>")
        source = frame.get("sourceFile")
        line = frame.get("sourceLine")
        where = f"  ({source}:{line})" if source and line else ""
        print(f"   {symbol}{where}")


if isinstance(faulting, int) and 0 <= faulting < len(threads):
    print(f"\nfaulting thread index: {faulting}")
    show(faulting, threads[faulting])
else:
    print(f"\nfaulting thread index {faulting} not in the report; printing every thread")
    for index, thread in enumerate(threads):
        show(index, thread)

# The main thread is worth seeing whenever it is not the one that crashed: a
# main-actor deadlock shows up there, not in the thread that finally trapped.
if faulting != 0 and threads:
    show(0, threads[0])
PY
  echo "::endgroup::"
done
