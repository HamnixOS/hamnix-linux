#!/bin/bash
# Run hkslot with /boot bound to a SANDBOX directory, inside a private mount
# namespace. THE GUARD IS NOT OPTIONAL: hkslot writes to /boot by absolute
# path and this host has a real one. If the bind did not take, the sentinel is
# absent and this script exits WITHOUT running hkslot. A test that silently
# ran against the host's ESP is precisely the success-shaped disaster this
# tree keeps paying for.
set -u
SB="$1"; shift
exec unshare -r -m /bin/bash -c '
  set -u
  SB="$1"; shift
  mount --bind "$SB/boot" /boot || { echo "SANDBOX: bind failed" >&2; exit 97; }
  if [ ! -f /boot/HKSLOT_SANDBOX_SENTINEL ]; then
     echo "SANDBOX: sentinel absent after bind -- REFUSING to run hkslot" >&2
     exit 98
  fi
  exec "$@"
' _ "$SB" "$@"
