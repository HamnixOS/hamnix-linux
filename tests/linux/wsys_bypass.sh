#!/usr/bin/env bash
# tests/linux/wsys_bypass.sh — the gate the KERNEL enforces, measured.
#
# WHAT IS UNDER TEST, and how it differs from wsys_uidgate.sh.  That test
# drives /dev/wsys through the file protocol and proves the ported devwsys uid
# gate refuses a non-owner.  Its own stated limit was that the gate is a check
# inside a LIBRARY: it binds every caller of the protocol -- which is every
# program in this tree -- and nothing else.  /dev/wsys is the file /srv/wsys,
# mode 0666, MAP_SHARED into every client, so a program that skips the protocol
# and mmaps the file itself was bound by nothing at all.
#
# This test drives that program.  tests/linux/wsys_bypass.c does not open
# /dev/wsys, does not link the syscall runtime and does not know the protocol
# exists; it opens the backing file, mmaps it MAP_SHARED, finds a byte string
# and overwrites it.  It is run against BOTH segments, and the only difference
# between the two runs is the file mode:
#
#   /srv/wsys         0666, the window table.  The bypass SUCCEEDS.  That is
#                     the residual hole, and it is asserted rather than
#                     apologised for -- it is also the positive control that
#                     proves the technique is real and the program works.
#   /srv/wsys.chrome  0644 owned by the host owner, the system chrome.  The
#                     kernel refuses O_RDWR, refuses PROT_WRITE|MAP_SHARED on
#                     the read-only fd, and refuses mprotect afterwards.
#
# And the half that must NOT regress, because the failure it guards against is
# worse than the hole: a non-owner can still READ the chrome (it maps PROT_READ
# and sees what the owner published), still reads /dev/wsys/screen through the
# protocol, and still maps and draws its own window.  A session that is
# unprivileged and BLIND is what the 0666 mode on the window table exists to
# prevent, and the split must not have reintroduced it by the back door.
#
# HOW THE UIDS ARE GOT WITHOUT ROOT.  The same user namespace shape as
# wsys_uidgate.sh: inner 0 (the compositor's identity on a real boot) and inner
# 1001 (`live`), mapped out of /etc/subuid.  Every process is really the same
# host user, so nothing here can reach the host's /srv, display or /dev/dri --
# the segments are files in a temp directory named by $HAMWSYS.
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

fail=0
note() { printf '%s\n' "$*"; }
ok()   { printf '  ok   %s\n' "$*"; }
bad()  { printf '  FAIL %s\n' "$*"; fail=1; }

# ---- inner half: runs inside the namespace -------------------------------
if [ "${1:-}" = "--inner" ]; then
    W="$2"
    PROBE="$W/wsys_uidgate"        # the /dev/wsys PROTOCOL probe
    BYP="$W/wsys_bypass"           # the program that skips the protocol
    export HAMWSYS="$W/seg"
    rm -f "$HAMWSYS" "$HAMWSYS".bb "$HAMWSYS".chrome

    as() { local u="$1"; shift
        if [ "$u" = 0 ]; then "$@" 2>&1
        else setpriv --reuid="$u" --regid="$u" --clear-groups "$@" 2>&1; fi; }

    # 1. The host owner brings the window system up through the protocol,
    #    exactly as rc.5 does: root, before anything drops.  One window (whose
    #    title lands in the 0666 table) and two pieces of chrome (which land in
    #    the 0644 one).
    echo "-- setup, as the host owner (inner uid 0)"
    # IN THE BACKGROUND, AND HELD.  A window whose owner has exited is not a
    # window: user/linux-wsys.c reaps one whose pid is gone, which is what
    # devwsys gets for free when the dying process's fid closes.  Every step
    # below is a SEPARATE process from the one that made this window, so
    # something has to still be holding it -- otherwise the bypass has nothing
    # to overwrite and the read-back has nothing to read, and this gate would
    # be measuring a window that no longer exists.
    as 0 "$PROBE" client hold >"$W/root.client.out" 2>&1 &
    HOLDER=$!
    for _ in $(seq 1 50); do
        grep -q 'commit=' "$W/root.client.out" 2>/dev/null && break
        sleep 0.1
    done
    sed 's/^/== root./' "$W/root.client.out"
    # Decorated, so the window appears in /dev/wsys/windows -- that listing is
    # what makes step 3 able to read the bypass's overwrite back through the
    # protocol, and it is the same file the panel's taskbar parses.
    as 0 "$PROBE" chrome /dev/wsys/2/ctl 'decorate 1'    | sed 's/^/== root./'
    as 0 "$PROBE" chrome /dev/wsys/ctl 'screen 1280 800' | sed 's/^/== root./'
    as 0 "$PROBE" chrome /dev/wsys/lock 'CHROMEMARK'     | sed 's/^/== root./'

    ls -l "$HAMWSYS" "$HAMWSYS".chrome 2>&1 | sed 's/^/== ls /'

    # 2. THE BYPASS, from the unprivileged uid.  ALL THREE attacks THE SPLIT
    #    names as still open on the window table are driven here, against root's
    #    window (wid 2), so each one is a uid-1001 program reaching into a
    #    uid-0-owned window it has no protocol right to touch:
    #
    #      RETITLE   overwrite the title byte run.  Needle and replacement are
    #                the same length so it is in place: "uidgate probe" is the
    #                title root's window carries; CHROMEMARK is what root
    #                published into the `lock` CHROME sink, and is the refusal
    #                control on the 0644 segment.
    #      SCRIBBLE  overwrite the committed SCENE.  root's window committed
    #                "rect 0 0 40 20 0x334455"; the bypass rewrites the colour
    #                in the published display list, and step 3 reads it back
    #                through /dev/wsys/2/scene.
    #      INJECT    poke a key line into another window's `keys` RING -- which
    #                a plain overwrite cannot do, because a reader only sees
    #                bytes between r and w, so the injkey mode advances w too.
    #                step 3 drains /dev/wsys/2/keys and the injected key is
    #                there, as if root's own window had been typed into.
    echo "-- the bypass, as live (inner uid 1001)"
    as 1001 "$BYP" bypass.table  "$HAMWSYS" 'uidgate probe' 'PWNEDBYPASSER'
    as 1001 "$BYP" bypass.chrome "$HAMWSYS".chrome  'CHROMEMARK' 'BYPASSEDXX'
    as 1001 "$BYP" bypass.scene  "$HAMWSYS" '0x334455' '0xDEAD99'
    as 1001 "$BYP" injkey "$HAMWSYS" 'PWNEDBYPASSER' '7 111'

    # 3. What the PROTOCOL sees afterwards.  This is what makes step 2 mean
    #    something: a write into a mapping that nothing reads back is not a
    #    compromise, and a refusal on a segment nobody can read is not a
    #    working desktop.
    echo "-- the protocol's view afterwards"
    as 0    "$PROBE" read /dev/wsys/windows  | sed 's/^/== after.table./'
    as 0    "$PROBE" read /dev/wsys/lock     | sed 's/^/== after.chrome./'
    as 0    "$PROBE" read /dev/wsys/2/scene  | sed 's/^/== after.scene./'
    as 0    "$PROBE" read /dev/wsys/2/keys   | sed 's/^/== after.keys./'
    as 1001 "$PROBE" read /dev/wsys/screen   | sed 's/^/== live.screen./'
    as 1001 "$PROBE" read /dev/wsys/lock     | sed 's/^/== live.chromeread./'
    as 1001 "$PROBE" client                  | sed 's/^/== live./'

    # 3a. THE MEASUREMENT THAT DECIDES THE FIX.  Everything above pits uid 1001
    #     against uid 0, so a reader might hope a mapping-per-owner-uid closes
    #     it -- give root's windows a root-owned segment a uid-1001 client
    #     cannot map, and the bypass is refused the way the 0644 chrome already
    #     refuses it.  But /etc/rc.de-user drops the WHOLE session to uid 1001:
    #     the terminal, the browser and a malicious download are ALL uid 1001,
    #     so the attack that matters on a real desktop is one uid-1001 program
    #     against ANOTHER.  Unix file permissions are uid-granular and cannot
    #     tell two processes of one uid apart, so no file mode and no per-uid
    #     mapping can gate this.  Here it is, measured: a uid-1001 holder's
    #     window, and a SEPARATE uid-1001 process injecting a key into it.
    echo "-- same-uid: a uid-1001 attacker against a uid-1001 victim"
    as 1001 "$PROBE" client hold >"$W/live.client.out" 2>&1 &
    LHOLDER=$!
    for _ in $(seq 1 50); do
        grep -q 'commit=' "$W/live.client.out" 2>/dev/null && break
        sleep 0.1
    done
    sed 's/^/== live.hold./' "$W/live.client.out"
    LWID="$(sed -n 's/.*wid=\([0-9][0-9]*\).*/\1/p' "$W/live.client.out" | head -1)"
    # The attacker is a SEPARATE process at the SAME uid 1001 -- no file-mode
    # boundary exists between it and the victim, and none could.  It targets the
    # victim by WID rather than by title, because "uidgate probe" is the title
    # every probe window carries (including the reaped not-blind one above) and
    # a title needle would alias to a stale row; a hostile program that has read
    # struct wshm walks win[] for the wid just as readily.
    as 1001 "$BYP" injkey "$HAMWSYS" "wid=${LWID:-0}" '9 222' sameuid.inj
    as 1001 "$PROBE" read "/dev/wsys/${LWID:-0}/keys" | sed 's/^/== sameuid.keys./'
    kill "$LHOLDER" 2>/dev/null

    # 4. THE ONE DELIBERATE BEHAVIOUR CHANGE the split carries, measured.
    #    devwsys parses `wallpaper` BEFORE its hostowner gate -- "choosing your
    #    own desktop picture is not a host-owner privilege" -- so the sink
    #    behind it is public and lives in the 0666 segment.  Before the split
    #    the ctl spelling was allowed to a non-owner and the FILE spelling was
    #    refused, which is a gate on one of two spellings of the same act.
    #    Both are now allowed, and both must reach the same sink.
    echo "-- wallpaper, ungated in BOTH spellings"
    as 1001 "$PROBE" chrome /dev/wsys/ctl 'wallpaper /a.ppm' | sed 's/^/== wp.ctl./'
    as 1001 "$PROBE" read /dev/wsys/wallpaper                | sed 's/^/== wp.afterctl./'
    as 1001 "$PROBE" chrome /dev/wsys/wallpaper 'WPFILE'     | sed 's/^/== wp.file./'
    as 1001 "$PROBE" read /dev/wsys/wallpaper                | sed 's/^/== wp.afterfile./'
    kill "$HOLDER" 2>/dev/null
    exit 0
fi

# ---- outer half ----------------------------------------------------------
W="$(mktemp -d "${TMPDIR:-/tmp}/wsysbypass.XXXXXX")"
trap 'rm -rf "$W"' EXIT
# 1777 for the same reason wsys_uidgate.sh needs it: two uids create files in
# here, and /srv on a real boot is 1777 too -- which is what makes
# fs.protected_regular relevant to both segments in the first place.
chmod 1777 "$W"

if [ -n "${WSYS_UIDGATE_BIN:-}" ]; then cp "$WSYS_UIDGATE_BIN" "$W/wsys_uidgate"
else
    ./scripts/hamlinux_build.sh tests/linux/wsys_uidgate.ad "$W/wsys_uidgate" \
        >"$W/build.log" 2>&1 || { cat "$W/build.log"; echo "BUILD FAILED"; exit 2; }
fi
cc -std=gnu11 -O1 -o "$W/wsys_bypass" tests/linux/wsys_bypass.c \
    >>"$W/build.log" 2>&1 || { cat "$W/build.log"; echo "BUILD FAILED"; exit 2; }
chmod 755 "$W/wsys_uidgate" "$W/wsys_bypass"
cp "$0" "$W/inner.sh"; chmod 755 "$W/inner.sh"

command -v unshare >/dev/null || { echo "SKIP: no unshare(1)"; exit 0; }
grep -q "^$(id -un):" /etc/subuid 2>/dev/null || {
    echo "SKIP: no /etc/subuid range for $(id -un); run this in the VM instead"
    exit 0; }
SUB="$(awk -F: -v u="$(id -un)" '$1==u{print $2; exit}' /etc/subuid)"
OUT="$W/out.txt"
unshare -U \
    --map-users=0:"$(id -u)":1  --map-groups=0:"$(id -g)":1 \
    --map-users=1001:"$SUB":1   --map-groups=1001:"$SUB":1 \
    -- "$W/inner.sh" --inner "$W" >"$OUT" 2>&1
rc=$?
cat "$OUT"
[ $rc -eq 0 ] || { echo "namespace setup failed (rc=$rc)"; exit 2; }

line() { grep -m1 "^== $1" "$OUT"; }
has()  { line "$1" | grep -q -- "$2"; }

note ""
note "the file modes, which after the split ARE the access control:"
if grep -q "^== ls .*rw-rw-rw-.*seg$" "$OUT"; then ok "window table is 0666"
else bad "window table is not 0666 -- an unprivileged client cannot map it"; fi
if has bypass.chrome "mode=0644"; then ok "chrome segment is 0644"
else bad "chrome segment is not 0644: $(line bypass.chrome)"; fi
if has bypass.chrome "uid=0"; then ok "chrome segment is owned by the host owner"
else bad "chrome segment is not the host owner's: $(line bypass.chrome)"; fi

note ""
note "THE HOLE, still open on the window table (the positive control):"
note "  attack 1 of 3 -- RETITLE another client's window:"
if has bypass.table "found=1"; then ok "a bypasser maps the real window table"
else bad "the bypass never found the table -- the test is measuring nothing"; fi
if has bypass.table "wrote=1"; then ok "and overwrites a window title in it"
else bad "the bypass could not write the 0666 table; control is broken"; fi
if has after.table "PWNEDBYPASSER"; then
    ok "the protocol reads the overwritten title back -- a real compromise"
else bad "the overwrite did not reach the protocol: $(line after.table)"; fi

note "  attack 2 of 3 -- SCRIBBLE another client's committed scene:"
if has bypass.scene "found=1"; then ok "a bypasser finds the published scene"
else bad "the bypass never found the scene: $(line bypass.scene)"; fi
if has bypass.scene "wrote=1"; then ok "and overwrites a colour in the display list"
else bad "the bypass could not write the scene: $(line bypass.scene)"; fi
if has after.scene "0xDEAD99"; then
    ok "the protocol reads the scribbled scene back through <wid>/scene"
else bad "the scribble did not reach the protocol: $(line after.scene)"; fi

note "  attack 3 of 3 -- INJECT a key into another client's ring:"
if has injkey.table "found=1"; then ok "a bypasser locates the victim's window row"
else bad "the bypass never found the row: $(line injkey.table)"; fi
if has injkey.table "wid=2"; then ok "and it is the right row (wid 2), by its own read-back"
else bad "injkey landed on the wrong row -- layout mirror drifted? $(line injkey.table)"; fi
if has injkey.table "wrote=1"; then ok "and pokes a key line into its keys ring"
else bad "the bypass could not write the ring: $(line injkey.table)"; fi
if has after.keys "7 111"; then
    ok "the protocol drains the injected key through <wid>/keys -- a real compromise"
else bad "the injected key did not reach the protocol: $(line after.keys)"; fi

note ""
note "AND WHY NO FILE MODE CLOSES IT: same uid attacks same uid."
note "(the measurement that rejects a mapping-per-owner-uid: on a real"
note " desktop attacker and victim are both uid 1001, and the kernel"
note " cannot tell two processes of one uid apart.)"
if grep -q "^== live.hold.client .*wid=[0-9]" "$OUT"; then
    ok "a uid-1001 victim holds a window: $(line live.hold.client)"
else bad "the same-uid victim never came up: $(line live.hold.client)"; fi
if has sameuid.inj "wrote=1"; then
    ok "a SEPARATE uid-1001 process injects into it -- no uid boundary to cross"
else bad "the same-uid injection did not write: $(line sameuid.inj)"; fi
if has sameuid.keys "9 222"; then
    ok "and the protocol reads the injected key back: two uid-1001 apps, no gate"
else bad "the same-uid injection did not reach the protocol: $(line sameuid.keys)"; fi

note ""
note "THE HOLE, CLOSED on the chrome segment -- by the kernel, not by an if:"
if has bypass.chrome "open_rdwr=-13"; then ok "open(O_RDWR) refused, EACCES"
else bad "the kernel allowed O_RDWR on the chrome segment: $(line bypass.chrome)"; fi
if has bypass.chrome "mmap_rw=skip"; then ok "no writable mapping to be had"
else bad "a writable mapping was obtained: $(line bypass.chrome)"; fi
if has bypass.chrome "mprotect_w=FAIL"; then
    ok "mprotect(PROT_WRITE) on the read-only mapping refused too"
else bad "mprotect opened a second door: $(line bypass.chrome)"; fi
if has bypass.chrome "wrote=0"; then ok "nothing was written"
else bad "the chrome segment was written: $(line bypass.chrome)"; fi
if has after.chrome "CHROMEMARK"; then ok "the chrome state is intact afterwards"
else bad "the chrome state changed: $(line after.chrome)"; fi

note ""
note "and the session is NOT blind, which is the failure worse than the hole:"
if has bypass.chrome "found=1"; then
    ok "a non-owner maps the chrome PROT_READ and sees what the owner published"
else bad "a non-owner cannot read the chrome segment: $(line bypass.chrome)"; fi
if has live.screen "1280 800"; then ok "live reads /dev/wsys/screen: 1280 800"
else bad "live cannot read the screen geometry: $(line live.screen)"; fi
if has live.chromeread "CHROMEMARK"; then ok "live reads a chrome sink"
else bad "live cannot read a chrome sink: $(line live.chromeread)"; fi
if line live.client | grep -q "exit=\|wid="; then
    if line live.client | grep -q -- "=-"; then
        bad "live could not map and draw its own window: $(line live.client)"
    else ok "live still maps and draws its own window"; fi
else bad "no client line at all: the run did not get that far"; fi

note ""
note "wallpaper is ungated in both spellings, as devwsys has it:"
if ! has wp.ctl -- "=-"; then ok "live writes \`wallpaper\` on /dev/wsys/ctl"
else bad "the ctl spelling was refused: $(line wp.ctl)"; fi
if has wp.afterctl "wallpaper /a.ppm"; then ok "and it lands in the wallpaper sink"
else bad "the ctl spelling went nowhere: $(line wp.afterctl)"; fi
if ! has wp.file -- "=-"; then ok "live writes /dev/wsys/wallpaper directly"
else bad "the file spelling was refused: $(line wp.file)"; fi
if has wp.afterfile "WPFILE"; then ok "and it lands in the SAME sink"
else bad "the file spelling went nowhere: $(line wp.afterfile)"; fi

note ""
[ $fail -eq 0 ] && echo "PASS wsys_bypass" || echo "FAIL wsys_bypass"
exit $fail
