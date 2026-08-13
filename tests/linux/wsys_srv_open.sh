#!/usr/bin/env bash
# wsys_srv_open.sh — STAGE 10: EXISTENCE IS A SERVER ANSWER, OR IT IS NOT.
#
# WHAT THIS GATE IS FOR
# =====================
# docs/wsys_server_design.md §7.1(2): "Routing `open` is the precondition for
# [removing the client's mapping], and no stage has touched it. Almost every arm
# of hamwsys_open() starts with win_find(f->wid), which is a walk of the mapped
# table. ... This is the largest single piece of unbuilt work in stage 7."
#
# Stage 9 routed the three leaves that REPORT attributes -- <wid>/ctl,
# <wid>/wctl and the directory -- and a caller that owns nothing now gets ENOENT
# from all three. THE LEAVES THAT REPORT NO ATTRIBUTES STILL ANSWERED, and they
# answered the same question: a refusal that distinguishes itself from an
# absence IS an enumeration channel. Measured, uid 1002 owning nothing:
#
#     cat /dev/wsys/<live>/draw/images   -> rc 0    (no output, but it OPENED)
#     cat /dev/wsys/<dead>/draw/images   -> ENOENT
#     cat /dev/wsys/<live>/scene         -> EPERM, and the message NAMES the window
#     cat /dev/wsys/<dead>/scene         -> ENOENT
#     cat /dev/wsys/<live>/pointer       -> EPERM   (the ring owner check, 0f80d3e5)
#     cat /dev/wsys/<dead>/pointer       -> ENOENT
#     cat /dev/wsys/<live>/keys          -> EPERM   (the one refusal by name)
#     cat /dev/wsys/<dead>/keys          -> ENOENT
#
# So the shape of every arm below is A PAIR, not a value: the SAME leaf on a
# window that exists and on one that does not, from the same process, and the
# claim is about whether the two can be told apart.
#
#   RED    (HAMWSYS_SERVER unset) live and dead DIFFER on every leaf. The
#          window table is enumerable from a process that owns nothing, without
#          reading one byte of it. MUST BE TRUE -- it is the tree until the
#          version bump, and a red arm that has quietly gone green makes the
#          green arm unattributable.
#   GREEN  (HAMWSYS_SERVER=1) the identical process, identical uid, identical
#          leaves: live and dead are BYTE-IDENTICAL. Existence is withheld.
#
# WHY A PAIR AND NOT A SINGLE REFUSAL. A gate that only checked "the snooper is
# refused" would have passed on the code this stage replaces: every one of these
# leaves already refused to hand over data. What leaked was WHICH refusal, and
# only a comparison can see that.
#
# THE RULE IS STAGE 9'S PER-WINDOW RULE, unchanged and reused rather than
# reinvented: `hostowner() || owns_wid_ancestry(wid)`, the one <wid>/ctl and
# <wid>/wctl answer to and the one the four rings took in 0f80d3e5. A leaf whose
# existence answers to a looser rule than its contents is a gate on one of two
# spellings.
#
# WHAT THIS GATE DOES NOT CLAIM, and the report says it too: THE MAPPING IS
# STILL THERE. Every attack in tests/linux/wsys_bypass.sh is an mmap and none of
# them calls this code. What is proved here is the PRECONDITION -- a client that
# asks honestly now learns existence from the server, which is what a client
# with no mapping will have to do. Removing the mapping costs the WSYS_VERSION
# bump, which this stage does not make.
#
# THE TRAP THIS FILE WAS WRITTEN AGAINST, inherited from wsys_srv_attrread.sh:
# every arm runs the client's ORDINARY open path, so A BUILD THAT ROUTED NOTHING
# WOULD PASS THE LOT -- both arms take the in-process path and agree. So the
# server's own trace NAMES THE LEAF (`leaf=exists`) and the crossings are
# COUNTED SCOPED TO EACH CLIENT'S OWN PID, which the client reports itself
# before exec'ing. Routed must be non-zero; unrouted must be exactly zero.
#
# WHY TWO UIDS: identical to wsys_enum_policy.sh and wsys_srv_attrread.sh. The
# policy grants the host owner everything, so a single-uid gate's "stranger" IS
# the host owner. `unshare -U --map-users` with three ids; wsysd as 1001,
# victim 1001, snooper 1002.
#
# Offscreen, software, no ICD. /dev/dri is untouched.
set -uo pipefail
PROJ="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

pass=0; fail=0
ok()   { printf 'wsopen: PASS %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf 'wsopen: FAIL %s\n' "$*"; fail=$((fail+1)); }
note() { printf 'wsopen: .... %s\n' "$*"; }

# The leaves this stage routes. wid/ctl, wid/wctl and the directory are NOT
# here: stage 9 routed those and wsys_srv_attrread.sh is their gate.
LEAVES="scene pointer event text cmd keys draw/images backbuffer"

# ======================================================================
# INNER HALF — runs inside the user namespace, as inner uid 0
# ======================================================================
if [ "${1:-}" = "--inner" ]; then
    W="$2"
    BIN="$W/bin"
    . "$W/reap.sh"
    reap_track "$W/reaped.inner"
    reap_on_exit

    # 0777 AND NOT STICKY: fs.protected_regular refuses a non-owner's O_RDWR
    # open of a file in a world-writable STICKY directory (wsys_srv_identity.sh
    # at length), so under 1777 every uid-1002 arm would fail to open the
    # segment and this gate would score the sysctl as the policy.
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
    # thing is exec'd so $! names the program and not a shell -- both traps are
    # documented in wsys_srv_identity.sh and both were paid for once already.
    BGPID=0
    as_bg() { local u="$1" out="$2" err="$3"; shift 3
        local pre=()
        [ "$u" = 0 ] || pre=(setpriv --reuid="$u" --regid="$u" --clear-groups)
        if [ "$err" = "-" ]; then ( exec "${pre[@]}" "$@" >"$out" 2>&1 ) &
        else                      ( exec "${pre[@]}" "$@" >"$out" 2>"$err" ) & fi
        BGPID=$!; reap_add "$BGPID"; }

    # ONE PROBE = ONE `cat` OF ONE LEAF, and what is recorded is the whole
    # observable: the exit code, the stdout, AND THE ERROR STRING. The error
    # string is the channel -- "No such file or directory" against "Operation
    # not permitted" is the bit that says a window is there.
    #
    # The pid is written before exec so the number is the one the kernel hands
    # the read server in SO_PEERCRED (see the crossing arms).
    #   probe <uid> <routed:0|1> <pidfile> <tag> <path>
    probe() { local u="$1" r="$2" pf="$3" tag="$4" p="$5"
        local env=()
        [ "$r" = 1 ] && env=(env HAMWSYS_SERVER=1) || env=(env -u HAMWSYS_SERVER)
        as "$u" bash -c 'echo $$ >"$1"; shift; exec "$@"' _ "$pf" \
           "${env[@]}" "$BIN/cat" "$p" >"$W/o.$tag" 2>"$W/e.$tag"
        local rc=$?
        # The error string only: cat prints "cat: cannot open <path>: <errstr>",
        # and the PATH contains the wid, which differs between the live and dead
        # arms by construction. Comparing the raw line would therefore ALWAYS
        # differ and every green arm would fail for the wrong reason.
        local es
        es="$(sed -n '1s/.*: //p' "$W/e.$tag" | tr -d '\n')"
        printf '== probe.%s rc=%s out=<%s> err=<%s>\n' "$tag" "$rc" \
               "$(tr '\n' ' ' <"$W/o.$tag" | sed 's/  */ /g')" "$es"
    }

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
    # owner has exited, so a creator that exits leaves nothing to probe and
    # every "live" arm would be a second "dead" arm.
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
    printf 'ctl decorate 1\nctl title VICTIM-OPEN-TITLE\nctl geometry 137 241 353 179\n' \
        >>"$W/vscript"
    # A COMMITTED SCENE, so the victim's `scene` leaf is a live one and its
    # refusal is the EPERM path rather than the "never committed, read empty"
    # path. Without this the scene arm would compare two empty successes.
    printf 'scene rect 10 10 40 40 255 0 0\n' >>"$W/vscript"
    sleep 1.2

    # A wid THAT DOES NOT EXIST, and it must be one that never will during this
    # run: wids are allocated upward from 1, so +1000 is not a race.
    DWID=$((VWID + 1000))
    echo "== deadwid $DWID"

    # ---- the instrument first: the OWNER must be able to open its own -----
    # A gate whose refusals are all it measures cannot tell a policy from a
    # server that answers nobody.
    #
    # FROM INSIDE THE OWNING PROCESS, and that is not a convenience. A window's
    # display list lives in a PER-WINDOW MEMFD since v8, and pix_get hands it
    # only to owns_wid() or to a process the descriptor was handed to -- so even
    # the HOST OWNER, cat'ing the file from a separate process, gets EPERM and
    # would score this instrument as broken. Measured that way first, which is
    # why this note exists.
    printf 'slurp /dev/wsys/%s/scene\n' "$VWID" >>"$W/vscript"; sleep 0.8
    echo "== ownscene $(tr '\n' ' ' <"$W/victim.out" \
                        | grep -o 'SLURP<[^>]*>SLURP' | sed -n '1p' \
                        | sed 's/^SLURP<//; s/>SLURP$//' | sed 's/  */ /g')"

    # ---- the pairs, one leaf at a time ----------------------------------
    n=0
    for L in scene pointer event text cmd keys draw/images backbuffer; do
        n=$((n+1))
        probe 1002 0 "$W/p.rl$n" "rl$n" "/dev/wsys/$VWID/$L"
        probe 1002 0 "$W/p.rd$n" "rd$n" "/dev/wsys/$DWID/$L"
        probe 1002 1 "$W/p.gl$n" "gl$n" "/dev/wsys/$VWID/$L"
        probe 1002 1 "$W/p.gd$n" "gd$n" "/dev/wsys/$DWID/$L"
        echo "== leaf$n $L"
    done

    # ---- THE OWNER'S OWN LEAVES, ROUTED: nothing may be taken away -------
    # uid 1002 with a window of its own opens ITS OWN scene and rings. If the
    # served predicate refused this, the desktop would not come up at all and
    # every refusal above would be that rather than a policy.
    : >"$W/ascript"; chmod 666 "$W/ascript"
    as_bg 1002 "$W/owner.out" "$W/owner.log" \
          env HAMWSYS_SERVER=1 "$BIN/wsys_hold" "$W/ascript"
    AP=$BGPID
    for _ in $(seq 1 100); do [ -s "$W/owner.out" ] && break; sleep 0.1; done
    AWID="$(head -1 "$W/owner.out" | tr -d '\n' 2>/dev/null || true)"
    echo "== ownerwid ${AWID:-none}"
    printf 'ctl decorate 1\nctl title OWNER-1002-OPEN\nctl geometry 611 97 222 144\n' \
        >>"$W/ascript"
    printf 'scene rect 5 5 20 20 0 255 0\n' >>"$W/ascript"
    sleep 1.0
    # Its OWN scene, then the VICTIM's scene, then a dead wid -- in order, cut
    # by ordinal. The middle two are the per-window rule separating a window
    # owner from THIS window's owner; the last is what the middle one must be
    # indistinguishable from.
    printf 'slurp /dev/wsys/%s/scene\n' "$AWID"  >>"$W/ascript"; sleep 0.8
    printf 'slurp /dev/wsys/%s/scene\n' "$VWID"  >>"$W/ascript"; sleep 0.8
    printf 'slurp /dev/wsys/%s/scene\n' "$DWID"  >>"$W/ascript"; sleep 0.8
    tr '\n' ' ' <"$W/owner.out" >"$W/owner.flat"
    for k in 1 2 3; do
        echo "== owner$k $(grep -o 'SLURP<[^>]*>SLURP' "$W/owner.flat" \
                           | sed -n "${k}p" | sed 's/^SLURP<//; s/>SLURP$//' \
                           | sed 's/  */ /g')"
    done

    sleep 0.4
    # ---- THE CROSSINGS, SCOPED TO EACH CLIENT'S OWN PID ------------------
    for n in 1 2 3 4 5 6 7 8; do
        for tag in gl$n gd$n rl$n rd$n; do
            p="$(cat "$W/p.$tag" 2>/dev/null || echo 0)"
            c=$(grep -c "wsrvtrace: read caller uid=1002 pid=$p .*leaf=exists" \
                "$W/wsysd.log" 2>/dev/null || true)
            echo "== cross.$tag pid=$p n=${c:-0}"
        done
    done
    echo "== traceexists $(grep -c 'wsrvtrace: read .*leaf=exists' "$W/wsysd.log")"
    echo "== existfull $(grep -c 'wsrvtrace: read .*leaf=exists.* -> FULL' "$W/wsysd.log")"
    echo "== existempty $(grep -c 'wsrvtrace: read .*leaf=exists.* -> EMPTY' "$W/wsysd.log")"
    grep 'wsrvtrace: read .*leaf=exists' "$W/wsysd.log" | tail -20 \
        | sed 's/^/== trace /'
    kill "$AP" "$VP" "$WP" 2>/dev/null
    exit 0
fi

# ======================================================================
# OUTER HALF
# ======================================================================
cd "$PROJ"
# PRIVATE NAMESPACE FIRST. wsysd's names are compiled into it -- /srv/wsys,
# /dev/shm/hamnix-wsys, /tmp/hamnix-wsys -- so a run of this gate beside a live
# desktop is a collision, not an untidiness (tests/linux/private_ns.sh).
. tests/linux/private_ns.sh
priv_ns_reexec "$@"

SCRATCH_BASE="${SRV_SCRATCH_BASE:-/home/david/.hamnix-build}"
if [ -n "${SRV_WORK:-}" ]; then
    OUT="$SRV_WORK"; OUT_EPHEMERAL=0
    mkdir -p "$OUT" || { echo "wsopen: FAIL cannot make $OUT"; exit 2; }
else
    mkdir -p "$SCRATCH_BASE" || { echo "wsopen: FAIL cannot make $SCRATCH_BASE"; exit 2; }
    OUT="$(mktemp -d "$SCRATCH_BASE/wsrv-open.XXXXXX")" || {
        echo "wsopen: FAIL cannot make a scratch dir under $SCRATCH_BASE"; exit 2; }
    OUT_EPHEMERAL=1
fi
BIN="$OUT/bin"; mkdir -p "$BIN"

for c in "${ADDER_HOST_AC:-}" "$PROJ/build/cutover/host_ac_llvm.elf" \
         "$PROJ/build/cutover/host_ac.elf" \
         "$(git -C "$PROJ" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/../build/cutover/host_ac.elf"; do
    [ -n "$c" ] && [ -x "$c" ] && { ADDER_HOST_AC="$c"; break; }
done
[ -n "${ADDER_HOST_AC:-}" ] || { echo "wsopen: FAIL no host_ac.elf"; exit 2; }
export ADDER_HOST_AC HAMLINUX_DISTRO_RO=1
for t in wsysd:user/wsysd.ad cat:user/cat.ad \
         wsys_hold:tests/linux/wsys_hold.ad; do
    n="${t%%:*}"
    [ "${SRV_REBUILD:-1}" = 0 ] && [ -x "$BIN/$n" ] && continue
    scripts/hamlinux_build.sh "${t#*:}" "$BIN/$n" >"$OUT/build.$n.log" 2>&1 || {
        echo "wsopen: FAIL could not build ${t#*:}"; tail -8 "$OUT/build.$n.log"
        exit 2; }
done

command -v unshare >/dev/null || { echo "wsopen: SKIP no unshare(1)"; exit 0; }
command -v setpriv >/dev/null || { echo "wsopen: SKIP no setpriv(1)"; exit 0; }

# WHERE THE SECOND AND THIRD UID COME FROM -- verbatim from
# wsys_enum_policy.sh, whose comment explains why the test is the MAPPING
# ATTEMPT and not a read of /proc/self/uid_map.
SUB=""
if grep -q "^$(id -un):" /etc/subuid 2>/dev/null \
   && grep -q "^$(id -un):" /etc/subgid 2>/dev/null; then
    SUB="$(awk -F: -v u="$(id -un)" '$1==u{print $2; exit}' /etc/subuid)"
    IDSRC="/etc/subuid range $SUB for $(id -un)"
elif unshare -U \
        --map-users=0:"$(id -u)":1      --map-groups=0:"$(id -g)":1 \
        --map-users=1001:1001:1         --map-groups=1001:1001:1 \
        --map-users=1002:1002:1         --map-groups=1002:1002:1 \
        true 2>/dev/null; then
    SUB=1001
    IDSRC="ids 1001/1002 are already this namespace's own (mapped to themselves)"
else
    echo "wsopen: SKIP no /etc/subuid range for $(id -un), and this namespace"
    echo "wsopen: SKIP does not already own uids 1001 and 1002; run this in the VM"
    exit 0
fi

note "$(priv_ns_describe)"
note "the two extra uids: $IDSRC"

W="$(mktemp -d "${TMPDIR:-/tmp}/wsopen.XXXXXX")"
trap 'rm -rf "$W"; [ "${OUT_EPHEMERAL:-0}" = 1 ] && rm -rf "$OUT"' EXIT
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
sed 's/^/wsopen|  /' "$OUTF"
[ $rc -eq 0 ] || { echo "wsopen: FAIL namespace run rc=$rc"; exit 2; }

f() { grep -m1 "^== $1 " "$OUTF" | sed "s/^== $1 *//"; }
pr() { grep -m1 "^== probe.$1 " "$OUTF" | sed "s/^== probe.$1 *//"; }

SEGOWN="$(f segowner)"; VWID="$(f victimwid)"; DWID="$(f deadwid)"
note "segment owner uid $SEGOWN; victim window $VWID owned by uid 1001; window $DWID does not exist; the snooper is uid 1002 and owns nothing"
if [ "$SEGOWN" = 1001 ]; then
    ok "the host owner is uid 1001 and the snooper is a different uid -- the two identities every arm below turns on are genuinely different"
else
    bad "the segment is owned by uid '$SEGOWN', not 1001 -- the uid separation this gate rests on did not happen"
fi

if printf '%s' "$(f readserver)" | grep -q 'read server pid'; then
    ok "wsysd forked a read server OFF the frame loop: $(f readserver)"
else
    bad "no read server was started -- every routed arm below would be falling back to the unmediated in-process lookup, which is the state this gate exists to distinguish from a policy"
fi

# ---------- the instrument must be able to produce a real answer ----------
OS="$(f ownscene)"
if printf '%s' "$OS" | grep -q 'rect'; then
    ok "the instrument reads: the OWNER's own routed scene open returns its committed display list (\"$OS\"). Every refusal below is a comparison and not a broken read."
else
    bad "the owner's own routed scene read came back \"$OS\" -- no display list, so the refusals below are unattributable"
    echo "wsopen: $pass passed, $fail failed"; exit 1
fi

# ---------- THE PAIRS ----------------------------------------------------
i=0
for L in scene pointer event text cmd keys draw/images backbuffer; do
    i=$((i+1))
    RL="$(pr "rl$i")"; RD="$(pr "rd$i")"
    GL="$(pr "gl$i")"; GD="$(pr "gd$i")"
    note "---- $L ----"
    note "  RED   live: $RL"
    note "  RED   dead: $RD"
    note "  GREEN live: $GL"
    note "  GREEN dead: $GD"
    # RED: the two must differ, or this leaf never leaked and the green arm
    # below proves nothing about it.
    if [ "$RL" = "$RD" ]; then
        if [ "$L" = backbuffer ]; then
            ok "UNROUTED $L: live and dead are already indistinguishable (\"$RL\"). This leaf answers ENOENT for a v0 window whose memfd was never handed up, so it never was an existence channel -- recorded rather than scored, and the routed arm below must not make it one."
        else
            bad "UNROUTED $L: live and dead are identical (\"$RL\"), so this leaf leaks nothing to begin with and the routed arm proves nothing about it. The red arm has gone green on its own."
        fi
    else
        ok "UNROUTED $L: a window-less uid-1002 process TELLS A LIVE WINDOW FROM A DEAD ONE -- live \"$RL\" against dead \"$RD\". Neither read a byte of the window; the difference IS the enumeration. It works and it is supposed to: that is the snooper's own linked-in code, answering out of a MAP_SHARED segment with a live mediator standing next to it."
    fi
    # GREEN: the two must be identical.
    if [ "$GL" = "$GD" ]; then
        ok "ROUTED $L: live and dead are BYTE-IDENTICAL (\"$GL\"). Existence is a server answer and the snooper cannot ask this leaf which windows are there."
    else
        bad "ROUTED $L: live \"$GL\" still differs from dead \"$GD\" -- the open is not mediated for this leaf."
    fi
done

# ---------- THE OWNER MUST NOT LOSE ANYTHING -----------------------------
AWID="$(f ownerwid)"
O1="$(f owner1)"; O2="$(f owner2)"; O3="$(f owner3)"
note "uid 1002 now owns window ${AWID:-none}, and from inside that process opens its OWN scene, the VICTIM's scene, and a dead wid:"
if [ -z "${AWID:-}" ] || [ "${AWID:-0}" -lt 2 ]; then
    bad "the uid-1002 client never got a window of its own -- the arms that keep the refusals honest could not run"
else
    if printf '%s' "$O1" | grep -q 'rect'; then
        ok "THE GRANT: the same uid-1002 process reads its OWN window's scene in full (\"$O1\"). The refusals above are a decision about the window, not a server that answers nobody."
    else
        bad "a uid-1002 process could not open its OWN window's scene (\"$O1\") -- the served existence predicate refuses the owner, which is a broken desktop and not a policy"
    fi
    # RECORDED AND NOT SCORED, AND THE REASON IS THE INSTRUMENT.  wsys_hold's
    # `slurp` prints OPENFAIL for any failed open and does not report the
    # errno, so EPERM and ENOENT are the SAME STRING to it -- this pair reads
    # identical on the unfixed tree too, which is precisely the trap this file's
    # header warns about.  Scoring it would be a green arm that was already
    # green.  The claim it is meant to make is made instead by the `keys` and
    # `scene` pairs above, whose probe records the error string, and by the
    # crossing counts.
    if [ "$O2" = "$O3" ]; then
        note "PER-WINDOW (recorded, not scored): from that same process the VICTIM's scene (\"$O2\") and a dead wid (\"$O3\") both read \"$O2\" -- slurp cannot report an errno, so this pair cannot separate EPERM from ENOENT either way"
    else
        bad "a uid-1002 process that owns window $AWID told the victim's window (\"$O2\") from a dead wid (\"$O3\") -- and slurp cannot even report an errno, so whatever separated them is worse than an errno"
    fi
fi

# ---------- THE ARMS THAT MAKE "IT WAS ROUTED" VISIBLE FROM OUTSIDE ------
note "THE CROSSINGS. Every arm above runs through the client's ORDINARY open path, so a build that routed NOTHING would pass all of them -- both arms would take the in-process path and agree perfectly. These count the read server's own trace, scoped to each client's own pid:"
i=0
for L in scene pointer event text cmd keys draw/images backbuffer; do
    i=$((i+1))
    for tag in gl$i gd$i; do
        line="$(grep -m1 "^== cross.$tag " "$OUTF")"
        n="$(printf '%s' "$line" | sed -n 's/.* n=\([0-9]*\).*/\1/p')"
        p="$(printf '%s' "$line" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')"
        if [ "${n:-0}" -ge 1 ]; then
            ok "ROUTED $L ($tag): the read server logged $n existence question(s) for pid $p -- the crossing is visible from outside the process"
        else
            bad "ROUTED $L ($tag): the read server logged NO existence question for pid $p. The arm above passed on the in-process path, so it proves nothing about routing."
        fi
    done
    for tag in rl$i rd$i; do
        line="$(grep -m1 "^== cross.$tag " "$OUTF")"
        n="$(printf '%s' "$line" | sed -n 's/.* n=\([0-9]*\).*/\1/p')"
        p="$(printf '%s' "$line" | sed -n 's/.*pid=\([0-9]*\).*/\1/p')"
        if [ "${n:-0}" = 0 ]; then
            ok "UNROUTED $L ($tag): zero crossings for pid $p, as there must be -- the red arm really did read shared memory"
        else
            bad "UNROUTED $L ($tag): the read server logged $n question(s) for pid $p, so the 'unrouted' arm was routed and the red/green pair is not a pair"
        fi
    done
done

EF="$(f existfull)"; EE="$(f existempty)"
if [ "${EF:-0}" -ge 1 ] && [ "${EE:-0}" -ge 1 ]; then
    ok "the read server decided existence BOTH WAYS in this run ($EE refused, $EF granted) -- a policy that only ever reaches one branch is indistinguishable from a constant"
else
    bad "the read server reached only one branch on the existence question (refused $EE, granted $EF); a constant answer would score the same as a policy"
fi

echo "wsopen: $pass passed, $fail failed"
[ "$fail" = 0 ]
