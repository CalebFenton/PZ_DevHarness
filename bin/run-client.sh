#!/usr/bin/env bash
# Starts the game client in debug mode (no Steam) with its own cache dir, the mod, its dev mod and
# the harness mod enabled. A mod's dev/run-debug-client.sh runs this; README.md describes the
# modes, the environment variables and dev/harness.conf.
#
#   (no flag)        play by hand: the main menu, with the mod's debug scenario under Scenarios
#                    and its tests in the debug menu's timed action tests
#   --test           starts the scenario, runs the mod's tests and quits. Runs unattended:
#                    java/ClickToStart.java presses "Click to start", and the display is kept
#                    awake. Prints the results and exits 1 if a test failed or any Lua error was
#                    logged.
#   --test --stay    the same, but the game stays open after the run, and the next --test --stay
#                    reruns the tests in it after loading the conf's RELOAD_FILES again. Any other
#                    change to the mods restarts the game. While it waits it shows and logs
#                    "<TAG> IDLE"; it quits after 10 minutes without a run, or when another run
#                    needs the game.
#   --<mode>         one of the conf's MODES: starts the scenario and runs the mod's handler for it
#                    instead of the tests
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

CACHE="${CACHE:-$TMP_REAL/$CACHE_NAME-client}"
usage() {
    local modes=
    for mode in ${MODES:-}; do
        modes="$modes | --$mode"
    done
    echo "usage: $0 [--test [--stay]$modes]" >&2
    exit 2
}
MODE= STAY=
for arg in "$@"; do
    case "$arg" in
        --test) MODE=test ;;
        --stay) STAY=1 ;;
        --*)
            case " ${MODES:-} " in
                *" ${arg#--} "*) MODE=${arg#--} ;;
                *) usage ;;
            esac
            ;;
        *) usage ;;
    esac
done
if [ -n "$STAY" ] && [ "$MODE" != test ]; then
    usage
fi
# What the run does, comma-separated: TESTS name prefixes for --test, else the variable the conf
# names in MODE_SELECTION_<mode>.
SELECTION=
MARK=$TAG
if [ "$MODE" = test ]; then
    SELECTION=${TESTS:-}
elif [ -n "$MODE" ]; then
    selection_var="MODE_SELECTION_$MODE"
    if [ -n "${!selection_var:-}" ]; then
        selection_name=${!selection_var}
        SELECTION=${!selection_name:-}
    fi
    mark_var="MODE_MARK_$MODE"
    MARK=${!mark_var:-$TAG}
fi
# A selection the mod refuses fails here rather than after the game has started.
if [ -n "$MODE" ] && declare -F "harness_check_$MODE" > /dev/null; then
    "harness_check_$MODE"
fi
TIMEOUT=${TIMEOUT:-1200}
LOG="$CACHE/console.txt"
# The harness Lua reads the run from the first file and, with --stay, rerun requests from the
# second (PZHarness/Runner.lua).
HARNESS_FILE="$CACHE/Lua/PZHarness.txt"
REQUEST_FILE="$CACHE/Lua/PZHarnessRerun.txt"

# Whether $1, relative to the dev mod, is one of the files a rerun loads again.
reloaded() {
    local pattern
    for pattern in "${RELOAD_FILES[@]}"; do
        # shellcheck disable=SC2053 # the pattern is a glob
        [[ $1 == $pattern ]] && return 0
    done
    return 1
}

# Why a kept game can't rerun the tests: it belongs to another cache dir, or something it loaded
# only at start changed since. Prints nothing if it can.
session_stale() {
    if [ "$SESSION_CACHE" != "$CACHE" ]; then
        echo "it runs with the cache dir $SESSION_CACHE"
        return
    fi
    local file
    while read -r file; do
        if [[ $file != "$DEV_MOD_DIR/"* ]] || ! reloaded "${file#"$DEV_MOD_DIR/"}"; then
            echo "${file#"$REPO/"} changed"
            return
        fi
    done < <(find "$DEV_MOD_DIR" "$HARNESS_MOD_DIR" -newer "$HARNESS_FILE" -type f)
    # "Files <ours> and <copy> differ" or "Only in <folder>: <name>", for every changed file.
    local changed
    changed=$(diff -rq "$MOD_DIR" "$CACHE/mods/$MOD_FOLDER" | head -1 || true)
    if [ -n "$changed" ]; then
        echo "the mod changed: $changed"
    fi
}

acquire_game_lock reuse
if [ -n "$SESSION_PID" ]; then
    reason=
    if [ -z "$STAY" ]; then
        reason="this run doesn't use --stay"
    else
        reason=$(session_stale)
    fi
    if [ -n "$reason" ]; then
        echo "stopping the game kept open by --stay: $reason"
        stop_session
    fi
fi

# Sends a kept game the tests to run and the files to load again, in the conf's order. The id
# names the run in console.txt.
request_rerun() {
    RUN_ID="$$-$(date +%s)"
    local pattern file
    {
        echo "$RUN_ID"
        echo "${TESTS:-}"
        for pattern in "${RELOAD_FILES[@]}"; do
            for file in "$CACHE/mods/$DEV_MOD_FOLDER/"$pattern; do
                [ -f "$file" ] && echo "$file"
            done
        done
    } > "$REQUEST_FILE.tmp"
    mv "$REQUEST_FILE.tmp" "$REQUEST_FILE" # whole, so the game never reads half a request
}

# Reuse your game settings (resolution, language, accepted terms of service) so a fresh cache
# dir doesn't stop at first-run screens.
prepare_cache() {
    if [ ! -f "$CACHE/options.ini" ] && [ -f "$HOME/Zomboid/options.ini" ]; then
        cp "$HOME/Zomboid/options.ini" "$CACHE/options.ini"
    fi
    # Harness runs play no sound, so they don't blare while you work. Only the volumes are zeroed:
    # the sound engine still runs, so code that plays sounds runs the same. A plain run keeps your
    # volumes.
    if [ -n "$MODE" ] && [ -f "$CACHE/options.ini" ]; then
        for key in soundVolume musicVolume ambientVolume vehicleEngineVolume jumpScareVolume voiceVolumePlayers; do
            sed -i '' "s/^$key=.*/$key=0/" "$CACHE/options.ini"
        done
    fi
    # Without this file the client empties mods/default.txt on start, as it does the first time a
    # cache dir runs a new major release (ZomboidFileSystem.resetDefaultModsForNewRelease).
    echo "If this file does not exist, default.txt will be reset to empty (no mods active)." > "$CACHE/mods/reset-mods-42_00.txt"
    # The dev mod and the harness load in every mode, so playing by hand has the scenario and the
    # tests too. Symlinks are enough for them: they have no tiles.
    ln -sfn "$HARNESS_MOD_DIR" "$CACHE/mods/$HARNESS_MOD_FOLDER"
    ln -sfn "$DEV_MOD_DIR" "$CACHE/mods/$DEV_MOD_FOLDER"
    mkdir -p "$CACHE/Lua"
    rm -f "$REQUEST_FILE"
    # Written when playing by hand too: the tests take their console tag from it.
    printf 'mode=%s\nselection=%s\nstay=%s\nmark=%s\ntag=%s\n' "$MODE" "$SELECTION" "$STAY" "$MARK" "$TAG" > "$HARNESS_FILE"
    cat > "$CACHE/mods/default.txt" <<EOF
VERSION = 1,

mods
{
    mod = $MOD_ID,
    mod = $HARNESS_MOD_ID,
    mod = $DEV_MOD_ID,
}

maps
{
}
EOF
    # The harness sets the scenario's forceLaunch; this debug option lets it start from the main
    # menu.
    printf 'Version=1\nDebugScenario.ForceLaunch=%s\n' "$([ -n "$MODE" ] && echo true || echo false)" > "$CACHE/debug-options.ini"
}

install_mod
# This run's part of console.txt: all of it after a launch; in a kept game, from this run's request
# on, copied to RUN_LOG on every poll. The checks read files rather than pipes into grep -q, whose
# early exit would make pipefail report a match as a miss.
RUN_ID=
RUN_LOG=$LOG
if [ -n "$SESSION_PID" ]; then
    PID=$SESSION_PID
    request_rerun
    RUN_LOG="$CACHE/console-rerun.txt"
    echo "rerunning the tests in the game kept open by --stay (pid $PID)"
else
    prepare_cache
    GAME=("$JAVA" "${JVM_COMMON[@]}" -XstartOnFirstThread -Xmx3072m -XX:+UseZGC)
    GAME_ARGS=(-debug -nosteam -cachedir="$CACHE")
    cd "$PZ/Java"
    if [ -z "$MODE" ]; then
        exec "${GAME[@]}" -cp "$GAME_CLASSPATH" zombie.gameStates.MainScreenState "${GAME_ARGS[@]}"
    fi

    LAUNCHER="$CACHE/launcher"
    compile_java "$HARNESS/java/ClickToStart.java" "$LAUNCHER"

    # GLFW finds no monitor while the display sleeps, and the game can't open its window.
    # caffeinate -u wakes the display, and -d -i keep it and the computer awake until this script
    # exits.
    caffeinate -d -i -u -w $$ &
    for _ in $(seq 10); do
        system_profiler SPDisplaysDataType | grep -q "Display Asleep: Yes" || break
        sleep 1
    done

    # Only this mode's screenshots go, so one mode's run doesn't delete another's.
    rm -f "$LOG" "$CACHE/Screenshots/${MODE}"_*.png
    # Neither the game nor its caffeinate holds this script's stdin or output, so a caller reading
    # that output sees it end when the script exits, even if the game stays open with --stay.
    "${GAME[@]}" -cp "$LAUNCHER:$GAME_CLASSPATH" ClickToStart "${GAME_ARGS[@]}" < /dev/null > "$CACHE/stdout.txt" 2>&1 &
    PID=$!
    if [ -n "$STAY" ]; then
        # Keeps the display awake for the kept game, after this script exits.
        caffeinate -d -i -w "$PID" < /dev/null > /dev/null 2>&1 &
    fi
fi
if [ -n "$STAY" ]; then
    keep_game_on_exit "$PID"
else
    stop_game_on_exit "$PID"
fi

update_run_log() {
    if [ -n "$RUN_ID" ]; then
        sed -n "/> $TAG RUN $RUN_ID\$/,\$p" "$LOG" > "$RUN_LOG" 2>/dev/null || true
    fi
}
# Whether this run's log has a line matching the extended regex $1, at or after the harness's
# first $MARK line if $2 is "harness".
logged() {
    [ -f "$RUN_LOG" ] || return 1
    RE=$1 FROM=$([ "${2:-}" = harness ] && echo "> $MARK " || true) awk '
        BEGIN { started = ENVIRON["FROM"] == "" }
        !started && index($0, ENVIRON["FROM"]) { started = 1 }
        started && $0 ~ ENVIRON["RE"] { found = 1; exit }
        END { exit !found }' "$RUN_LOG"
}
# In debug mode a Lua error stops the game at the error, so it never quits on its own. A stack
# trace through the mods' Lua, or any failure once the harness has started, ends the run at once
# instead of at the timeout. Stack trace frames are indented; a require warning names the mod on a
# WARN line instead.
lua_stopped() {
    logged "^[[:space:]]+Lua\\($OUR_LUA_ERROR" \
        || logged '^Lua fail|dumping Lua stack trace|Error found in LUA file' harness
}
# A game without --stay quits when it is done; a kept one prints the DONE line and waits.
STOPPED= DONE=
SECONDS=0
while [ "$SECONDS" -lt "$TIMEOUT" ]; do
    kill -0 "$PID" 2>/dev/null || break
    update_run_log
    if lua_stopped; then
        STOPPED=1
        sleep 2 # lets the rest of the stack trace reach the log
        update_run_log
        break
    fi
    if [ -n "$STAY" ] && logged "> $TAG DONE "; then
        DONE=1
        break
    fi
    sleep 0.5
done
if [ -n "$STOPPED" ]; then
    echo "FAIL: a Lua error stopped the game; the stack trace from $LOG:"
    grep -n -A20 'dumping Lua stack trace' "$RUN_LOG" | grep -v -E '^[0-9]+-\s+(se\.krka|java\.|zombie\.)' | head -40
    stop_game
    exit 1
fi
if [ -z "$DONE" ] && kill -0 "$PID" 2>/dev/null; then
    echo "FAIL: no result after ${TIMEOUT}s; stopping the game"
    stop_game
    exit 1
fi

echo "log: $LOG"
if ! logged "$MARK"; then
    echo "FAIL: the game stopped before the harness ran; the end of $CACHE/stdout.txt:"
    tail -n 20 "$CACHE/stdout.txt"
    exit 1
fi
grep -o "$MARK.*" "$RUN_LOG" | grep -v "^$TAG RUN " | uniq || true
# Anything the mod logs counts, from loading on. A mod mistake can also surface as an error in
# vanilla Lua, such as a crafting window drawing an item the mod defined badly, so every Lua error
# counts once the harness has started; before that, vanilla logs errors of its own.
if grep -n -E "$MOD_ERROR" "$RUN_LOG" \
    || sed -n "/> $MARK /,\$p" "$RUN_LOG" | grep -n -E "^ERROR: Lua|LuaManager.*Exception|-- file: "; then
    echo "FAIL: Lua errors were logged"
    exit 1
fi
if [ "$MODE" != test ]; then
    if ! logged "$MARK DONE"; then
        echo "FAIL: the harness didn't finish"
        exit 1
    fi
    if declare -F "harness_after_$MODE" > /dev/null; then
        "harness_after_$MODE"
    else
        echo "PASS"
    fi
    exit 0
fi
if ! logged "$TAG DONE passed=[1-9][0-9]* failed=0$"; then
    echo "FAIL: not every test passed"
    exit 1
fi
echo "PASS"
