# tests/linux/_greet_auth.sh -- GET A GATE PAST THE GRAPHICAL LOGIN.
#
# Sourced, not executed. It defines two functions and nothing else; it starts
# no QEMU, opens no socket at load time and prints nothing when sourced.
#
# WHY THIS FILE EXISTS
# ====================
# Since ee1461d0 `etc/rc.d/rc.5.linux` runs `/bin/hamgreet` IN THE FOREGROUND,
# so PID 1's rc BLOCKS there. Every gate in this tree is written to the same
# idiom -- write a machine `/etc/rc.boot` that does
#
#     source '/etc/rc.boot.installed'
#     ...the gate's own questions...
#
# -- and `/etc/rc.boot.installed` ends by sourcing rc.5. So on an installed
# disk at runlevel 5, EVERYTHING THE GATE APPENDED AFTER THAT SOURCE IS DEAD
# CODE until somebody authenticates. Measured in the 1.0.33 release run: nine
# gates whose guest serial logs all end at the same two lines,
#
#     [rc.5] the graphical login is starting -- no session program exists yet
#     hamgreet: the graphical login is presenting
#
# and whose failures then all read "the machine never reached <marker>" -- a
# red about a machine that was never asked anything.
#
# THERE ARE EXACTLY TWO HONEST TREATMENTS AND THIS FILE IS THE SECOND ONE.
#
#   1. OPT OUT OF RUNLEVEL 5 -- `echo 'hamnix_runlevel = 3' > /etc/rc.runlevel`
#      before the source. etc/rc.boot.installed reads it under try/except and
#      skips rc.5, saying so on the console. This is right for a gate that only
#      ever wanted a BOOTED MACHINE to ask questions of -- no compositor, no
#      session. tests/linux/bootsync_installed.sh and tests/linux/installed_update.sh
#      use it. IT IS WRONG, AND DISHONEST, FOR ANY GATE THAT THEN ASSERTS ABOUT
#      A DESKTOP: that would be measuring a machine that cannot possibly have
#      one, which is this project's own worst shape.
#
#   2. AUTHENTICATE -- type a real account's real password at the greeter over
#      QEMU's own input devices, exactly as tests/linux/graphical_login.sh does.
#      rc.5 then RETURNS and the rest of the machine rc runs. This is the only
#      treatment available to a gate that needs a SESSION, and it is what this
#      file provides.
#
# WHAT rc.5 STARTS WHEN, BECAUSE IT DECIDES WHICH TREATMENT A GATE NEEDS.
# READ etc/rc.d/rc.5.linux, NOT THIS COMMENT, IF THEY EVER DISAGREE:
#
#     /bin/wsysd          the COMPOSITOR -- started BEFORE the greeter, so
#                         /dev/wsys EXISTS while the greeter is still asking.
#     /bin/hamgreet       foreground. Blocks here.
#     ---- authentication ----
#     /bin/hamdesktop     the backdrop, and /var/log/hamdesktop.log
#     /bin/hampanelscene  the panel
#     /etc/rc.de-user     the pre-warm that prints `uid 1001 home /home/<who>`
#
# So "needs /dev/wsys" alone does NOT mean a gate needs to authenticate -- the
# compositor is up either way at runlevel 5. What forces authentication is that
# THE GATE'S OWN APPENDED LINES DO NOT RUN AT ALL until rc.5 returns. That is
# true of every gate, whatever it asks. The opt-out is available only because a
# machine at runlevel 3 never enters the greeter in the first place.
#
# THE LIVE MEDIUM DOES NOT NEED THIS. user/hamgreet.ad detects
# /etc/installer-medium (which user/hlinstall.ad removes from the target and
# then verifies is gone) and returns immediately with a recipe naming `live`,
# without asking for a password. An installer nobody has an account on must not
# ask for one. So a gate that boots the MEDIUM has no greeter problem; only a
# gate that boots an INSTALLED DISK does.
#
# WHAT WOULD MAKE THIS RED -- because an instrument that cannot fail is worth
# nothing, and this tree has shipped one before. greet_authenticate returns
# NON-ZERO, and says which step it got to, when:
#
#   * the greeter never presents within the timeout (the machine did not reach
#     rc.5 at all, or wsysd died, or the disk is not the one you think);
#   * a screendump cannot be taken or has no parseable geometry;
#   * rc.5 never returns after the password was typed -- which is what a WRONG
#     PASSWORD looks like, and is therefore the built-in negative control:
#     call it with a password the account does not have and it MUST fail.
#     tests/linux/graphical_login.sh already measures that refusal directly
#     (78/0, the only registry gate that authenticates); this function is the
#     same keystrokes with the assertions left to the caller.
#
# It deliberately does NOT assert anything itself. A helper that scored its own
# success would put assertions the caller did not write into the caller's
# count, and `scripts/release_gates.sh` scores a gate by the assertions it
# prints. Callers assert on the return value.

# _greet_geom <qmp.sock> <workdir>
# Echoes "<w> <h>" for the guest's screen, read out of a real screendump's PPM
# header. Returns non-zero if no dump could be taken or parsed.
_greet_geom() {
    local sock="$1" work="$2" ppm="$2/_greet_geom.ppm" i=0 n prev=-1
    rm -f "$ppm"
    python3 "$_GREET_QMP_INPUT" "$sock" screendump "$ppm" >/dev/null 2>&1 || return 1
    # A screendump is written progressively; wait for the size to stop moving
    # rather than for a fixed sleep, or the header may be all there is.
    while [ "$i" -lt 40 ]; do
        sleep 0.25; i=$((i+1))
        n=$(stat -c%s "$ppm" 2>/dev/null || echo 0)
        [ "$n" -gt 0 ] && [ "$n" = "$prev" ] && break
        prev="$n"
    done
    [ -s "$ppm" ] || return 1
    # P6\n<w> <h>\n255\n -- read the second whitespace-separated token pair.
    head -c 64 "$ppm" | tr '\n' ' ' | awk '{ if ($1 != "P6") exit 1; print $2, $3 }'
}

# greet_wait_present <serial.log> <timeout-secs>
# Waits for the greeter to say it is on the screen. Returns 0 if it did.
greet_wait_present() {
    local log="$1" limit="${2:-240}" i=0
    while [ "$i" -lt "$limit" ]; do
        grep -aq 'the graphical login is presenting' "$log" 2>/dev/null && return 0
        # It is also legitimate for the machine to have gone STRAIGHT PAST the
        # greeter -- the live medium does, and so does a machine that opted out
        # of runlevel 5. Either way there is nothing here to authenticate to,
        # and reporting that as "the greeter never came up" would be a red
        # about this helper rather than about the machine.
        grep -aq 'rc\.boot: up' "$log" 2>/dev/null && return 2
        sleep 2; i=$((i+2))
    done
    return 1
}

# greet_authenticate <qmp.sock> <serial.log> <user> <pass> [present-timeout] [admit-timeout]
#
# Types <user> RET <pass> RET at the graphical greeter and waits for rc.5 to
# return, which is what lets the caller's own machine-rc lines run at last.
#
# Returns 0 admitted; 1 the greeter never presented; 2 the machine was already
# past the greeter (live medium, or runlevel 3 -- NOT an error, and the caller
# usually wants to treat it as success); 3 no screen geometry; 4 the password
# was typed and rc.5 never came back.
#
# It reports each step on stderr with a `[greet]` prefix so that a gate's log
# says which of those happened without the caller writing any of it.
greet_authenticate() {
    local sock="$1" log="$2" user="$3" pass="$4"
    local ptimeout="${5:-300}" atimeout="${6:-240}"
    local work geom w h i=0 rc

    : "${_GREET_QMP_INPUT:?_GREET_QMP_INPUT must name tests/linux/qmp_input.py}"
    work="$(dirname "$sock")"

    greet_wait_present "$log" "$ptimeout"; rc=$?
    case "$rc" in
        2) echo "[greet] the machine is already past the graphical login (live medium, or runlevel 3) -- nothing to authenticate" >&2
           return 2 ;;
        1) echo "[greet] the greeter never presented in ${ptimeout}s" >&2
           return 1 ;;
    esac
    echo "[greet] the greeter is presenting" >&2

    geom="$(_greet_geom "$sock" "$work")" || {
        echo "[greet] could not take a screendump, so the screen geometry is unknown" >&2
        return 3; }
    w="${geom% *}"; h="${geom#* }"
    [ "${w:-0}" -gt 0 ] && [ "${h:-0}" -gt 0 ] || {
        echo "[greet] the screendump's PPM header did not give a geometry ('$geom')" >&2
        return 3; }
    echo "[greet] screen is ${w}x${h}" >&2

    # Give the greeter the keyboard. Its own first scene commit raises and
    # focuses it, so this is belt and braces -- but wsysd gates keys on focus,
    # and a gate that ASSUMED focus would be measuring the assumption.
    # graphical_login.sh clicks for the same reason.
    python3 "$_GREET_QMP_INPUT" "$sock" click $((w / 2)) $((h / 2)) "$w" "$h" >/dev/null 2>&1
    sleep 2

    # THE NEGATIVE CONTROL, AND IT IS A SWITCH RATHER THAN A SEPARATE PROGRAM
    # ON PURPOSE. Every assertion a treated gate makes downstream of this
    # function rests on the claim that authenticating is what got the machine
    # moving. That claim is only worth something if the SAME code path, in the
    # SAME gate, on the SAME disk, can be made to fail. GREET_NEGCTL=1 corrupts
    # the password and nothing else -- same account, same keystrokes, same
    # waits -- so a gate run with it set MUST go red on its own greet
    # assertion, and every assertion below that one must go red with it. If a
    # gate stays green under GREET_NEGCTL=1, its greens are not about a login.
    if [ "${GREET_NEGCTL:-0}" = 1 ]; then
        pass="${pass}-NEGCTL-WRONG"
        echo "[greet] GREET_NEGCTL=1: TYPING A DELIBERATELY WRONG PASSWORD. This run is a control and its result is not a product measurement." >&2
    fi

    echo "[greet] typing the account name and password" >&2
    python3 "$_GREET_QMP_INPUT" "$sock" type "$user" >/dev/null 2>&1; sleep 1
    python3 "$_GREET_QMP_INPUT" "$sock" key ret            >/dev/null 2>&1; sleep 1
    python3 "$_GREET_QMP_INPUT" "$sock" type "$pass" >/dev/null 2>&1; sleep 1
    python3 "$_GREET_QMP_INPUT" "$sock" key ret            >/dev/null 2>&1

    # rc.5's own line, printed only on the authenticated branch. Waiting for
    # `rc.boot: up` instead would also accept the no-session branch, which is
    # exactly what a refused password produces -- so this waits for the branch
    # that means a password was ACCEPTED.
    while [ "$i" -lt "$atimeout" ]; do
        sleep 2; i=$((i+2))
        grep -aq 'authenticated -- starting the session' "$log" 2>/dev/null && {
            echo "[greet] admitted after ${i}s -- rc.5 has returned and the rest of the machine rc is running" >&2
            return 0; }
        grep -aq 'The graphical login authenticated nobody' "$log" 2>/dev/null && {
            echo "[greet] REFUSED -- rc.5 took its no-session branch, so the password was not accepted" >&2
            return 4; }
    done
    echo "[greet] rc.5 never came back in ${i}s after the password was typed" >&2
    return 4
}
