#!/usr/bin/env bash
# tests/linux/hpm_trusted_key_file.sh — CAN THE TRUST ROOT ACTUALLY BE
# ROTATED? `hpm --trusted-key=<path>` against the files this tree SHIPS.
#
# THE DEFECT THIS GATES
# =====================
# MEASURED, on this tree, before the fix (assertion 1 re-measures it on every
# run rather than trusting these numbers):
#
#   etc/hpm/trusted.pub         718 bytes, its 64-hex key token starts at 653
#   etc/hpm/local-trusted.pub  1054 bytes, its key token starts at  989
#
# `user/hpm.ad`'s `_set_trusted_key_path` read through a 512-byte buffer
# (`tkey_file_buf`, `while total < 512`). Both files are mostly the comment
# header that documents the format, so the entire read landed inside that
# header, no bare token was ever reached, and
#
#     hpm --trusted-key=etc/hpm/trusted.pub refresh
#     hpm: malformed trusted-key file (want 64 hex chars)
#
# on a perfectly well-formed file that this project ships FOR THAT PURPOSE.
#
# That is not a cosmetic failure. `--trusted-key` is the documented mechanism
# for overriding the compiled-in Ed25519 root that authenticates every package
# this distribution installs. The one reason such an override exists is that
# the root might one day have to be REPLACED — and on that day the documented
# path did not work. This is the etc/panel.conf defect (a fixed buffer smaller
# than the shipped file) with a security consequence.
#
# WHY A BIGGER BUFFER IS NOT THE FIX, and what this gate holds to it
# ------------------------------------------------------------------
# A merely-larger fixed buffer is the same defect at a larger size, and this
# tree has four scars from exactly that: a 2047-byte panel config, this
# 512-byte key buffer, an 8192-byte /etc/modules ceiling, and a `tail` that
# read the first 8 KiB. So `_set_trusted_key_path` now STREAMS — 4 KiB chunks,
# parsed one LINE at a time, no whole-file buffer and no size ceiling.
# Assertion 6 holds the fix to that claim rather than to a number: it puts the
# SAME key behind a 64 KiB comment header and demands the same acceptance. Any
# fix that is "512 -> 8192" passes assertions 3-5 and fails assertion 6.
#
# AND A KEY FILE THAT CANNOT BE USED MUST SAY SO, BY NAME
# -------------------------------------------------------
# Silently falling back to the compiled-in root is the worst outcome available
# on this path: the operator asks for key A, gets key B, and installs packages
# under a root they believe they replaced. It is the security equivalent of
# the panel quietly drawing its built-in default. Assertions 7.x hand hpm a
# key file that is unreadable / empty / comment-only / truncated / too long in
# one line / not a key, and require that hpm NAME THE FILE, exit non-zero, and
# NOT go on to refresh anything.
#
# WHAT MUST STAY TRUE, and is asserted here rather than assumed
# -------------------------------------------------------------
# * the REAL published channel still verifies with NO FLAGS (assertion 10 —
#   the actual bytes of https://255.one/linux/index{.json,.json.sig}, served
#   back from loopback, against the COMPILED-IN root, no --trusted-key and no
#   --allow-unsigned);
# * a WRONG key is still rejected (assertion 8);
# * a TAMPERED index is still rejected (assertion 9);
# * and the shipped file and the compiled-in constant are the SAME 32 bytes
#   (assertion 2) — a rotation that edits one and not the other would leave
#   the documented file describing a root the binary does not use.
#
# Host-side and loopback; no VM, no display, no GPU. Assertion 10 wants the
# network for two small files and says so loudly if it cannot have them.
# About a minute, most of it compiling hpm.
#
# Usage: tests/linux/hpm_trusted_key_file.sh
set -uo pipefail
PROJ_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$PROJ_ROOT"

# ISOLATE FIRST. This gate runs `hpm`, which writes its index cache to the
# FIXED path /tmp/hpm/index.json and its transaction log under /var — names a
# concurrent gate and this machine's own hpm share. tests/linux/private_ns.sh
# gives this run its own /tmp, /dev/shm and /srv; the call execs and does not
# return. reap.sh is sourced AFTER it, because a registry made before the
# tmpfs lands on /tmp is one this gate can no longer see.
. tests/linux/private_ns.sh
priv_ns_reexec "$@"
. tests/linux/reap.sh

# Build artefacts stay OUT of the project tree (build/ is symlinked to the one
# shared tree on this host and another agent may be booting from it).
WORK="${TKEY_WORK:-/home/david/.hamnix-build/tkeygate}"
mkdir -p "$WORK"
KEEP="${TKEY_KEEP:-0}"
OUT="$WORK/hpm.elf"
PORT="${TKEY_PORT:-18841}"
SRVPID=""
BASE="http://127.0.0.1:$PORT/"

pass=0; fail=0
ok()   { echo "tkey: PASS $*"; pass=$((pass+1)); }
bad()  { echo "tkey: FAIL $*"; fail=$((fail+1)); }
info() { echo "tkey: INFO $*"; }

reap_track "$WORK/reaped"
stop_server() {
    if [ -n "$SRVPID" ] && kill -0 "$SRVPID" 2>/dev/null; then
        kill "$SRVPID" 2>/dev/null; wait "$SRVPID" 2>/dev/null
    fi
    SRVPID=""
}
cleanup() {
    stop_server
    [ "$KEEP" = 1 ] || rm -rf "$WORK/repo" "$WORK/keys" "$WORK/root"
}
reap_on_exit cleanup
done_report() { echo "tkey: $pass passed, $fail failed"; [ "$fail" = 0 ]; }

SHIPPED="$PROJ_ROOT/etc/hpm/trusted.pub"
SHIPPED_LOCAL="$PROJ_ROOT/etc/hpm/local-trusted.pub"
LOCAL_SEED="$PROJ_ROOT/scripts/hpm_local_key.seed"

# keytok <pubfile> -> "<size> <byte offset of the first bare token> <token>"
# The same rule hpm and scripts/hpm_sign.py parse by: skip blank lines and
# lines whose first non-blank character is '#'; the first bare token is the
# key. Measured in BYTES from the start of the file, because the number that
# mattered was an offset against a buffer size.
keytok() {
    python3 - "$1" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
off = 0
for line in d.splitlines(keepends=True):
    s = line.strip()
    if s and not s.startswith(b'#'):
        lead = len(line) - len(line.lstrip())
        print(len(d), off + lead, s.split()[0].decode())
        break
    off += len(line)
else:
    print(len(d), -1, '')
PY
}

# ---- 1. THE SHIPPED FILES ARE THE HARD CASE, measured not assumed ---------
# If somebody shortens either header this gate stops being about anything, so
# it says out loud what it stands on. 512 is the buffer that used to be there;
# the point is that the key is PAST it.
OLDCAP=512
for f in "$SHIPPED" "$SHIPPED_LOCAL"; do
    read -r SZ OFF TOK <<<"$(keytok "$f")"
    rel="${f#$PROJ_ROOT/}"
    if [ "${OFF:--1}" -gt "$OLDCAP" ]; then
        ok "$rel is $SZ bytes and its key token begins at byte $OFF -- past the ${OLDCAP}-byte read that used to swallow this file whole"
    else
        bad "$rel's key token is at byte ${OFF:-?} of ${SZ:-?} -- it now fits inside the old ${OLDCAP}-byte buffer, so this gate no longer reproduces the defect it exists for"
    fi
    [ "${#TOK}" = 64 ] || bad "$rel's first bare token is ${#TOK} characters, not 64 -- it is not an Ed25519 public key"
done
TRUSTED_HEX="$(keytok "$SHIPPED"       | awk '{print $3}')"
LOCAL_HEX="$(  keytok "$SHIPPED_LOCAL" | awk '{print $3}')"
TRUSTED_OFF="$(keytok "$SHIPPED"       | awk '{print $2}')"
LOCAL_OFF="$(  keytok "$SHIPPED_LOCAL" | awk '{print $2}')"

# ---- 2. THE FILE AND THE BINARY ARE THE SAME 32 BYTES --------------------
# `_load_default_trusted_pub` compiles the root in as a literal so it cannot
# be swapped by editing a file. That is deliberate, and it means the shipped
# file is a DESCRIPTION of the binary's root -- a rotation that updates one
# and not the other leaves /etc/hpm/trusted.pub documenting a key hpm does
# not use, and nothing would say so.
BUILTIN="$(grep -A3 'def _load_default_trusted_pub' user/hpm.ad \
           | grep -oE '"[0-9a-f]{64}"' | tr -d '"' | head -1)"
BUILTIN_LOCAL="$(grep -A3 'def _load_local_trusted_pub' user/hpm.ad \
           | grep -oE '"[0-9a-f]{64}"' | tr -d '"' | head -1)"
if [ -n "$BUILTIN" ] && [ "$BUILTIN" = "$TRUSTED_HEX" ]; then
    ok "the compiled-in production root and etc/hpm/trusted.pub are the same 32 bytes (${TRUSTED_HEX:0:16}...)"
else
    bad "the compiled-in production root ($BUILTIN) is NOT etc/hpm/trusted.pub's key ($TRUSTED_HEX) -- the shipped file documents a root the binary does not use"
fi
if [ -n "$BUILTIN_LOCAL" ] && [ "$BUILTIN_LOCAL" = "$LOCAL_HEX" ]; then
    ok "the compiled-in LOCAL root and etc/hpm/local-trusted.pub are the same 32 bytes (${LOCAL_HEX:0:16}...)"
else
    bad "the compiled-in local root ($BUILTIN_LOCAL) is NOT etc/hpm/local-trusted.pub's key ($LOCAL_HEX)"
fi

# ---- the repo, the keys, the server --------------------------------------
python3 -c 'import sys; sys.path.insert(0, "scripts"); import hpm_sign' 2>/dev/null || {
    bad "scripts/hpm_sign.py will not import -- nothing below can be signed"
    done_report; exit 1; }

KEYS="$WORK/keys"; rm -rf "$KEYS"; mkdir -p "$KEYS"
REPO="$WORK/repo"; rm -rf "$REPO"; mkdir -p "$REPO/main/packages"
python3 scripts/hpm_sign.py keygen --out-pub "$KEYS/k1.pub" --out-sec "$KEYS/k1.sec" >/dev/null
python3 scripts/hpm_sign.py keygen --out-pub "$KEYS/k2.pub" --out-sec "$KEYS/k2.sec" >/dev/null
K1="$(awk '!/^#/ && NF {print $1; exit}' "$KEYS/k1.pub")"
K2="$(awk '!/^#/ && NF {print $1; exit}' "$KEYS/k2.pub")"
[ -n "$K1" ] && [ -n "$K2" ] && [ "$K1" != "$K2" ] || {
    bad "could not mint two distinct throwaway keys"; done_report; exit 1; }

# A REAL package, so `install` has something to fetch, verify and unpack --
# a signature check that passes and is then ignored would satisfy a refresh
# assertion on its own.
PKGSRC="$WORK/pkgsrc/tkey-hello-1.0"
rm -rf "$WORK/pkgsrc"; mkdir -p "$PKGSRC/files/var/lib"
cat > "$PKGSRC/PKGINFO" <<'EOF'
name: tkey-hello
version: 1.0
arch: any
description: trusted-key gate fixture
target: #hamnix-system
EOF
printf 'the key was honoured\n' > "$PKGSRC/files/var/lib/tkey-hello-greet"
tar czf "$REPO/main/packages/tkey-hello-1.0.tar.gz" -C "$WORK/pkgsrc" tkey-hello-1.0
PKG_SHA="$(sha256sum "$REPO/main/packages/tkey-hello-1.0.tar.gz" | awk '{print $1}')"
PKG_SIZE="$(stat -c%s "$REPO/main/packages/tkey-hello-1.0.tar.gz")"
cat > "$REPO/main/index.json" <<EOF
{"schema":1,"repo":"tkey-gate","channel":"main","url":"$BASE","updated":"2026-08-12","packages":[{"name":"tkey-hello","version":"1.0","arch":"any","channel":"main","url":"packages/tkey-hello-1.0.tar.gz","sha256":"$PKG_SHA","size":$PKG_SIZE,"description":"trusted-key gate fixture","depends":[],"target":"#hamnix-system"}]}
EOF
cp "$REPO/main/index.json" "$WORK/index.pristine.json"
sign_with() {   # sign_with <secret-hex-file>
    python3 scripts/hpm_sign.py sign "$REPO/main/index.json" "$1" \
            "$REPO/main/index.json.sig" >/dev/null
}
sign_with "$KEYS/k1.sec" || { bad "cannot sign the fixture index"; done_report; exit 1; }

# The server. Its response headers are padded to a CDN's size for the reason
# tests/linux/hpm_index_sig.sh gives: python's http.server emits 203 bytes of
# headers and cannot reproduce a bug whose cause is a 640-byte header block.
cat > "$WORK/cdn.py" <<'PYSRV'
import os, sys, http.server
ROOT = sys.argv[1]; PORT = int(sys.argv[2]); PAD = int(sys.argv[3])
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a): pass
    def _pad(self):
        n, i = PAD, 0
        while n > 0:
            chunk = min(n, 200)
            name = "x-hamnix-pad-%d" % i
            body = "z" * max(1, chunk - len(name) - 4)
            self.send_header(name, body)
            n -= len(name) + len(body) + 4
            i += 1
    def do_GET(self):
        path = os.path.normpath(self.path.split("?")[0]).lstrip("/")
        full = os.path.join(ROOT, path)
        if not os.path.isfile(full):
            data = ("<!doctype html><title>404</title>" + "x" * 9300).encode()
            self.send_response(404); self._pad()
            self.send_header("content-length", str(len(data)))
            self.end_headers(); self.wfile.write(data); return
        data = open(full, "rb").read()
        self.send_response(200); self._pad()
        self.send_header("content-length", str(len(data)))
        self.end_headers(); self.wfile.write(data)
http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
PYSRV

start_server() {
    stop_server
    python3 "$WORK/cdn.py" "$REPO" "$PORT" 640 >"$WORK/server.log" 2>&1 &
    SRVPID=$!; reap_add "$SRVPID"
    for _ in $(seq 1 60); do
        curl -s -o /dev/null "$BASE/main/index.json" && return 0
        sleep 0.1
    done
    bad "the loopback repo server did not come up on $PORT"; return 1
}

# ---- build ---------------------------------------------------------------
info "building user/hpm.ad -> $OUT"
nice -n 15 scripts/hamlinux_build.sh user/hpm.ad "$OUT" >"$WORK/build.log" 2>&1 || {
    bad "could not build user/hpm.ad"; tail -20 "$WORK/build.log" >&2
    done_report; exit 1; }

# run_hpm <flags...> — output in $LAST, rc in $LASTRC. hpm parses its flags
# BEFORE the command word, so extras go in front of `refresh`, not after it.
run_hpm() {
    LAST="$("$OUT" --repo="$BASE" "$@" 2>&1)"; LASTRC=$?
}
has()  { case "$LAST" in *"$1"*) return 0;; *) return 1;; esac; }
dump() { printf '%s\n' "$LAST" | sed 's/^/tkey:      | /'; }

start_server || { done_report; exit 1; }

# A key file shaped like the SHIPPED one: its comment header VERBATIM, with a
# key we hold the secret for in place of the key we do not. This is the whole
# 653-byte header, so it is the same reading problem the shipped file poses,
# and unlike the shipped file it can be proved end to end.
hdr_keyfile() {   # hdr_keyfile <shipped-file> <hex> <out>
    python3 - "$1" "$2" "$3" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
head = b''
for line in d.splitlines(keepends=True):
    s = line.strip()
    if s and not s.startswith(b'#'):
        break
    head += line
open(sys.argv[3], 'wb').write(head + sys.argv[2].encode() + b'\n')
PY
}
hdr_keyfile "$SHIPPED"       "$K1" "$WORK/hdr-prod.pub"
hdr_keyfile "$SHIPPED_LOCAL" "$K1" "$WORK/hdr-local.pub"

# ---- 3. THE SHIPPED FILE IS ACCEPTED -------------------------------------
# Verbatim, header and all. The index here is signed by K1, not by the root
# this file names, so the REFRESH must fail -- but it must fail as an INVALID
# SIGNATURE, which is only reachable if the 32 bytes were read out of the
# file and used. "malformed key file" is the defect; "signature INVALID" is
# the file being honoured against a repo it does not vouch for.
run_hpm --trusted-key="$SHIPPED" refresh
if has "trust root taken from $SHIPPED" && ! has "malformed" && ! has "no key in it"; then
    ok "etc/hpm/trusted.pub is READ VERBATIM (718 bytes, key at byte $TRUSTED_OFF): $(printf '%s' "$LAST" | grep -a 'trust root taken from' | head -1)"
else
    bad "THE DEFECT: hpm could not read the trust root out of the file this project ships for that purpose"
    dump
fi
if has "signature INVALID" && ! has "refreshed index"; then
    ok "and the key it read is USED: an index NOT signed by that root is refused as an invalid signature, not waved through"
else
    bad "etc/hpm/trusted.pub loaded but the index it does not vouch for was not refused (rc=$LASTRC)"
    dump
fi
run_hpm --trusted-key="$SHIPPED_LOCAL" refresh
if has "trust root taken from $SHIPPED_LOCAL" && has "signature INVALID"; then
    ok "etc/hpm/local-trusted.pub is READ VERBATIM too (1054 bytes, key at byte $LOCAL_OFF) and used"
else
    bad "etc/hpm/local-trusted.pub was not read and used"
    dump
fi

# ---- 4. THE POSITIVE, END TO END, THROUGH THE SHIPPED HEADER -------------
# The shipped file's own 653-byte comment header, carrying a key we hold the
# secret for, signing this index: refresh AND install must both succeed, and
# the installed file must be on disk with the bytes the package carried.
ROOTFS="$WORK/root"; rm -rf "$ROOTFS"; mkdir -p "$ROOTFS"
run_hpm --trusted-key="$WORK/hdr-prod.pub" refresh
if has "refreshed index" && ! has "INVALID" && ! has "unsigned" && [ "$LASTRC" = 0 ]; then
    ok "a key behind etc/hpm/trusted.pub's OWN 653-byte header verifies the index and refreshes with no other flag"
else
    bad "a key behind the shipped 653-byte header did not verify (rc=$LASTRC)"
    dump
fi
run_hpm --trusted-key="$WORK/hdr-local.pub" refresh
if has "refreshed index" && [ "$LASTRC" = 0 ]; then
    ok "and the same behind etc/hpm/local-trusted.pub's 989-byte header"
else
    bad "a key behind the shipped 989-byte header did not verify (rc=$LASTRC)"
    dump
fi
run_hpm --trusted-key="$WORK/hdr-prod.pub" --target-prefix="$ROOTFS" install tkey-hello
GREET="$ROOTFS/var/lib/tkey-hello-greet"
if [ "$LASTRC" = 0 ] && [ -r "$GREET" ] && grep -q 'the key was honoured' "$GREET"; then
    ok "and a PACKAGE signed under that key installs end to end -- $GREET carries the bytes the tarball did"
else
    bad "install under the header-carrying key did not put the package on disk (rc=$LASTRC, file $( [ -r "$GREET" ] && echo present || echo absent))"
    dump
fi

# ---- 5. THE SHIPPED FILE'S OWN SECRET, for the one root whose secret is
#         in the tree ------------------------------------------------------
# etc/hpm/local-trusted.pub's secret IS committed (scripts/hpm_local_key.seed)
# because that boundary is trusted-by-construction. So this one can be proved
# without any substitution at all: the SHIPPED FILE, byte for byte, against an
# index signed by the SHIPPED SECRET.
if [ -r "$LOCAL_SEED" ]; then
    cp "$WORK/index.pristine.json" "$REPO/main/index.json"
    sign_with "$LOCAL_SEED"
    run_hpm --trusted-key="$SHIPPED_LOCAL" refresh
    if has "refreshed index" && ! has "INVALID" && [ "$LASTRC" = 0 ]; then
        ok "THE SHIPPED FILE, UNMODIFIED, AUTHENTICATES A REAL INDEX: etc/hpm/local-trusted.pub (1054 bytes verbatim) verifies an index signed with scripts/hpm_local_key.seed"
    else
        bad "the shipped local trust root did not verify an index signed by the committed local secret (rc=$LASTRC)"
        dump
    fi
    # ... and the OTHER shipped file, which does not vouch for it, still says no.
    run_hpm --trusted-key="$SHIPPED" refresh
    if has "signature INVALID" && ! has "refreshed index"; then
        ok "and etc/hpm/trusted.pub refuses that same index -- the two shipped roots are distinguishable, so the assertion above means something"
    else
        bad "etc/hpm/trusted.pub accepted an index signed by the LOCAL key -- the two roots are not being told apart"
        dump
    fi
    cp "$WORK/index.pristine.json" "$REPO/main/index.json"
    sign_with "$KEYS/k1.sec"
else
    bad "scripts/hpm_local_key.seed is gone -- the only shipped trust root whose secret is in the tree can no longer be proved end to end"
fi

# ---- 6. NO CEILING, not a bigger one -------------------------------------
# The same key behind 64 KiB of comments. A fix that moved the buffer from
# 512 to 8192 (or to 65536) passes everything above and fails this.
python3 - "$K1" "$WORK/huge.pub" <<'PY'
import sys
pad = ''.join('# padding line %d, and the key is still below all of it\n' % i
              for i in range(1200))
open(sys.argv[2], 'w').write(pad + sys.argv[1] + '\n')
PY
HUGESZ="$(wc -c <"$WORK/huge.pub")"
HUGEOFF="$(keytok "$WORK/huge.pub" | awk '{print $2}')"
run_hpm --trusted-key="$WORK/huge.pub" refresh
if has "refreshed index" && [ "$LASTRC" = 0 ]; then
    ok "the SAME key behind a ${HUGESZ}-byte comment header (token at byte $HUGEOFF) still verifies -- the reader has no size ceiling, so this is not a bigger fixed buffer wearing the fix's hat"
else
    bad "a ${HUGESZ}-byte key file failed (rc=$LASTRC) -- the ceiling was RAISED, not removed, and the next key file to cross it will fail exactly as silently as the shipped one did"
    dump
fi

# ---- 7. EVERY UNUSABLE KEY FILE IS REFUSED **BY NAME** -------------------
# Each of these must: exit non-zero, name THE FILE in the message, and NOT
# refresh. The last clause is the security one -- falling back to the built-in
# root would let a refresh succeed under a key the operator did not ask for,
# and it would look exactly like success.
BADD="$WORK/bad"; rm -rf "$BADD"; mkdir -p "$BADD"
: >                                        "$BADD/empty.pub"
printf '# a header and nothing else\n' >   "$BADD/commentonly.pub"
head -c 400 "$SHIPPED" >                   "$BADD/truncated.pub"
printf 'deadbeef\n' >                      "$BADD/shorttoken.pub"
printf 'zz%s\n' "${K1:2}" >                "$BADD/nothex.pub"
{ printf '# one absurd line\n'; python3 -c "print('a' * 900)"; } > "$BADD/longline.pub"
printf '%s' "$K1" >                        "$BADD/nonewline.pub"   # legal: last line, no \n

check_refused() {   # check_refused <file> <what it is>
    run_hpm --trusted-key="$1" refresh
    local named=1 quiet=1 zero=1
    has "$1"                || named=0
    has "refreshed index"   && quiet=0
    [ "$LASTRC" != 0 ]      || zero=0
    if [ "$named$quiet$zero" = 111 ]; then
        ok "$2 is REFUSED BY NAME (rc=$LASTRC): $(printf '%s' "$LAST" | grep -a -- '--trusted-key' | head -1)"
    else
        bad "$2 was not refused by name (names the file: $named, refreshed nothing: $quiet, non-zero rc: $zero, rc=$LASTRC)"
        dump
    fi
}
check_refused "$BADD/nosuchfile.pub" "a key file that does not exist"
check_refused "$BADD/empty.pub"      "an EMPTY key file"
check_refused "$BADD/commentonly.pub" "a key file that is all comment"
check_refused "$BADD/truncated.pub"  "etc/hpm/trusted.pub TRUNCATED to its first 400 bytes"
check_refused "$BADD/shorttoken.pub" "a token that is 8 hex characters, not 64"
check_refused "$BADD/nothex.pub"     "a 64-character token that is not hex"
check_refused "$BADD/longline.pub"   "a key file with a 900-character line"
# The long-line case has a second half: it must SAY the line was too long,
# not merely that it found no key. Otherwise "your file is wrong" is the
# answer to "your file is right and my limit is small".
run_hpm --trusted-key="$BADD/longline.pub" refresh
if has "longer than the 512-byte line limit"; then
    ok "and the over-long line is reported AS SUCH, not merely as a missing key: $(printf '%s' "$LAST" | grep -a 'line limit' | head -1)"
else
    bad "a 900-character line was cut and the message did not say the line limit was the reason"
    dump
fi
# ... and a key on the LAST line with no trailing newline is a legal file.
run_hpm --trusted-key="$BADD/nonewline.pub" refresh
if has "refreshed index" && [ "$LASTRC" = 0 ]; then
    ok "a key file whose last line has NO trailing newline is accepted -- the streaming reader does not lose the final line"
else
    bad "a key file with no trailing newline was rejected (rc=$LASTRC) -- the chunked reader drops its last line"
    dump
fi

# ---- 8. A WRONG KEY IS STILL REFUSED ------------------------------------
run_hpm --trusted-key="$KEYS/k2.pub" refresh
if has "signature INVALID" && ! has "refreshed index" && [ "$LASTRC" != 0 ]; then
    ok "a DIFFERENT (well-formed) key refuses this index as an invalid signature"
else
    bad "an index signed by K1 was accepted under K2 (rc=$LASTRC)"
    dump
fi
rm -rf "$WORK/root2"; mkdir -p "$WORK/root2"
# WHAT THIS ASSERTION HAD TO LEARN. `install` does not re-verify the index
# signature: it reads the cache /tmp/hpm/index-<uid>.json that the last GOOD
# `refresh` wrote, and checks each tarball's sha256 against it. That is apt's
# model and it is fine -- but it means an install run right after a successful
# refresh succeeds no matter what --trusted-key says, because the index it is
# working from was already authenticated. Asserting otherwise would be
# asserting against the design. So the cache is cleared first, and the
# question asked is the real one: with NOTHING already trusted, can a package
# signed by a key the operator does not trust get onto the disk?
rm -rf /tmp/hpm
run_hpm --trusted-key="$KEYS/k2.pub" --target-prefix="$WORK/root2" install tkey-hello
if [ "$LASTRC" != 0 ] && [ ! -r "$WORK/root2/var/lib/tkey-hello-greet" ]; then
    ok "and with no already-authenticated index in the cache, a package signed by a key the operator does not trust does NOT install (rc=$LASTRC, nothing on disk)"
else
    bad "a package under an untrusted key INSTALLED from a cold cache (rc=$LASTRC)"
    dump
fi
# Said out loud, so this gate's green is not read as a claim `install`
# re-checks the signature. It does not; `refresh` is where the trust decision
# is made, and the cache is per-user (/tmp/hpm/index-<uid>.json) rather than
# a shared world-writable one, which is what makes that safe.
run_hpm --trusted-key="$WORK/hdr-prod.pub" refresh >/dev/null 2>&1
run_hpm --trusted-key="$KEYS/k2.pub" --target-prefix="$WORK/root2" install tkey-hello
if [ "$LASTRC" = 0 ]; then
    info "for the record: after a GOOD refresh, install under a different --trusted-key succeeds from the per-user cache -- \`refresh\` is the trust decision, \`install\` verifies sha256 against the index it already authenticated (apt's model)"
else
    info "for the record: install re-checks the trust root as well as the cache (rc=$LASTRC)"
fi

# ---- 9. A TAMPERED INDEX IS STILL REFUSED -------------------------------
cp "$REPO/main/index.json" "$WORK/index.keep.json"
python3 - "$REPO/main/index.json" <<'PY'
import sys, pathlib, re
p = pathlib.Path(sys.argv[1]); t = p.read_text()
h = re.search(r'"sha256":"([0-9a-f]{64})"', t).group(1)
p.write_text(t.replace(h, ('0' if h[0] != '0' else '1') + h[1:], 1))
PY
run_hpm --trusted-key="$WORK/hdr-prod.pub" refresh
if has "signature INVALID" && ! has "refreshed index"; then
    ok "an index tampered with after signing is still refused, under a key read out of a header-carrying file"
else
    bad "a tampered index was not refused (rc=$LASTRC)"
    dump
fi
mv "$WORK/index.keep.json" "$REPO/main/index.json"

# ---- 10. THE REAL PUBLISHED CHANNEL, NO FLAGS AT ALL --------------------
# The actual bytes of https://255.one/linux/index.json and its published
# signature, served back from loopback and verified against the COMPILED-IN
# root: no --trusted-key, no --allow-unsigned. This is the thing that must
# not have been broken by any of the above. Nothing is published or written
# to 255.one -- two GETs, that is all.
LIVE="$WORK/live"; mkdir -p "$LIVE"
if curl -fsS --max-time 45 -o "$LIVE/index.json"     https://255.one/linux/index.json \
   && curl -fsS --max-time 45 -o "$LIVE/index.json.sig" https://255.one/linux/index.json.sig
then
    # `verify` takes index, sig, pub -- in that order -- and prints OK/BAD.
    if python3 scripts/hpm_sign.py verify \
            "$LIVE/index.json" "$LIVE/index.json.sig" "$SHIPPED" >/dev/null; then
        ok "the LIVE published https://255.one/linux/index.json verifies against etc/hpm/trusted.pub ($(wc -c <"$LIVE/index.json") bytes of index, $(wc -c <"$LIVE/index.json.sig") of signature)"
    else
        bad "the live published index does NOT verify against the shipped trust root"
    fi
    stop_server
    LREPO="$WORK/liverepo"; rm -rf "$LREPO"; mkdir -p "$LREPO/main"
    cp "$LIVE/index.json" "$LIVE/index.json.sig" "$LREPO/main/"
    python3 "$WORK/cdn.py" "$LREPO" "$PORT" 640 >"$WORK/server2.log" 2>&1 &
    SRVPID=$!; reap_add "$SRVPID"
    for _ in $(seq 1 60); do curl -s -o /dev/null "$BASE/main/index.json" && break; sleep 0.1; done
    run_hpm refresh          # NO --trusted-key, NO --allow-unsigned
    if has "refreshed index" && ! has "unsigned" && ! has "INVALID" && [ "$LASTRC" = 0 ]; then
        ok "AND THE COMPILED-IN ROOT STILL VERIFIES IT WITH NO FLAGS: the real published index refreshes clean"
    else
        bad "the real published index no longer verifies under the compiled-in root with no flags (rc=$LASTRC)"
        dump
    fi
    # ... and one flipped byte of the REAL index is still caught.
    python3 - "$LREPO/main/index.json" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1]); b = bytearray(p.read_bytes())
b[len(b) // 2] ^= 0x01
p.write_bytes(bytes(b))
PY
    run_hpm refresh
    if has "INVALID" && ! has "refreshed index"; then
        ok "and one flipped byte of that real index is caught with no flags"
    else
        bad "a flipped byte of the real published index was not caught (rc=$LASTRC)"
        dump
    fi
else
    bad "could not GET https://255.one/linux/index{.json,.json.sig} -- the no-flags acceptance assertion did NOT run, and this gate is green about less than it claims"
fi

info "the reader's own account of itself, from the last successful load:"
run_hpm --trusted-key="$WORK/huge.pub" refresh
printf '%s' "$LAST" | grep -a 'trust root taken from' | sed 's/^/tkey:      /'
done_report
