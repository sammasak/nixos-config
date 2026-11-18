#!/usr/bin/env bash
# The .trash sweep of modules/workers/core.nix (trashSweep, run by the activation and the dev-environments-trash
# timer), its text run as written against a temp state dir: an entry trashed over the threshold goes, a fresh one
# stays, a live instance dir is never touched, and a .trash that is a link, a file or another mount is refused. With a
# recorder (the timer's platform-record; here a fake that keeps its argv) each run records its counts, never a name.
# ctime cannot be set, so the test swaps the 7-day threshold for 3 s and ages its entries by sleeping.
# Usage: test-trash-sweep.sh [core.nix]
set -euo pipefail

core=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/modules/workers/core.nix}
find . -maxdepth 0 -cmin -1.5 >/dev/null 2>&1 || { echo "test-trash-sweep: needs GNU find (fractional -cmin) on PATH" >&2; exit 2; }

raw=$(awk '/trashSweep = pkgs.writeShellApplication \{/ { on = 1 } on && /text = '"''"'$/ { body = 1; next }
  body && /^ *'"''"';$/ { exit } body { print }' "$core")
[[ -n $raw ]] || { echo "test-trash-sweep: no trashSweep text in $core" >&2; exit 1; }
if grep -qE "(^|[^'])\\\$\\{" <<<"$raw"; then
  echo "test-trash-sweep: the sweep interpolates Nix; give the test its value" >&2
  exit 1
fi
body=$(sed -e 's/^      //' -e "s/''\\\$/\$/g" <<<"$raw")
[[ $(grep -c -- '-cmin +10080 ' <<<"$body") == 1 ]] || { echo "test-trash-sweep: no single 7-day (-cmin +10080) threshold" >&2; exit 1; }
# an entry made before the 4 s sleep is old, one made after it is fresh
body=${body/-cmin +10080 /-cmin +0.05 }

fails=0
ok() { echo "ok   $1"; }
no() {
  echo "FAIL $1" >&2
  fails=$((fails + 1))
}
sweep() { bash -euo pipefail -c "$body" dev-env-trash-sweep "$@"; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/trash-sweep.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
rec=$tmp/recorder
records=$tmp/records
cat >"$rec" <<EOF
#!$BASH
printf '%s\n' "\$*" >>"$records"
EOF
chmod +x "$rec"

# a state dir with a live instance, and a .trash holding an old home, an old link to the live dir, and a fresh home
s=$tmp/swept
mkdir -p "$s/live/home" "$s/.trash/old-1/home"
echo work >"$s/live/home/work"
echo gone >"$s/.trash/old-1/home/work"
ln -s ../live "$s/.trash/old-link"
mkdir -p "$s/.trash/xyzzy-canary-20261101/home"
head -c 12345 /dev/zero >"$s/.trash/xyzzy-canary-20261101/home/big"
# a .trash with nothing old in it yet
z=$tmp/young
mkdir -p "$z/.trash"
# the refused shapes, aged the same way: a .trash that is a link to a live dir, a file, or another mount
l=$tmp/link
mkdir -p "$l/live/home"
echo work >"$l/live/home/work"
ln -s live "$l/.trash"
f=$tmp/file
mkdir -p "$f/live"
echo x >"$f/.trash"
m=$tmp/mount
mkdir -p "$m/.trash"
a=$tmp/absent
mkdir -p "$a/live"
e=$tmp/finderr
mkdir -p "$e/.trash/old-2/home" "$tmp/bin"
sleep 4
mkdir -p "$s/.trash/fresh-1/home" "$z/.trash/fresh-2/home"
# what the old entries hold, directories not counted: "gone\n", the link's "../live" and 12345 zeros
want_bytes=$((5 + 7 + 12345))

d="a .trash on the state dir's filesystem is swept"
rc=0 && out=$(sweep "$s" "$rec" 2>&1) || rc=$?
if [[ $rc == 0 ]]; then ok "$d"; else no "$d (rc $rc: $out)"; fi
d="the run records its counts once: every entry seen, the old ones deleted, their bytes"
got=$(cat "$records" 2>/dev/null)
if [[ $got == "trash-sweep seen=4 deleted=3 bytes=$want_bytes result=ok" ]]; then ok "$d"; else no "$d (want bytes=$want_bytes, got: $got)"; fi
d="the record names no entry and no path"
if [[ -n $got && $got != *xyzzy* && $got != *old-* && $got != *fresh* && $got != *"$tmp"* ]]; then ok "$d"; else no "$d ($got)"; fi

d="a run with nothing old still records, deleted=0"
: >"$records"
rc=0 && out=$(sweep "$z" "$rec" 2>&1) || rc=$?
got=$(cat "$records" 2>/dev/null)
if [[ $rc == 0 && $got == "trash-sweep seen=1 deleted=0 bytes=0 result=ok" && -d $z/.trash/fresh-2 ]]; then ok "$d"; else no "$d (rc $rc: $out; $got)"; fi
d="a find failing inside the size sum still records, result=failed, and the run exits non-zero"
# a find that fails only for the size sum, as an unreadable entry makes it; every other call is the real one
real_find=$(command -v find)
# shellcheck disable=SC2016 # the wrapper's own script: it expands when the wrapper runs
printf '#!/usr/bin/env bash\nfor a; do [[ $a == +%%s ]] && { echo "find: unreadable" >&2; exit 1; }; done\nexec %q "$@"\n' \
  "$real_find" >"$tmp/bin/find"
chmod +x "$tmp/bin/find"
: >"$records"
rc=0 && out=$(PATH=$tmp/bin:$PATH sweep "$e" "$rec" 2>&1) || rc=$?
got=$(cat "$records" 2>/dev/null)
if [[ $rc != 0 && $got == "trash-sweep seen=1 deleted="*" result=failed" ]]; then ok "$d"; else no "$d (rc $rc: $out; $got)"; fi

d="an entry trashed over the threshold is deleted, a link entry as itself"
if [[ ! -e $s/.trash/old-1 && ! -L $s/.trash/old-link ]]; then ok "$d"; else no "$d"; fi
d="an entry trashed under the threshold stays"
if [[ -d $s/.trash/fresh-1/home ]]; then ok "$d"; else no "$d"; fi
d="the live instance dir stays, though an old link in .trash pointed at it"
if [[ $(cat "$s/live/home/work" 2>/dev/null) == work ]]; then ok "$d"; else no "$d"; fi

d=".trash as a link to a live dir is refused, and recorded as refused with nothing counted"
: >"$records"
rc=0 && out=$(sweep "$l" "$rec" 2>&1) || rc=$?
got=$(cat "$records" 2>/dev/null)
if [[ $rc != 0 && $out == *"not swept"* && $got == "trash-sweep seen=0 deleted=0 bytes=0 result=refused" ]]; then
  ok "$d"
else
  no "$d (rc $rc: $out; $got)"
fi
d="the live dir a .trash link points at keeps its old entries"
if [[ $(cat "$l/live/home/work" 2>/dev/null) == work ]]; then ok "$d"; else no "$d"; fi

d=".trash as a file is refused"
rc=0 && out=$(sweep "$f" 2>&1) || rc=$?
if [[ $rc != 0 && -f $f/.trash ]]; then ok "$d"; else no "$d (rc $rc: $out)"; fi

d="no .trash: nothing to do, exit 0"
rc=0 && out=$(sweep "$a" 2>&1) || rc=$?
if [[ $rc == 0 && -d $a/live ]]; then ok "$d"; else no "$d (rc $rc: $out)"; fi

d=".trash on another filesystem is refused"
if unshare -rm true 2>/dev/null; then
  # shellcheck disable=SC2016 # expanded by the inner bash
  rc=0 && out=$(unshare -rm bash -c 'mount -t tmpfs none "$1/.trash" && exec bash -euo pipefail -c "$2" sweep "$1"' \
    _ "$m" "$body" 2>&1) || rc=$?
  if [[ $rc != 0 && $out == *"not swept"* ]]; then ok "$d"; else no "$d (rc $rc: $out)"; fi
else
  no "$d: no unprivileged user namespace to mount one in"
fi

((fails == 0)) || { echo "test-trash-sweep: $fails failed" >&2; exit 1; }
echo "test-trash-sweep: all passed"
