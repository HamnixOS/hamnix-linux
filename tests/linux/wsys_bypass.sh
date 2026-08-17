#!/usr/bin/env bash
#
# REGISTRATION, 2026-08-17. Until this date scripts/test_gate_registration.sh
# globbed only scripts/test_*.sh, so this directory was invisible to the gate
# against unregistered gates and every file in it read as coverage without
# being coverage. This gate is ON-DEMAND: not in ci_battery_manifest.txt
# because nobody has measured its host runtime yet, and the battery is 12-way
# sharded under a 50-minute cap -- registering an unmeasured gate is how a
# shard goes from green to timed-out. Measure it, then move it into the
# manifest.
#
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
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
# FIVE ATTACKS NOW, and the fifth was found by asking what an attacker does
# AFTER attack 4 is closed.  The keystrokes left the mapping, so nothing can be
# read out of the table any more -- but the victim still holds them in its own
# address space, and /proc/<pid>/mem is readable by any process of the same uid
# whose target is dumpable, with no ptrace call and nothing to notice.  The
# table hands over `pid=` (it must: the taskbar reads that row), so the chain is
# two steps long.  It is closed by prctl(PR_SET_DUMPABLE, 0) in every window
# owner, and by kernel.yama.ptrace_scope=1 at boot for the ptrace half.
#
# FOUR ATTACKS, NOT THREE, and the fourth is the one that decides the fix.
# Attacks 1-3 (retitle, scribble, inject) are INTEGRITY: each needs PROT_WRITE,
# and the 0644 chrome segment shows exactly what the kernel does to them when it
# refuses that.  Attack 4 is CONFIDENTIALITY -- read another window's
# keystrokes, its committed scene, and its whole row -- and it runs O_RDONLY.
# It is here because it is what rules out the last cheap fix anybody will
# propose after reading THE SPLIT: keep ONE table, make it 0644, put every write
# behind an authenticated RPC to wsysd.  That closes 1-3 and NONE of 4, because
# the table has to stay world-readable for the panel taskbar to list windows and
# for a uid-1001 client to read the geometry root published.  A keylogger
# between two of the user's own applications survives it untouched.  So the fix
# is not a mode and not an RPC in front of a shared table: it is per-window
# memory a non-owner cannot map, handed out by the authority at create time.
# tests/linux/wsys_write_census.sh measures what that authority would cost.
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
    # HAMWSYS_BB, EXPLICITLY, and this line is a bug fix as well as a
    # prerequisite.  The v2 backbuffer store is NOT named from $HAMWSYS the way
    # the chrome segment is -- bb_attach has its own candidate list, and with
    # this unset it falls through /srv (unwritable here) to the HOST's
    # /dev/shm/hamnix-wsys-bb, which every other gate that sets it avoids.  So
    # this gate has been creating a shared segment outside its own temp
    # directory on every run, and the `rm -f "$HAMWSYS".bb` below has been
    # removing a file nothing ever created.  It is also what makes the v2
    # scrape below MEASURABLE: a store this gate cannot name is a store it
    # cannot honestly report as open.
    export HAMWSYS_BB="$HAMWSYS.bb"
    rm -f "$HAMWSYS" "$HAMWSYS".bb "$HAMWSYS".chrome

    # FROM $W, NOT FROM THE TREE. The inner half is a COPY of this file at
    # $W/inner.sh, so the $PROJ_ROOT computed at the top of it -- dirname of
    # the copy, up two -- is `/`, and the shell has already cd'd there. A
    # relative `. tests/linux/reap.sh` here silently found nothing: the traps
    # were never installed, every reap_add was a "command not found", and the
    # error text landed in the `== root.` stream the assertions below parse.
    # The outer half copies the helper in beside inner.sh for this reason.
    . "$W/reap.sh"
    reap_track "$W/reaped.inner"
    reap_on_exit

    as() { local u="$1"; shift
        if [ "$u" = 0 ]; then "$@" 2>&1
        else setpriv --reuid="$u" --regid="$u" --clear-groups "$@" 2>&1; fi; }

    # BACKGROUNDING A SHELL FUNCTION LOSES THE PROCESS YOU WANTED.
    # `as 0 "$PROBE" client hold &` forks a subshell to run the function, and
    # the function then forks AGAIN to run the probe -- so $! is the WRAPPER.
    # `kill "$HOLDER"` killed the wrapper and ORPHANED the probe onto init,
    # where it sat for ever. This gate left exactly two wsys_uidgate processes
    # behind on every single run, and still printed "PASS wsys_bypass": the
    # namespace here is `unshare -U`, a USER namespace with no pid namespace,
    # so nothing collects the orphans. `exec` inside the subshell makes the
    # backgrounded process the probe itself, so $! names what we mean to kill.
    as_bg() { local u="$1"; shift
        if [ "$u" = 0 ]; then ( exec "$@" ) &
        else ( exec setpriv --reuid="$u" --regid="$u" --clear-groups "$@" ) & fi
        reap_add $!; }

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
    # THE DRAIN FLAG.  Both holders keep their own keys fd open from the start
    # -- that is what claims the window's channel -- but read NOTHING until this
    # file exists.  A drain is destructive, and a witness that drains while the
    # attacks are being driven eats the evidence: with it draining freely this
    # gate went GREEN ON THE REVERTED RUN, reporting that the keystrokes were
    # not in the mapping about a hole that was wide open.
    DRAIN="$W/drain.flag"
    rm -f "$DRAIN"
    as_bg 0 "$PROBE" client hold "$DRAIN" >"$W/root.client.out" 2>&1
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

    # 2. THE BYPASS, from the unprivileged uid.  ALL FOUR attacks THE SPLIT
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
    #      AND THE HALF OF SCRAPE THAT IS STILL OPEN, driven as a POSITIVE
    #      control on every green run.  The v1 display list left the segment for
    #      a per-window memfd; /srv/wsys.bb, which holds every v2 window's
    #      PIXELS -- a browser, a video, a bridged X client -- did not.  So a
    #      hamUI application's screen contents are private on this machine and
    #      FIREFOX'S ARE NOT, and nothing about the two windows says which is
    #      which.  The day that closes, this assertion is what says so.
    #      THE STORE IS CREATED LAZILY, so it has to be made to exist before it
    #      can be measured -- a stat of a file that is not there would have
    #      reported "no backbuffer store" about a segment every v2 client on a
    #      real desktop is sharing.  A 17-byte 'D' (damage/publish) record on
    #      the window's draw ctl is the smallest thing that flips a window to
    #      protocol 2 and allocates its slot; the rectangle in it is never read
    #      because the surface has nothing started, so this creates the store
    #      and draws nothing.
    as 0 "$PROBE" chrome /dev/wsys/2/draw/ctl 'D000000000000000' \
        | sed 's/^/== bbmake./'
    as 1001 "$BYP" bbscrape "$HAMWSYS".bb 'NOTHINGBLITTEDINTHISGATE' sameuid.bb

    # 3. What the PROTOCOL sees afterwards.  This is what makes step 2 mean
    #    something: a write into a mapping that nothing reads back is not a
    #    compromise, and a refusal on a segment nobody can read is not a
    #    working desktop.
    echo "-- the protocol's view afterwards"
    as 0    "$PROBE" read /dev/wsys/windows  | sed 's/^/== after.table./'
    as 0    "$PROBE" read /dev/wsys/lock     | sed 's/^/== after.chrome./'
    as 0    "$PROBE" read /dev/wsys/2/scene  | sed 's/^/== after.scene./'
    # NOT "read the victim's ring from a third process" any more.  Keystrokes
    # are delivered to whoever holds the window's channel and only the OWNER can
    # hold it, so this read is now REFUSED BY NAME -- and the question it used to
    # ask ("did the injected key reach the protocol?") is asked of the holder
    # itself further down, which is a better witness than a stand-in.
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
    # THE NEEDLE THE VICTIM PAINTS.  This holder also renders a v2 BACKBUFFER
    # whose pixels are this exact byte string -- it is the browser-shaped window
    # whose screen contents the backbuffer scrape below recovers by name.  The
    # string is distinctive so a hit in the 8 GB store is the victim's pixels
    # and not a coincidence.
    BBSECRET='BACKBUFFERSECRET31337'
    as_bg 1001 "$PROBE" client hold "$DRAIN" "$BBSECRET" >"$W/live.client.out" 2>&1
    LHOLDER=$!
    for _ in $(seq 1 50); do
        grep -q 'blit=1' "$W/live.client.out" 2>/dev/null && break
        sleep 0.1
    done
    sed 's/^/== live.hold./' "$W/live.client.out"
    LWID="$(sed -n 's/.*wid=\([0-9][0-9]*\).*/\1/p' "$W/live.client.out" | head -1)"
    # THE REAL BACKBUFFER SCRAPE, and the one that decides the fix.  The victim
    # above rendered a v2 backbuffer whose pixels ARE $BBSECRET; now a SEPARATE
    # uid-1001 process -- no protocol, no /dev/wsys, just open+mmap of the store
    # -- recovers those exact bytes by walking the shared surface.  This is the
    # "Firefox's pixels are readable" finding, driven end to end: a hit here is
    # the victim's screen contents in the attacker's hands.  On the old tree it
    # MUST find them (the positive control that proves the scrape is real); the
    # day the store goes private it MUST NOT, and this assertion says which.
    as 1001 "$BYP" bbscrape "$HAMWSYS".bb "$BBSECRET" sameuid.bbreal
    # The attacker is a SEPARATE process at the SAME uid 1001 -- no file-mode
    # boundary exists between it and the victim, and none could.  It targets the
    # victim by WID rather than by title, because "uidgate probe" is the title
    # every probe window carries (including the reaped not-blind one above) and
    # a title needle would alias to a stale row; a hostile program that has read
    # struct wshm walks win[] for the wid just as readily.
    # THE PROTOCOL READ FIRST, AND THE INJECTION AFTER.  A uid-1001 non-owner
    # asking for the victim's keystrokes through the protocol is itself an
    # attack, and it is now refused by name.  It runs BEFORE the injection
    # because a library without this change would SERVE it -- draining the
    # injected key and hiding it from the victim, which would make the
    # assertion below pass for the wrong reason on the reverted run.
    as 1001 "$PROBE" read "/dev/wsys/${LWID:-0}/keys" | sed 's/^/== sameuid.keys./'
    as 1001 "$BYP" injkey "$HAMWSYS" "wid=${LWID:-0}" '9 222' sameuid.inj

    #     AND THE ATTACK THE NEW CHANNEL INVITES, driven rather than assumed.
    #     The keys ring left the segment for an ABSTRACT AF_UNIX address, and an
    #     abstract socket has no file mode: its name is derived from the
    #     segment's st_dev/st_ino and the wid, all of them public, so anybody can
    #     compute it and anybody can sendto() it.  If that were the whole story
    #     the keylogger would simply have become a key INJECTOR at a new address.
    #     It is not: the receiver drops every datagram the KERNEL did not stamp
    #     (SO_PASSCRED/SCM_CREDENTIALS) with the host owner's uid.
    #
    #     Both directions are driven, because a refusal measured without a
    #     matching success proves only that the address was wrong:
    #       uid 1001  the attacker.  sendto SUCCEEDS -- nothing can stop it --
    #                 and the victim must never see the line.
    #       uid 0     the host owner, i.e. what wsysd does on every keystroke.
    #                 The same program, the same address, and it MUST arrive.
    as 1001 "$BYP" keysend "$HAMWSYS" "${LWID:-0}" '9 333' sameuid.keysend
    as 0    "$BYP" keysend "$HAMWSYS" "${LWID:-0}" '9 444' hostowner.keysend
    sleep 0.5

    # 3b. THE FOURTH ATTACK, and the half the other three do not touch:
    #     CONFIDENTIALITY.  Everything above needs PROT_WRITE, so a reader can
    #     still hope that one table at 0644 with every write behind an
    #     authenticated RPC would close the lot.  It would not close ANY of
    #     this, because the table has to stay world-READABLE -- the panel
    #     taskbar parses every window's title out of it, and the 0644 chrome
    #     segment above is proof that "readable by everyone" is exactly what
    #     this project ships when it protects something.
    #
    #     The compositor routes a keystroke into the victim's ring, which is
    #     what wsysd's deliver_key does on every key a person presses; then a
    #     SEPARATE uid-1001 process reads it out of the mapping O_RDONLY,
    #     without disturbing r or w, so the victim receives it normally and
    #     cannot tell.  The preceding protocol read drained the ring, so the
    #     only bytes between r and w are the ones typed after it.
    echo "-- same-uid: reading the victim's keystrokes, O_RDONLY"
    as 0 "$PROBE" chrome "/dev/wsys/${LWID:-0}/keys" '1 PASSWORD31337' \
        | sed 's/^/== sameuid.typed./'
    as 1001 "$BYP" snoop "$HAMWSYS" "wid=${LWID:-0}" sameuid.snoop
    # AND THE VICTIM STILL GETS IT, ASKED OF THE VICTIM.  A fix that closed the
    # keylogger by breaking keyboard delivery would pass every assertion above
    # and ship a desktop nobody can type into, so the victim's OWN drain is
    # printed here and asserted on.  It is the holder process itself: it opened
    # /dev/wsys/<wid>/keys at startup and prints a `keysgot [...]` line for
    # every event it receives (tests/linux/wsys_uidgate.ad, hold_open).
    # ATTACK 3 AGAINST THE uid-0 WINDOW, DRIVEN LAST ON PURPOSE.  It used to run
    # up with the other three, and the `read /dev/wsys/2/keys` in step 3 -- the
    # one that now measures a refusal -- would DRAIN the injected key before its
    # owner could be asked about it, so on the reverted run the owner truthfully
    # reported never receiving a key that had in fact been delivered to somebody.
    # One ring, two questions, and the earlier reader consumed the answer to the
    # later one.  The injection happens after every read, so nothing but the
    # owner can consume it.
    as 1001 "$BYP" injkey "$HAMWSYS" 'PWNEDBYPASSER' '7 111'

    # EVERY ATTACK HAS BEEN DRIVEN.  Now let the witnesses drain and say what
    # they actually received.
    : >"$DRAIN"
    chmod 666 "$DRAIN"
    sleep 1
    sed 's/^/== victim./' "$W/live.client.out"

    # 3b'. THE ATTACK THE PIXEL HAND-UP INVITES, and its matching success.
    #
    #      The display list left the segment for a per-window memfd the OWNER
    #      hands to the compositor over an ABSTRACT AF_UNIX rendezvous.  An
    #      abstract name has no file mode and this one is derived from public
    #      facts, so anybody can bind it -- and if the RECEIVER were the one
    #      checking credentials, as it is for the keystroke channel, a uid-1001
    #      attacker that got there first would be handed every client's display
    #      list.  That is a strictly WORSE hole than the one being closed,
    #      reached by copying a construction that is right in the other
    #      direction.  What refuses it is that THE SENDER checks: getsockopt
    #      SO_PEERCRED on the connection it just made, against the segment's
    #      owner.
    #
    #      BOTH DIRECTIONS, for the reason keysend is driven from both uids: a
    #      refusal measured without a matching success proves only that the
    #      address was wrong.  The uid-0 run is what wsysd is on a real boot and
    #      it MUST receive a display list; the uid-1001 run is the attacker and
    #      MUST receive nothing.  The attacker runs FIRST, so that the success
    #      cannot be mistaken for something the refusal left behind.
    #
    #      IT IS HERE AND NOT WITH THE OTHER ATTACKS because a hand-up is the
    #      CLIENT's action on the client's own clock, driven from the wsys calls
    #      it makes -- and the holders make none at all until the drain flag
    #      above lets them read their own rings.  Before that line they are
    #      parked in sys_waitfds and would hand nothing to anybody, attacker or
    #      compositor, which would make the refusal below pass for a reason that
    #      has nothing to do with the check under test.
    echo "-- the pixel hand-up rendezvous, from both uids"
    as 1001 "$BYP" pixgrab "$HAMWSYS" 2500 sameuid.pixgrab
    as 0    "$BYP" pixgrab "$HAMWSYS" 2500 hostowner.pixgrab
    # The client says on stderr that it refused a stranger the descriptor.  Its
    # output was already printed above under `victim.`, before any of this ran,
    # so it is re-read here.
    sed 's/^/== pixvictim./' "$W/live.client.out"

    # AND THE SAME FOR THE BACKBUFFER, which is the whole point of this pass: the
    # v2 pixels left /srv/wsys.bb for a per-window memfd handed up over
    # "…/backbuffer", so both ends are driven exactly as the scene's are.  The
    # attacker binds first and must be handed nothing; the segment owner then
    # binds and MUST recover the victim's BACKBUFFERSECRET31337 -- which is the
    # compositor working and the positive control for the sameuid.bbreal=found=0
    # assertion above.  It runs here, after DRAIN, because the victim only ticks
    # its hand-up once it is reading its ring (see hold_open).
    as 1001 "$BYP" bbgrab "$HAMWSYS" 2500 "$BBSECRET" bbgrab.attacker
    as 0    "$BYP" bbgrab "$HAMWSYS" 2500 "$BBSECRET" bbgrab.owner

    # 3c. ATTACK 5 OF 5 -- PEEK, and it is the one that walks THROUGH attack 4's
    #     fix.  The keystrokes left the mapping, so the snooper above finds
    #     nothing; but the VICTIM still has them in its own address space, and on
    #     Linux one process reads another of the SAME UID out of /proc/<pid>/mem
    #     with no ptrace call, no stop and no trace.  The chain starts exactly
    #     where attack 4 ended: the world-readable table hands over `pid=`.
    #
    #     IT RUNS LAST, AFTER THE VICTIM HAS BEEN READ.  Two reasons, and the
    #     second is the destructive-witness rule this file has been bitten by
    #     twice.  (1) The password is only IN the victim's memory once the victim
    #     has drained it -- before the drain it is sitting in a kernel socket
    #     buffer and a memory scrape would truthfully find nothing, which would
    #     pass on the reverted run for the wrong reason.  (2) The PTRACE_ATTACH
    #     it ends with STOPS the victim, so nothing may observe it afterwards.
    as 1001 "$BYP" peek "$HAMWSYS" "wid=${LWID:-0}" 'PASSWORD31337' sameuid.peek
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
    # The uid-0 holder's own drain, for attack 3's read-back: it owns wid 2, so
    # if the injected "7 111" ever reached the protocol, this is where it lands.
    sed 's/^/== rootvictim./' "$W/root.client.out"
    kill "$HOLDER" 2>/dev/null
    exit 0
fi

# ---- outer half ----------------------------------------------------------
W="$(mktemp -d "${TMPDIR:-/tmp}/wsysbypass.XXXXXX")"
. tests/linux/reap.sh
reap_on_exit_cleanup() { rm -rf "$W"; }
reap_on_exit reap_on_exit_cleanup
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
# The inner half runs as a copy in $W with $PROJ_ROOT resolving to `/`, so it
# cannot reach the tree to source the reaper. It gets its own copy here.
cp tests/linux/reap.sh "$W/reap.sh"

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
note "  attack 1 of 4 -- RETITLE another client's window:"
if has bypass.table "found=1"; then ok "a bypasser maps the real window table"
else bad "the bypass never found the table -- the test is measuring nothing"; fi
if has bypass.table "wrote=1"; then ok "and overwrites a window title in it"
else bad "the bypass could not write the 0666 table; control is broken"; fi
if has after.table "PWNEDBYPASSER"; then
    ok "the protocol reads the overwritten title back -- a real compromise"
else bad "the overwrite did not reach the protocol: $(line after.table)"; fi

note "  attack 2 of 4 -- SCRIBBLE another client's committed scene:"
note "  (CLOSED, and the controls below are INVERTED rather than deleted, the"
note "   same way attack 3's were.  The bypasser is UNCHANGED: it still maps the"
note "   0666 table read/write, still searches it for the victim's committed"
note "   display list, and the assertion that it MAPPED the table must keep"
note "   passing.  What changed is that the display list is not in the mapping"
note "   at all -- it lives in a per-window memfd the owner hands to the"
note "   compositor, THE PIXEL HAND-UP in user/linux-wsys.c -- so there is"
note "   nothing there to find and nothing there to scribble.)"
if has bypass.scene "open_rdwr=[0-9]"; then
    ok "a bypasser still opens the 0666 table read/write"
else bad "the bypass could not open the table; the control is broken: $(line bypass.scene)"; fi
if has bypass.scene "mmap_rw=0"; then
    ok "and still maps it MAP_SHARED PROT_WRITE"
else bad "the bypass could not map the table; the control is broken: $(line bypass.scene)"; fi
if has bypass.scene "found=1"; then
    bad "INVERTED CONTROL FAILED: the committed display list is back in the"\
        "0666 mapping: $(line bypass.scene)"
else ok "AND THE COMMITTED DISPLAY LIST IS NOT THERE: the needle the victim"\
       "drew is not in the table (was: found, and overwritten)"; fi
if has after.scene "0xDEAD99"; then
    bad "INVERTED CONTROL FAILED: a scribble into the table reached the"\
        "protocol through <wid>/scene: $(line after.scene)"
else ok "and nothing a bypasser writes there reaches the protocol"; fi
# A REFUSAL THAT NAMES THE WINDOW, not a silent zero-byte read -- the same
# standard the keys refusal is held to.  A read that succeeded and returned
# nothing would be this tree's own worst bug shape.
if grep -q "neither owns window 2 nor holds its display list" "$OUT"; then
    ok "and a process that holds neither is refused BY NAME, not with an empty read"
else bad "the scene read did not name its refusal: $(line after.scene)"; fi

note ""
note "  AND THE HALF OF SCRAPE THAT IS STILL OPEN (a positive control):"
note "  (the v1 display list left the segment; /srv/wsys.bb, which holds every"
note "   v2 window's PIXELS -- a browser, a video, a rootless Xwayland -- did"
note "   not.  A hamUI app's screen contents are private on this machine and"
note "   FIREFOX'S ARE NOT, and nothing about the two windows says which is"
note "   which.  This runs on every green run so nobody can come to believe"
note "   otherwise.)"
if has sameuid.bb "mode=0666"; then
    ok "STILL OPEN: the v2 backbuffer store is 0666"
else bad "the backbuffer segment's mode was not read: $(line sameuid.bb)"; fi
if has sameuid.bb "ro=1"; then
    ok "and the scrape asked for no write access: O_RDONLY, PROT_READ"
else bad "the backbuffer scrape did not run read-only: $(line sameuid.bb)"; fi
if has sameuid.bb "mapped=1"; then
    note "  (the store is still a shared mapping an attacker can open; what"
    note "   decides the fix is whether a victim's PIXELS come back through it,"
    note "   which the real scrape below measures)"
else bad "the attacker could not map the v2 backbuffer store: $(line sameuid.bb)"; fi

note ""
note "  THE REAL BACKBUFFER SCRAPE -- a victim's actual pixels, recovered by a"
note "  same-uid process (this is the finding, driven end to end):"
note "  (the victim rendered a v2 backbuffer whose pixels are BACKBUFFERSECRET"
note "   31337; a SEPARATE uid-1001 process then opened the store O_RDONLY and"
note "   searched it.  found=1 is the victim's screen contents in the attacker's"
note "   hands -- Firefox's pixels read by name.  The instrument is proven by the"
note "   POSITIVE CONTROL: the compositor's own hand-up read below recovers the"
note "   SAME bytes, so a found=0 for the attacker is a closed store, not a"
note "   window that never painted.)"
# THE POSITIVE CONTROL FIRST -- the pixels exist and are reachable by the one
# process entitled to them.  On the old tree that is the raw shared store (the
# hole); on the fixed tree it is the memfd hand-up (bbgrab as the segment owner).
if has bbgrab.owner "found=1"; then
    ok "the compositor (segment owner) recovers the victim's pixels: the window"\
       "really painted BACKBUFFERSECRET31337, so the attacker's result is meaningful"
else bad "the instrument did not confirm the pixels exist -- a scrape result"\
        "against a blank window proves nothing: $(line bbgrab.owner)"; fi
# THE ATTACK ITSELF -- the fixed-tree expectation is that it comes back EMPTY.
# On the unfixed tree this line goes RED, which is the point: a gate that has
# never gone red is not a gate.
if has sameuid.bbreal "found=0"; then
    ok "CLOSED: a same-uid attacker recovers NO pixel content from the store"
else bad "OPEN: a same-uid attacker recovered the victim's backbuffer pixels"\
        "by name -- Firefox's screen contents are readable: $(line sameuid.bbreal)"; fi
# AND THE ATTACKER'S HAND-UP GRAB IS REFUSED, the way pixgrab's is, so the fix
# is not merely "the pixels moved to a place this one scrape misses".
if has bbgrab.attacker "found=0"; then
    ok "and the attacker's hand-up grab is refused too: no pixels by that route either"
else note "  (bbgrab.attacker not measured on this tree: $(line bbgrab.attacker))"; fi

note "  attack 3 of 4 -- INJECT a key into another client's ring:"
note "  (CLOSED, and the control below is INVERTED rather than deleted.  The"
note "   bypasser still maps the table, still finds the row and still writes the"
note "   ring -- the first three assertions are unchanged and must keep passing,"
note "   because the day they stop the test has stopped measuring anything.  What"
note "   changed is that the ring is DEAD STORAGE: keystrokes are delivered over"
note "   a channel that is not in the mapping at all, so the write lands in bytes"
note "   nothing reads.  THE SPLIT: attack 4 of 4 forced this and attack 3 is"
note "   closed by the same construction, for the keys ring.)"
if has injkey.table "found=1"; then ok "a bypasser locates the victim's window row"
else bad "the bypass never found the row: $(line injkey.table)"; fi
if has injkey.table "wid=2"; then ok "and it is the right row (wid 2), by its own read-back"
else bad "injkey landed on the wrong row -- layout mirror drifted? $(line injkey.table)"; fi
if has injkey.table "wrote=1"; then ok "and pokes a key line into its keys ring"
else bad "the bypass could not write the ring: $(line injkey.table)"; fi
if grep -q "^== rootvictim.keysgot .*7 111" "$OUT"; then
    bad "INVERTED CONTROL FAILED: the injected key reached the window's owner"
else ok "and the owner never receives it: the ring it wrote is not the channel"; fi
# THE REFUSAL IS ON TWO LINES because the probe's own stdout and the library's
# named diagnostic on stderr are merged by `as`.  Both are asserted: a refusal
# that does not SAY which window and why is a refusal a person has to guess at.
if grep -q "^== after\.keys\..*open=-1" "$OUT"; then
    ok "and a third process cannot read that window's keys at all: refused"
else bad "a non-owner still opened another window's keys: $(line after.keys)"; fi
if grep -q "does not own window 2, so it cannot read its keystrokes" "$OUT"; then
    ok "and it is refused BY NAME, not with a silent zero-byte read"
else bad "the refusal did not name the window: $(line after.keys)"; fi

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
# INVERTED.  This used to read the injected key back and call it "two uid-1001
# apps, no gate".  The mapping it wrote is no longer the delivery path.
if grep -q "^== sameuid\.keys\..*open=-1" "$OUT"; then
    ok "a uid-1001 non-owner asking for them through the protocol is refused"
else bad "a non-owner read the victim's keys through the protocol: $(line sameuid.keys)"; fi
if grep -q "^== victim.keysgot .*9 222" "$OUT"; then
    bad "INVERTED CONTROL FAILED: the same-uid injection reached the victim"
else ok "and the victim never receives it -- the ring it wrote is dead storage"; fi

note ""
note "and the channel that replaced it is not open by default either:"
note "(an abstract socket has no file mode and its name is public, so the"
note " attacker CAN address it; what refuses it is the kernel's credential"
note " stamp on the datagram, which is why both directions are driven.)"
if has sameuid.keysend "sent=1"; then
    ok "a uid-1001 attacker computes the address and the sendto SUCCEEDS"
else bad "the attacker's sendto failed -- this proves nothing: $(line sameuid.keysend)"; fi
if has hostowner.keysend "sent=1"; then
    ok "so does the host owner's, byte for byte the same program and address"
else bad "the host owner's sendto failed -- the control is broken: $(line hostowner.keysend)"; fi
if grep -q "^== victim.keysgot .*9 444" "$OUT"; then
    ok "and ONLY the host owner's line arrives: SCM_CREDENTIALS, not obscurity"
else bad "the host owner's keystroke never arrived -- delivery is broken, and"\
        "every refusal above would then be meaningless"; fi
if grep -q "^== victim.keysgot .*9 333" "$OUT"; then
    bad "INVERTED CONTROL FAILED: the uid-1001 attacker's keystroke arrived"
else ok "and the uid-1001 one is dropped, unstamped, by the receiving kernel"; fi

note ""
note "attack 6 of 6 -- PIXGRAB: bind the pixel hand-up address and be handed"
note "the desktop's display lists."
note "(the attack the new channel invites, and the one that decides whether it"
note " is sound.  The rendezvous is an ABSTRACT AF_UNIX name with no file mode,"
note " derived from public facts, so ANYBODY can bind it -- and a receiver-checks"
note " construction, which is exactly what the keystroke channel correctly uses,"
note " would here hand every client's screen to whoever bound it first.  Which"
note " end holds the secret decides which end checks: THE SENDER checks, with"
note " SO_PEERCRED on the connection it just made.)"
if has sameuid.pixgrab "bound=1"; then
    ok "a uid-1001 attacker CAN take the address -- nothing can stop it"
else bad "the attacker never bound the address, so its zero below proves"\
        "nothing: $(line sameuid.pixgrab)"; fi
if has sameuid.pixgrab "fds=0"; then
    ok "AND NOT ONE CLIENT HANDS IT A DESCRIPTOR: fds=0, no display list"
else bad "CONTROL FAILED: a uid-1001 attacker was handed a window's display"\
        "list: $(line sameuid.pixgrab)"; fi
if has sameuid.pixgrab "scene=\["; then
    bad "CONTROL FAILED: the attacker read a victim's display list:"\
        "$(line sameuid.pixgrab)"
else ok "and there is nothing to read: no scene came back at all"; fi
if grep -q "pixel hand-up address is held by uid" "$OUT"; then
    ok "and the client SAYS SO, by name, on stderr -- a refusal nobody sees is"\
       "how a desktop stops painting for no stated reason"
else bad "the client refused silently: no named diagnostic in the run"; fi
# THE MATCHING SUCCESS.  A refusal with no matching success proves only that
# the address was wrong -- the rule keysend is driven under, applied here.
if has hostowner.pixgrab "bound=1"; then
    ok "the SEGMENT OWNER (what wsysd is on a real boot) binds the same address"
else bad "the host owner could not bind: $(line hostowner.pixgrab)"; fi
if grep -q "^== hostowner.pixgrab .* fds=[1-9]" "$OUT"; then
    ok "and IS handed the descriptors: the same program, the same address, and"\
       "the only difference is who the kernel says is listening"
else bad "the host owner was handed nothing, so the refusal above proves only"\
        "that the address was wrong: $(line hostowner.pixgrab)"; fi
if has hostowner.pixgrab "rect 0 0 40 20"; then
    ok "and reads the victim's committed display list out of the memfd -- which"\
       "is the desktop working, the same bytes wsysd composites"
else bad "the host owner got a descriptor with no display list in it:"\
        "$(line hostowner.pixgrab)"; fi

note ""
note "attack 4 of 6 -- SNOOP: read the victim's keystrokes and screen, O_RDONLY."
note "(THE KEYLOGGER IS CLOSED.  The snooper is UNCHANGED and still runs -- it"
note " still opens the table O_RDONLY, still maps it PROT_READ, still finds the"
note " victim's row and still scrapes its scene and its identity.  Only the"
note " keystrokes are gone from the mapping, so this is the one control that"
note " inverts and the three around it that must NOT.)"
if has sameuid.snoop "ro=1"; then
    ok "the snooper never asked for write access: O_RDONLY, PROT_READ"
else bad "the snoop did not run read-only -- the finding does not hold: $(line sameuid.snoop)"; fi
if has sameuid.snoop "found=1"; then ok "and it locates the victim's row anyway"
else bad "the snooper could not find the victim: $(line sameuid.snoop)"; fi
# THE INVERSION THAT IS THE POINT OF THIS PASS.  This assertion used to read
# "IT READS THE VICTIM'S KEYSTROKES -- a keylogger between two uid-1001 apps",
# and it passed.  The keystrokes are not in the mapping any more.
if has sameuid.snoop "PASSWORD31337"; then
    bad "INVERTED CONTROL FAILED: the victim's password is still in the mapping"
else ok "AND THE KEYSTROKES ARE NOT THERE: no password in the table (was: read)"; fi
# THE SECOND INVERSION, and it is this pass's.  This assertion used to read
# "STILL OPEN: its committed scene -- what is drawn inside that window", and it
# passed.  The display list is not in the mapping any more.  The snooper is
# UNCHANGED: it still reads scene_len and the scene bytes out of the row at the
# same offsets, which is why `scenelen=0 scene=[]` is a measurement and not an
# absence of one.
if has sameuid.snoop "rect 0 0 40 20"; then
    bad "INVERTED CONTROL FAILED: the victim's committed display list is still"\
        "in the mapping: $(line sameuid.snoop)"
else ok "AND ITS COMMITTED DISPLAY LIST IS NOT THERE either: the row's scene is"\
       "empty (was: 'rect 0 0 40 20 0x334455', what is drawn inside that window)"; fi
if has sameuid.snoop "scenelen=0"; then
    ok "and it reads the length as 0 from the same offset it always read it"
else bad "the snooper did not read the scene length, so scene=[] proves"\
        "nothing about where the bytes went: $(line sameuid.snoop)"; fi
if has sameuid.snoop "pid="; then
    ok "STILL OPEN: its wid, pid, geometry and title -- the table enumerates"
else bad "the row did not enumerate: $(line sameuid.snoop)"; fi
if grep -q "^== victim.keysgot .*PASSWORD31337" "$OUT"; then
    ok "and the victim DOES receive what was typed at it -- delivery still works"
else bad "the victim never got the keystroke: closing the leak by breaking the"\
        "keyboard is not closing it: $(grep -c '^== victim.keysgot' "$OUT") drains seen"; fi

note ""
note "attack 5 of 5 -- PEEK: the owner's PID out of the table, then its MEMORY."
note "(this attack is NEW, and it is the one that walked through attack 4's fix:"
note " the keystrokes are not in the mapping any more, but the VICTIM still has"
note " them, and /proc/<pid>/mem is readable by any same-uid process whose target"
note " is DUMPABLE -- no ptrace call, no stop, nothing to notice.  What refuses it"
note " is prctl(PR_SET_DUMPABLE, 0) in every window owner, in keychan_bind.)"
if has sameuid.peek "found=1"; then
    ok "the attacker still reads the victim's pid straight out of the 0666 table"
else bad "the peek never found the victim's row, so the chain proves nothing:"\
        "$(line sameuid.peek)"; fi
# THE FOUR THAT ARE THE POINT.  With user/linux-wsys.c reverted every one of
# them goes the other way -- mem= an fd, secret=1, enumerable=1, ptrace=0 --
# which is what makes this a measurement and not a description.
if has sameuid.peek "mem=-13"; then
    ok "and is refused the victim's memory: /proc/<pid>/mem EACCES (was: an fd)"
else bad "CONTROL FAILED: a same-uid attacker opened the window owner's"\
        "/proc/<pid>/mem: $(line sameuid.peek)"; fi
if has sameuid.peek "secret=0"; then
    ok "so the typed password is NOT scraped out of the owner's address space"
else bad "CONTROL FAILED: the victim's password was read out of its memory --"\
        "the keystroke channel is bypassed: $(line sameuid.peek)"; fi
if has sameuid.peek "enumerable=0"; then
    ok "and /proc/<pid>/fd is not listable, so its descriptors are not inventory"
else bad "CONTROL FAILED: the owner's fd table was enumerable: $(line sameuid.peek)"; fi
if has sameuid.peek "ptrace=-1"; then
    ok "and PTRACE_ATTACH is refused (here by PR_SET_DUMPABLE; on a real boot by kernel.yama.ptrace_scope=1 as well -- tests/linux/ptrace_scope_boot.sh)"
else bad "CONTROL FAILED: a same-uid attacker attached to the window owner:"\
        "$(line sameuid.peek)"; fi

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
