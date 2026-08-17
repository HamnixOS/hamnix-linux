#!/bin/sh
# Its host runtime and its pass/fail were NOT measured when this line was
# written. If you make it cheap enough for the battery, add the manifest line
# and delete this block.
#
# tests/linux/enter_user.sh -- run INSIDE the Debian namespace by
# tests/linux/enter_user_run.sh. It answers the two questions the root switch
# exists to answer, and it answers them from where the person is standing:
# is this actually Debian, and can something inside it build a container?
say() { echo "enteruser: $*"; }

if [ -r /etc/debian_version ]; then
    say "PASS this is Debian $(cat /etc/debian_version)"
else
    say "FAIL /etc/debian_version is not here -- this is not the namespace"
fi
say "INFO uid=$(id -u) user=$(id -un 2>/dev/null) root=$(ls -d / >/dev/null 2>&1 && echo ok)"

if [ -x /usr/bin/unshare ]; then
    if /usr/bin/unshare -U /bin/true 2>/dev/null; then
        say "PASS unshare -U (CLONE_NEWUSER) from inside the namespace"
    else
        say "FAIL unshare -U: the process is still chrooted, so no container can start"
    fi
fi

if [ -x /usr/bin/bwrap ]; then
    out=$(/usr/bin/bwrap --unshare-user --bind / / /bin/true 2>&1)
    if [ $? -eq 0 ]; then
        say "PASS bwrap --unshare-user builds a container"
    else
        say "FAIL bwrap --unshare-user: $out"
    fi
fi
