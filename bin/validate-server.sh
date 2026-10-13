#!/usr/bin/env bash
# Boots a throwaway dedicated server (no Steam, isolated cache dir) with only the mod enabled,
# waits for it to finish loading, stops it, and fails if the mod logged a problem: a Lua stack
# trace through the mod, or a line matching the conf's SERVER_PROBLEMS that doesn't match
# SERVER_IGNORE. The server loads the mod's tiles, scripts, sandbox options, shared and server
# Lua, and loot tables. The conf's harness_server_setup hook can add files to the server's config,
# such as its sandbox options, in "$CACHE/Server/$SERVER_NAME"*.
#
# CACHE overrides the cache dir (default: $TMPDIR/<CACHE_NAME>-server), and TIMEOUT the seconds
# the server may take to start (default 900).
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

CACHE="${CACHE:-$TMP_REAL/$CACHE_NAME-server}"
SERVER_NAME=harness
TIMEOUT=${TIMEOUT:-900}

acquire_game_lock
install_mod
mkdir -p "$CACHE/Server"
rm -f "$CACHE/Server/$SERVER_NAME"*
cat > "$CACHE/Server/$SERVER_NAME.ini" <<EOF
Mods=$MOD_ID
Map=Muldraugh, KY
UPnP=false
Public=false
EOF
if declare -F harness_server_setup > /dev/null; then
    harness_server_setup
fi
# A new world each time, so whatever the mod does for a new world runs every time.
rm -rf "$CACHE/Saves/Multiplayer/$SERVER_NAME"

LOG="$CACHE/server-console.txt"
rm -f "$LOG"
FIFO="$CACHE/stdin"
rm -f "$FIFO"
mkfifo "$FIFO"

cd "$PZ/Java"
"$JAVA" "${JVM_COMMON[@]}" -cp "$GAME_CLASSPATH" -Ddebug -Xmx4g zombie.network.GameServer \
    -cachedir="$CACHE" -servername "$SERVER_NAME" -adminpassword admin -nosteam -debuglog=Mod,Lua \
    < "$FIFO" > "$CACHE/stdout.txt" 2>&1 &
SERVER=$!
stop_game_on_exit "$SERVER"
# Opening the FIFO waits for the server's end to open too; once both are open it can go.
exec 3>"$FIFO"
rm -f "$FIFO"

started=0
for _ in $(seq "$TIMEOUT"); do
    if grep -q "SERVER STARTED" "$LOG" 2>/dev/null; then started=1; break; fi
    if ! kill -0 "$SERVER" 2>/dev/null; then break; fi
    sleep 1
done
if kill -0 "$SERVER" 2>/dev/null; then
    echo quit >&3
    for _ in $(seq 120); do kill -0 "$SERVER" 2>/dev/null || break; sleep 1; done
fi
exec 3>&-

echo "log: $LOG"
if [ "$started" != 1 ]; then
    echo "FAIL: server did not start"
    exit 1
fi
if grep -n -E "$MOD_ERROR${SERVER_PROBLEMS:+|$SERVER_PROBLEMS}" "$LOG" \
    | { if [ -n "${SERVER_IGNORE:-}" ]; then grep -v -E "$SERVER_IGNORE"; else cat; fi; }; then
    echo "FAIL: the mod logged problems"
    exit 1
fi
echo "PASS: server started and the mod logged no problems"
