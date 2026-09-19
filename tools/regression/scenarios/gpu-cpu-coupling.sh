#!/bin/sh
# gpu-cpu-coupling: exercises the Infinity CPU-to-GPU coupling path.
#
# Counter: "CPU->GPU coupling" in /proc/sys/kernel/infinity_stats.
# Incremented in drm_sched_entity_update_vruntime() (sched_rq.c) when the
# entity's owning task carries CPU-side interactivity signals:
#
#	p = pid_task(entity->infinity_pid, PIDTYPE_PID)
#	if (p && infinity_is_interactive_candidate(p)) {
#		if (p->infinity.futex_waiting) coupling++
#		if (p->infinity.ema == 0)      coupling++
#	}
#	if (coupling) { delta_ns reduced by min(50*coupling, 75)%; counter++ }
#
# and infinity_is_interactive_candidate() is
#
#	p->sched_class == &fair_sched_class && !task_has_idle_policy(p)
#
# Two phases:
#
#   POSITIVE -- N paced VAAPI encodes.  Each submitter sleeps between
#     frames, so its CPU EMA sits at 0 and its worker threads park on
#     futexes: both signals are live and the counter must climb.
#
#   NEGATIVE control -- the same workload under SCHED_IDLE.  That fails
#     the !task_has_idle_policy() half of the gate, so the counter must
#     stay (nearly) flat.  This is what separates "the coupling works"
#     from "the counter increments unconditionally".
#
# Gate: the fold is reached only from drm_sched_rq_pop_entity() under
# `drm_sched_policy == DRM_SCHED_POLICY_FAIR` (2); the module default is
# FIFO (1), where this counter can never move.
#
# Measured on the reference machine (Ryzen 5 5600H / amdgpu, 20 s runs):
# 1x -> 13, 4x -> 54, 8x -> 126 couplings; SCHED_IDLE control -> 0.

# constants
PARALLEL=4                # concurrent DRM entities; ~54 couplings measured
RATE=5                    # source fps -> paced submission, submitter idles
BURN_SECS=20
MIN_EVENTS=10             # sanity floor for the positive phase
DRI=/dev/dri/renderD128

STATS=/proc/sys/kernel/infinity_stats
POLICY=/sys/module/gpu_sched/parameters/sched_policy
NAME=gpu-cpu-coupling

read_counter() {
	awk -F'|' -v want="$1" '
		/^\|/ {
			name = $2; val = $3
			gsub(/^[ \t]+|[ \t]+$/, "", name)
			gsub(/^[ \t]+|[ \t]+$/, "", val)
			if (name == want) { print val; exit }
		}' "$STATS"
}

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

# Runs PARALLEL paced encodes; "$@" is an optional launcher prefix
# (e.g. chrt -i 0) and expands away when empty.
encode_all() {
	i=0
	while [ "$i" -lt "$PARALLEL" ]; do
		"$@" ffmpeg -hide_banner -loglevel error -re \
			-vaapi_device "$DRI" \
			-f lavfi -i "testsrc=size=640x480:rate=$RATE" \
			-vf format=nv12,hwupload -c:v h264_vaapi \
			-t "$BURN_SECS" -f null - >/dev/null 2>&1 &
		i=$((i + 1))
	done
	wait
	sleep 1
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

# --- positive phase: fair-class submitters ------------------------------
before=$(to_num "$(read_counter 'CPU->GPU coupling')")
encode_all
after=$(to_num "$(read_counter 'CPU->GPU coupling')")
pos=$((after - before))

if [ "$pos" -eq 0 ]; then
	echo "RESULT $NAME FAIL couplings 0 >=$MIN_EVENTS (no GPU jobs accounted -- VAAPI unavailable?)"
	exit 1
fi

# --- negative control: SCHED_IDLE submitters fail the gate --------------
neg=-1
if command -v chrt >/dev/null 2>&1; then
	before=$(to_num "$(read_counter 'CPU->GPU coupling')")
	encode_all chrt -i 0
	after=$(to_num "$(read_counter 'CPU->GPU coupling')")
	neg=$((after - before))
fi

if [ "$pos" -lt "$MIN_EVENTS" ]; then
	echo "RESULT $NAME FAIL couplings $pos >=$MIN_EVENTS (idle-control $neg)"
	exit 1
fi

# The control runs on a live system, so allow a little background noise
# from other DRM clients; it must stay far below the fair-class phase.
if [ "$neg" -ge 0 ] && [ "$neg" -gt $((pos / 4)) ]; then
	echo "RESULT $NAME FAIL idle-control-leaks $neg <=$((pos / 4)) (fair phase $pos; SCHED_IDLE must fail the gate)"
	exit 1
fi

echo "RESULT $NAME PASS couplings $pos >=$MIN_EVENTS (${PARALLEL}x; SCHED_IDLE control $neg)"
