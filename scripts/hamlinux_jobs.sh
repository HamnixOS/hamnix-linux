# scripts/hamlinux_jobs.sh — how many workers this tree is allowed to run.
#
# Sourced by every script here that fans out. It exists because this repo is
# built on a machine somebody else is USING: a full sweep compiles 366
# programs, and defaulting to `nproc` took 6 of 12 cores and made a game
# stutter. The machine's owner set the policy: cap the WORKERS.
#
# Workers, not cores. Nothing here pins CPU affinity — the scheduler is better
# at placing work than we are, and pinning to N cores also means REFUSING the
# other cores when the machine is idle. Limiting how many jobs run at once
# bounds the load without ever making an idle machine slower.
#
# HAMLINUX_JOBS overrides. Set it higher on a build box with nobody on it.
HAMLINUX_JOBS="${HAMLINUX_JOBS:-4}"

# `nice` on top, because the cap bounds how much we take and nice decides who
# wins when we and the owner want the same core at the same time. The two do
# different jobs and neither replaces the other.
HAMLINUX_NICE="${HAMLINUX_NICE:-15}"
