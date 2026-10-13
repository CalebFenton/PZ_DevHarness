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
TIMEOUT=${TIMEOUT:-900}
# For the conf's hooks: this server serves no --mp run.
MP=

acquire_game_lock
prepare_server "$MOD_ID"
start_server
stop_games_on_exit

started=
SECONDS=0
while [ "$SECONDS" -lt "$TIMEOUT" ] && kill -0 "$SERVER_PID" 2>/dev/null; do
    if server_started; then
        started=1
        break
    fi
    sleep 1
done
stop_server

echo "log: $SERVER_LOG"
if [ -z "$started" ]; then
    echo "FAIL: server did not start"
    exit 1
fi
if server_problems "$SERVER_LOG"; then
    echo "FAIL: the mod logged problems"
    exit 1
fi
echo "PASS: server started and the mod logged no problems"
