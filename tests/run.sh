#!/bin/sh
# Run the tests and compare each transcript with tests/expected/.
#
#   sh tests/run.sh            run, and show a diff for anything that changed
#   sh tests/run.sh --update   rewrite tests/expected/ from this run
#
# A changed transcript is a failure until someone has read the diff and
# decided the new behaviour is right; --update is how that decision is
# recorded. Needs luajit and busybox; LUAJIT and BUSYBOX override the commands.

cd "$(dirname "$0")/.." || exit 1
LUAJIT=${LUAJIT:-luajit}
BUSYBOX=${BUSYBOX:-busybox}
export BUSYBOX

# On Linux, put busybox's own applets (awk, sed, grep...) first on PATH, so
# the scripts run with the same tools as on the Kobo rather than, say, mawk.
if [ "$(uname)" = Linux ]; then
    rm -rf tests/.bin
    mkdir -p tests/.bin
    "$BUSYBOX" --install -s "$PWD/tests/.bin"
    PATH=$PWD/tests/.bin:$PATH
    export PATH
fi

# Carriage returns stripped: luajit on Windows writes CRLF, and the expected
# files are stored with LF.
mkdir -p tests/out
"$LUAJIT" tests/lua/scenarios.lua 2>&1 | tr -d '\r' > tests/out/lua.txt
"$BUSYBOX" sh tests/sh/scenarios.sh 2>&1 | tr -d '\r' > tests/out/sh.txt

status=0
for t in lua sh; do
    if [ "$1" = --update ]; then
        cp "tests/out/$t.txt" "tests/expected/$t.txt"
        echo "updated tests/expected/$t.txt"
    elif diff -u "tests/expected/$t.txt" "tests/out/$t.txt"; then
        echo "$t: ok"
    else
        echo "$t: FAILED -- the transcript above differs from tests/expected/$t.txt"
        status=1
    fi
done
exit $status
