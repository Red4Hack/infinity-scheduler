#!/bin/sh
# gpu-idle-compensation: exercises the Infinity GPU EMA idle-decay path.
#
# Counter: "Idle compensation" in /proc/sys/kernel/infinity_stats.
# Incremented in drm_sched_entity_update_vruntime() (sched_rq.c) when the
# gap since the entity's previous vruntime fold spans at least one
# INFINITY_GPU_EMA_HALFLIFE_NS (32 ms) period:
#
#	idle_ns = now - stats->gpu_time_last_active
#	periods = idle_ns / INFINITY_GPU_EMA_HALFLIFE_NS
#	if (periods) atomic64_inc(&infinity_gpu_idle_compensations)
#
# Two conditions must hold together, and both come straight from the code:
#
#   1. The fold must run at all.  drm_sched_rq_pop_entity() only reaches
#      drm_sched_entity_get_job_ts() -> the fold in its `if (next_job)`
#      branch; when an entity's queue drains, the `else` branch runs
#      save_vruntime() and no fold (hence no counter) happens.  So the
#      entity needs a backlog at pop time.
#   2. Consecutive folds of the SAME entity must be >32 ms apart.
#
# Those two pull in opposite directions for a single client -- a backlog
# means the entity is served back-to-back, which leaves no idle gap.  The
# resolution is CONCURRENCY: several entities competing for the GPU each
# keep a backlog while waiting their turn behind the others, so each one
# sees multi-frame gaps between its own folds.
#
# Measured on the reference machine (Ryzen 5 5600H / amdgpu, 20 s runs),
# which is why this scenario runs N parallel encodes rather than one:
#
#	1x  -re 5fps 640x480      idle=4
#	1x  -re 2fps 640x480      idle=6
#	1x  -re 15fps 1080p       idle=4
#	1x  no -re (backlog) 1080p idle=5
#	4x  -re 5fps              idle=10
#	8x  -re 5fps              idle=18   <- used here
#
# Note the first four rows: for a single client the rate, the resolution
# and even a saturated backlog make no difference. Concurrency does.
#
# Gate: the whole vruntime fold is reached only from
# drm_sched_rq_pop_entity() under `drm_sched_policy == DRM_SCHED_POLICY_FAIR`
# (2).  The module default is FIFO (1), where this counter can never move.

# constants
PARALLEL=8                # concurrent DRM entities (see table above)
RATE=5                    # source fps -> paced submission per client
BURN_SECS=20
MIN_EVENTS=10             # sanity floor; ~18 measured at PARALLEL=8
DRI=/dev/dri/renderD128

STATS=/proc/sys/kernel/infinity_stats
POLICY=/sys/module/gpu_sched/parameters/sched_policy
NAME=gpu-idle-compensation

# Reads one humanized counter cell out of the infinity_stats table.
read_counter() {
	awk -F'|' -v want="$1" '
		/^\|/ {
			name = $2; val = $3
			gsub(/^[ \t]+|[ \t]+$/, "", name)
			gsub(/^[ \t]+|[ \t]+$/, "", val)
			if (name == want) { print val; exit }
		}' "$STATS"
}

# "13.78K" -> 13780.  The table humanizes large values; deltas measured
# over a short run stay well inside the exact range.
to_num() {
	printf '%s\n' "$1" | awk '
		{
			v = $0; mult = 1
			if (v ~ /K$/) { mult = 1000;       sub(/K$/, "", v) }
			else if (v ~ /M$/) { mult = 1000000;    sub(/M$/, "", v) }
			else if (v ~ /G$/) { mult = 1000000000; sub(/G$/, "", v) }
			printf "%d\n", v * mult
		}'
}

[ -r "$STATS" ] || {
	echo "RESULT $NAME WARN no-stats 0 infinity_stats unreadable (stock kernel?)"
	exit 0
}
[ -e "$POLICY" ] || {
	echo "RESULT $NAME WARN no-drm-sched 0 gpu_sched not loaded (driver has no DRM scheduler, e.g. i915)"
	exit 0
}

policy=$(cat "$POLICY" 2>/dev/null)
[ "$policy" = 2 ] || {
	echo "RESULT $NAME WARN policy-$policy 0 needs gpu_sched.sched_policy=2 (FAIR); the vruntime fold never runs under RR/FIFO"
	exit 0
}

[ -e "$DRI" ] || {
	echo "RESULT $NAME WARN no-render-node 0 $DRI missing"
	exit 0
}
command -v ffmpeg >/dev/null 2>&1 || {
	echo "RESULT $NAME WARN missing ffmpeg 0"
	exit 0
}

before=$(to_num "$(read_counter 'Idle compensation')")

# N concurrent paced encodes: each is one DRM entity that keeps a backlog
# while the others are being served, producing >32 ms gaps between its own
# folds.
i=0
while [ "$i" -lt "$PARALLEL" ]; do
	ffmpeg -hide_banner -loglevel error -re \
		-vaapi_device "$DRI" \
		-f lavfi -i "testsrc=size=640x480:rate=$RATE" \
		-vf format=nv12,hwupload -c:v h264_vaapi \
		-t "$BURN_SECS" -f null - >/dev/null 2>&1 &
	i=$((i + 1))
done
wait
sleep 1

after=$(to_num "$(read_counter 'Idle compensation')")
delta=$((after - before))

if [ "$delta" -ge "$MIN_EVENTS" ]; then
	echo "RESULT $NAME PASS idle-decays $delta >=$MIN_EVENTS (${PARALLEL}x ${BURN_SECS}s @ ${RATE}fps)"
else
	echo "RESULT $NAME FAIL idle-decays $delta >=$MIN_EVENTS (${PARALLEL}x ${BURN_SECS}s @ ${RATE}fps)"
	exit 1
fi
