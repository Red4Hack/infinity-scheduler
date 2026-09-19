#!/bin/sh
# rt: cyclictest with a rogue same-priority SCHED_FIFO busy loop. Without
# the v4.7+ RT safety valve the rogue starves the probe (it never sleeps);
# with the valve the probe is rotated in periodically. Max latency with the
# rogue is the metric; the delta against the no-rogue run is the signal.

# constants
PRIO=80
INTERVAL_US=1000
LOOPS=100000
ROGUE_MAX_FLOOR=50000     # us; valve requeues at most once per 5ms, so a
                          # few-ms probe wait is expected under the rogue

command -v cyclictest >/dev/null 2>&1 || { echo "RESULT rt WARN missing cyclictest 0"; exit 0; }
command -v chrt >/dev/null 2>&1 || { echo "RESULT rt WARN missing chrt 0"; exit 0; }
[ "$(id -u)" -eq 0 ] || { echo "RESULT rt WARN needs-root 0"; exit 0; }

# Parse the FINAL cyclictest summary line.  cyclictest prints a live
# progress line every update, and the first one carries C:0 / Max:0 -- an
# awk that exits on the first match therefore always reported 0 and the
# scenario always passed.  -q suppresses the progress output and the awk
# below keeps the LAST match instead of exiting on the first.
get_max() {
	awk '/^T: /{for (i = 1; i <= NF; i++) if ($i == "Max:") m = $(i + 1)} END {print m}'
}

# no-rogue baseline
base=$(cyclictest -q -t 1 -p "$PRIO" -i "$INTERVAL_US" -l "$LOOPS" 2>&1 | get_max)
[ -z "$base" ] && base=0

# rogue at the same FIFO priority, busy-looping forever
chrt -f "$PRIO" sh -c 'while :; do :; done' &
rogue=$!
sleep 1

max=$(cyclictest -q -t 1 -p "$PRIO" -i "$INTERVAL_US" -l "$LOOPS" 2>&1 | get_max)

kill "$rogue" 2>/dev/null
wait "$rogue" 2>/dev/null

if [ -z "$max" ]; then
	echo "RESULT rt FAIL no-max 0 cyclictest-parse-error"
	exit 1
fi
if [ "$max" -lt "$ROGUE_MAX_FLOOR" ]; then
	echo "RESULT rt PASS rogue-max-us $max <$ROGUE_MAX_FLOOR (baseline $base)"
else
	echo "RESULT rt FAIL rogue-max-us $max <$ROGUE_MAX_FLOOR (baseline $base)"
	exit 1
fi
