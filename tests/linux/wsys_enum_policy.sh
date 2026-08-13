#!/usr/bin/env bash
# wsys_enum_policy.sh — WHO MAY LEARN WHICH WINDOWS EXIST.
#
# WHAT THIS FILE USED TO BE, AND WHY IT CHANGED SHAPE
# ===================================================
# This gate was written RED, before the file server existed, and it said:
#
#     enumpol: FAIL a process owning NO window enumerated window 2 ("2 win2").
#
# An ordinary `cat`, owning nothing, read the whole window list. That was never
# a missing check. /dev/wsys is implemented IN-PROCESS -- the window system is
# linked into every binary -- so the reader's own code answered from shared
# memory and there was nowhere a policy could live. The fix could only ever be
# a MEDIATOR, and stage 4 of docs/wsys_server_design.md is that mediator for
# reads.
#
# So the assertion has not been softened, it has been PAIRED. The old single
# arm is now the RED arm and it must still FAIL-OPEN -- the unrouted read must
# still hand a window-less stranger the full list, because that is the state of
# the tree until WSYS_VERSION is bumped and the in-process path is removed, and
# because a red arm that has quietly gone green makes the green arm
# unattributable. A gate that is green in every configuration proves nothing:
# it is equally green against a server that checks nothing.
#
#   RED    (HAMWSYS_SERVER unset) a window-less uid-1002 process reads the
#          victim's title out of shared memory. MUST SUCCEED.
#   GREEN  (HAMWSYS_SERVER=1) the identical process, identical uid, identical
#          file, gets an EMPTY list from the read server. MUST BE EMPTY.
#
# WHY TWO UIDS, AND WHY THIS GATE CANNOT BE RUN AS ONE
# ====================================================
# The policy grants the full list to the HOST OWNER -- the uid that owns the
# segment -- exactly as devwsys grants that uid everything else. An offscreen
# gate run as a single uid IS the host owner, so its "stranger" would be
# granted the list correctly and the gate would report the policy absent when
# it was present. This is the same trap that made stage 2's first identity
# result wrong, written up in tests/linux/wsys_srv_identity.sh. So: `unshare -U
# --map-users` with three ids out of /etc/subuid, wsysd as 1001 (which is what
# MAKES 1001 the host owner), the victim as 1001 and the snooper as 1002.
#
# THE POLICY, AND THE ARM THAT KEEPS IT HONEST
# ============================================
# The rule implemented in user/linux-wsys.c (srd_enum_tier) is: the full list
# to the host owner, and to any caller that ALREADY OWNS A WINDOW; an empty
# list to everybody else. The obvious way to fake that is to answer on uid
# alone -- 1001 yes, everyone else no -- which would pass a red/green pair and
# would break the taskbar on a real desktop, where the panel runs as uid 1001
# and the compositor as the host owner. So there is an arm for it: a uid-1002
# process THAT OWNS A WINDOW must get the full list, including the victim's
# title, through the same server that just refused a window-less uid-1002
# process. If enumeration were uid-gated that arm goes red.
#
# WHAT THIS DOES NOT ASSERT, because it is not true: that a taskbar sees more
# than an ordinary application. It does not. See THE ENUMERATION POLICY in
# user/linux-wsys.c for why no fact in SO_PEERCRED separates them today.
#
# Offscreen, software, no ICD. /dev/dri is untouched.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass=0; fail=0
ok()   { printf 'enumpol: PASS %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'enumpol: FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'enumpol: .... %s\n' "$*"; }

# ======================================================================
# INNER HALF — runs inside the user namespace, as inner uid 0
# ======================================================================
if [ "${1:-}" = "--inner" ]; then
    W="$2"
    BIN="$W/bin"
    . "$W/reap.sh"
    reap_track "$W/reaped.inner"
    reap_on_exit

    # 0777 AND NOT STICKY, for the reason wsys_srv_identity.sh gives at
    # length: fs.protected_regular refuses a non-owner's O_RDWR open of a file
    # in a world-writable STICKY directory, so under 1777 the uid-1002 arms
    # would fail to open the segment at all and this gate would score the
    # sysctl as the policy.
    mkdir -p "$W/ws" "$W/noicd"; chmod 0777 "$W/ws"
    export HAMWSYS="$W/ws/seg" HAMWSYS_BB="$W/ws/seg.bb" HAMWSYS_IMG="$W/ws/img"
    export HAMFB_FILE="$W/ws/fb.raw" HAMFB_GEOM=1280x800
    export VK_ICD_FILENAMES="$W/noicd/none.json" HAMLINUX_VNC=none
    : >"$W/in"; chmod 666 "$W/in"; export HAMWSYSD_INPUT="$W/in"
    rm -f "$HAMWSYS" "$HAMWSYS.chrome" "$HAMWSYS_BB" "$HAMFB_FILE"

    as() { local u="$1"; shift
        if [ "$u" = 0 ]; then "$@"
        else setpriv --reuid="$u" --regid="$u" --clear-groups "$@"; fi; }
    # The pid comes back in a global, never on stdout, and the backgrounded
    # thing is exec'd so $! names the program and not a shell -- both traps
    # are documented in wsys_srv_identity.sh, both were paid for once already.
    BGPID=0
    as_bg() { local u="$1" out="$2" err="$3"; shift 3
        local pre=()
        [ "$u" = 0 ] || pre=(setpriv --reuid="$u" --regid="$u" --clear-groups)
        if [ "$err" = "-" ]; then ( exec "${pre[@]}" "$@" >"$out" 2>&1 ) &
        else                      ( exec "${pre[@]}" "$@" >"$out" 2>"$err" ) & fi
        BGPID=$!; reap_add "$BGPID"; }

    echo "== starting wsysd as uid 1001, HAMWSYS_SERVER=1, TRACE=1"
    as_bg 1001 "$W/wsysd.log" - \
          env HAMWSYS_SERVER=1 HAMWSYS_SRV_TRACE=1 "$BIN/wsysd"
    WP=$BGPID
    for _ in $(seq 1 150); do [ -s "$HAMFB_FILE" ] && break; sleep 0.1; done
    if ! [ -s "$HAMFB_FILE" ]; then
        echo "== FATAL wsysd produced no framebuffer"
        tail -20 "$W/wsysd.log" | sed 's/^/== wsysd: /'
        exit 3
    fi
    echo "== segowner $(stat -c %u "$HAMWSYS")"
    grep -m1 'read server pid' "$W/wsysd.log" \
        | sed 's/^/== readserver /' || echo "== readserver NONE"

    # ---- the victim: uid 1001, owns a window, STAYS ALIVE ---------------
    # wsys_hold and not a one-shot: win_reap_dead() destroys a window whose
    # owner has exited, so a creator that exits leaves nothing to enumerate
    # and every arm below would be comparing "" against "".
    : >"$W/vscript"; chmod 666 "$W/vscript"
    as_bg 1001 "$W/victim.out" "$W/victim.log" \
          env HAMWSYS_SERVER=1 "$BIN/wsys_hold" "$W/vscript"
    VP=$BGPID
    for _ in $(seq 1 100); do [ -s "$W/victim.out" ] && break; sleep 0.1; done
    VWID="$(head -1 "$W/victim.out" | tr -d '\n' 2>/dev/null || true)"
    echo "== victimwid ${VWID:-none}"
    if [ -z "${VWID:-}" ] || [ "${VWID:-0}" -lt 2 ]; then
        echo "== FATAL the victim never mapped a window"
        sed 's/^/== victim: /' "$W/victim.log"
        exit 3
    fi
    # `decorate 1` IS THE INSTRUMENT, NOT DECORATION. snap_windows() lists only
    # windows that are BOTH visible and decorate, and a fresh window is visible
    # and NOT decorated -- without this line /dev/wsys/windows is empty for
    # everyone and every arm below passes for the wrong reason.
    printf 'ctl decorate 1\nctl title VICTIM-ENUM-TITLE\n' >>"$W/vscript"
    sleep 1.2

    one() { tr '\n' ' ' | sed 's/  */ /g'; }

    # ---- the instrument, first --------------------------------------------
    echo "== baseline $(as 1001 "$BIN/cat" /dev/wsys/windows 2>&1 | one)"

    # ---- RED: unrouted, uid 1002, owns nothing ---------------------------
    echo "== red $(as 1002 "$BIN/cat" /dev/wsys/windows 2>/dev/null | one)"

    # ---- GREEN: routed, same uid, same file ------------------------------
    echo "== green $(as 1002 env HAMWSYS_SERVER=1 "$BIN/cat" \
                     /dev/wsys/windows 2>/dev/null | one)"

    # ---- the read server must be able to say something, or GREEN is a lie --
    echo "== hostrouted $(as 1001 env HAMWSYS_SERVER=1 "$BIN/cat" \
                          /dev/wsys/windows 2>/dev/null | one)"

    # ---- THE ARM THAT SEPARATES "OWNS A WINDOW" FROM "IS UID 1001" -------
    : >"$W/ascript"; chmod 666 "$W/ascript"
    as_bg 1002 "$W/attacker.out" "$W/attacker.log" \
          env HAMWSYS_SERVER=1 "$BIN/wsys_hold" "$W/ascript"
    AP=$BGPID
    for _ in $(seq 1 100); do [ -s "$W/attacker.out" ] && break; sleep 0.1; done
    AWID="$(head -1 "$W/attacker.out" | tr -d '\n' 2>/dev/null || true)"
    echo "== attackerwid ${AWID:-none}"
    printf 'ctl decorate 1\nctl title ATTACKER-OWN-WINDOW\n' >>"$W/ascript"
    sleep 1.0
    printf 'list\n' >>"$W/ascript"
    sleep 1.0
    echo "== owner1002 $(sed -n 's/^LIST<//p;/>LIST/q' "$W/attacker.out" \
                        | tr '\n' ' ' | sed 's/  */ /g')"
    echo "== owner1002raw $(tr '\n' '|' <"$W/attacker.out")"

    # ---- and a window-less 1002 STILL sees nothing, with 1002 owning one --
    echo "== green2 $(as 1002 env HAMWSYS_SERVER=1 "$BIN/cat" \
                      /dev/wsys/windows 2>/dev/null | one)"

    sleep 0.3
    echo "== traceempty $(grep -c 'wsrvtrace: enum .*tier=EMPTY' "$W/wsysd.log")"
    echo "== tracefull $(grep -c 'wsrvtrace: enum .*tier=FULL' "$W/wsysd.log")"
    grep 'wsrvtrace: enum' "$W/wsysd.log" | sed 's/^/== trace /'
    kill "$AP" "$VP" "$WP" 2>/dev/null
    exit 0
fi

# ======================================================================
# OUTER HALF
# ======================================================================
cd "$PROJ"
OUT="${SRV_WORK:-/home/david/.hamnix-build/wsrv-s4}"
BIN="$OUT/bin"; mkdir -p "$BIN"

for c in "${ADDER_HOST_AC:-}" "$PROJ/build/cutover/host_ac_llvm.elf" \
         "$PROJ/build/cutover/host_ac.elf" \
         "$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/../build/cutover/host_ac.elf"; do
    [ -n "$c" ] && [ -x "$c" ] && { ADDER_HOST_AC="$c"; break; }
done
[ -n "${ADDER_HOST_AC:-}" ] || { echo "enumpol: FAIL no host_ac.elf"; exit 2; }
export ADDER_HOST_AC HAMLINUX_DISTRO_RO=1
for t in wsysd:user/wsysd.ad cat:user/cat.ad \
         wsys_hold:tests/linux/wsys_hold.ad; do
    n="${t%%:*}"
    [ "${SRV_REBUILD:-1}" = 0 ] && [ -x "$BIN/$n" ] && continue
    scripts/hamlinux_build.sh "${t#*:}" "$BIN/$n" >"$OUT/build.$n.log" 2>&1 || {
        echo "enumpol: FAIL could not build ${t#*:}"; tail -8 "$OUT/build.$n.log"
        exit 2; }
done

command -v unshare >/dev/null || { echo "enumpol: SKIP no unshare(1)"; exit 0; }
command -v setpriv >/dev/null || { echo "enumpol: SKIP no setpriv(1)"; exit 0; }
grep -q "^$(id -un):" /etc/subuid 2>/dev/null || {
    echo "enumpol: SKIP no /etc/subuid range for $(id -un); run this in the VM"
    exit 0; }
SUB="$(awk -F: -v u="$(id -un)" '$1==u{print $2; exit}' /etc/subuid)"

W="$(mktemp -d "${TMPDIR:-/tmp}/enumpol.XXXXXX")"
trap 'rm -rf "$W"' EXIT
trap 'exit 130' INT TERM HUP
chmod 1777 "$W"
mkdir -p "$W/bin"; cp "$BIN"/wsysd "$BIN"/cat "$BIN"/wsys_hold "$W/bin/"
chmod 755 "$W/bin"/*
cp "$0" "$W/inner.sh"; chmod 755 "$W/inner.sh"
cp tests/linux/reap.sh "$W/reap.sh"

OUTF="$W/out.txt"
unshare -U \
    --map-users=0:"$(id -u)":1      --map-groups=0:"$(id -g)":1 \
    --map-users=1001:"$SUB":1       --map-groups=1001:"$SUB":1 \
    --map-users=1002:"$((SUB+1))":1 --map-groups=1002:"$((SUB+1))":1 \
    -- "$W/inner.sh" --inner "$W" >"$OUTF" 2>&1
rc=$?
sed 's/^/enumpol|  /' "$OUTF"
[ $rc -eq 0 ] || { echo "enumpol: FAIL namespace run rc=$rc"; exit 2; }

f() { grep -m1 "^== $1" "$OUTF" | sed "s/^== $1 *//"; }

SEGOWN="$(f segowner)"; VWID="$(f victimwid)"
note "segment owner uid $SEGOWN (this is the host owner the policy grants); victim window $VWID owned by uid 1001; the snooper is uid 1002 and owns nothing"
if [ "$SEGOWN" = 1001 ]; then
    ok "the host owner is uid 1001 and the snooper is a different uid -- the two identities every arm below turns on are genuinely different"
else
    bad "the segment is owned by uid '$SEGOWN', not 1001 -- the uid separation this gate rests on did not happen"
fi

if printf '%s' "$(f readserver)" | grep -q 'read server pid'; then
    ok "wsysd forked a read server OFF the frame loop: $(f readserver)"
else
    bad "no read server was started -- every routed arm below would be falling back to the unmediated in-process read, which is the state this gate exists to distinguish from a policy"
fi

# ---------- the instrument must be able to produce a non-empty answer -----
BASE="$(f baseline)"
if printf '%s' "$BASE" | grep -q 'VICTIM-ENUM-TITLE'; then
    ok "the enumeration instrument reads back a real window list (\"$BASE\") -- an 'empty' below is a comparison and not two blanks"
else
    bad "the window list never contained the victim's title (got \"$BASE\"). snap_windows() lists only windows that are BOTH visible and decorate, so this is most likely a missing \`decorate 1\`; every 'empty' below would be vacuous and none of them are scored."
    echo "enumpol: $pass passed, $fail failed"; exit 1
fi

# ---------- RED: it must still fail open ---------------------------------
note "RED ARM -- uid 1002, owns no window, HAMWSYS_SERVER unset, reading the same file:"
RED="$(f red)"
if printf '%s' "$RED" | grep -q 'VICTIM-ENUM-TITLE'; then
    ok "UNROUTED: a window-less uid-1002 process enumerated uid 1001's window -> \"$RED\". IT WORKS, AND IT IS SUPPOSED TO: the read was the snooper's own linked-in code answering from a MAP_SHARED segment, with a live mediator standing next to it and unable to see it. That is the hole WSYS_VERSION 8 -> 9 exists to close, and it is why the bump is the enforcement rather than a consequence of it."
else
    bad "the unrouted read did NOT see the window (\"$RED\"). The instrument is not looking, so an empty routed read below would be unattributable -- it could be the policy or it could be that nothing was ever readable."
fi

# ---------- GREEN: the same read, routed ---------------------------------
note "GREEN ARM -- the identical process, the identical uid, the identical file, routed:"
GREEN="$(f green)"
if [ -z "$GREEN" ]; then
    ok "ROUTED: the read server answered a window-less uid-1002 caller with an EMPTY list. In the server's own words: $(grep -m1 'wsrvtrace: enum caller uid=1002' "$OUTF" | sed 's/^== trace //')"
elif printf '%s' "$GREEN" | grep -q 'VICTIM-ENUM-TITLE'; then
    bad "ROUTED: a window-less uid-1002 process still enumerated uid 1001's window -> \"$GREEN\". Enumeration is not mediated."
else
    bad "ROUTED: the answer was neither empty nor the list -> \"$GREEN\""
fi

# ---------- the server is not simply answering everyone nothing ----------
note "the read server must not be a blanket empty -- two arms that must be ANSWERED:"
HOSTR="$(f hostrouted)"
if printf '%s' "$HOSTR" | grep -q 'VICTIM-ENUM-TITLE'; then
    ok "the host owner's routed read returned the full list (\"$HOSTR\") -- the empty answer above was a decision, not a broken read"
else
    bad "the HOST OWNER's routed read came back \"$HOSTR\" -- a server that answers nobody would have scored the arm above for the wrong reason, so that PASS is withdrawn"
fi

AWID="$(f attackerwid)"
OWN="$(f owner1002)"
note "and the arm that separates 'owns a window' from 'is the host owner's uid': uid 1002 now owns window ${AWID:-none} and reads the list from inside that process --"
if [ -z "${AWID:-}" ] || [ "${AWID:-0}" -lt 2 ]; then
    bad "the uid-1002 client never got a window of its own ($(f owner1002raw)) -- the arm that would catch a uid-only policy could not run"
elif printf '%s' "$OWN" | grep -q 'VICTIM-ENUM-TITLE'; then
    ok "a uid-1002 process THAT OWNS A WINDOW got the full list through the same server -> \"$OWN\". The rule is ownership, not uid: a policy that answered on uid alone would be red here and would have broken the taskbar on a real desktop, where the panel is not the host owner."
else
    bad "a uid-1002 window OWNER was denied the list (\"$OWN\"). The policy has collapsed to a uid check, which denies the panel its taskbar."
fi

GREEN2="$(f green2)"
if [ -z "$GREEN2" ]; then
    ok "and the window-LESS uid-1002 process still sees nothing while a uid-1002 window exists -- the grant is per-caller, not per-uid"
else
    bad "a window-less uid-1002 process saw \"$GREEN2\" once ANY uid-1002 window existed -- the check is answering about the uid, not about the caller"
fi

TE="$(f traceempty)"; TF="$(f tracefull)"
if [ "${TE:-0}" -ge 1 ] && [ "${TF:-0}" -ge 1 ]; then
    ok "the read server decided both ways in this run ($TE EMPTY, $TF FULL) -- a policy that only ever reaches one branch is indistinguishable from a constant"
else
    bad "the read server reached only one branch (EMPTY $TE, FULL $TF); a constant answer would score the same as a policy"
fi

echo "enumpol: $pass passed, $fail failed"
[ "$fail" = 0 ]
