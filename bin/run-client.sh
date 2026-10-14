#!/usr/bin/env bash
# Starts the game client in debug mode (no Steam) with its own cache dir, the mod, its dev mod and
# the harness mod enabled. A mod's dev/run-debug-client.sh runs this; docs/running.md describes the
# modes and the environment variables, and docs/adopting.md dev/harness.conf.
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
#                    "<TAG> IDLE"; it quits after 30 minutes without a run, or when another run
#                    needs the game.
#   --test --mp      the same in multiplayer: starts a dedicated server with the three mods and a
#                    client that joins it as the admin, runs the tests on the client, and fails on
#                    a problem in either log. With --stay both stay open, and the next
#                    --test --mp --stay reruns the tests, the server loading its share of the
#                    RELOAD_FILES again too.
#   --test --failed  runs only the tests that failed, or were running when the game stopped, in
#                    the last --test run of the same kind (with or without --mp)
#   --test --changed runs the tests the conf's TEST_MAP gives for the files changed since HEAD
#   --<mode>         one of the conf's MODES: starts the scenario and runs the mod's handler for it
#                    instead of the tests
#
# With --test, REPEAT=<n> runs the selection n times in one game, ORDER=reverse or
# ORDER=shuffle[:<seed>] changes the order, and LEAKS=fail (the default), warn or off sets what the
# leak check between tests does. docs/running.md and docs/debugging.md describe them.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"

usage() {
    local modes=
    for mode in ${MODES:-}; do
        modes="$modes | --$mode"
    done
    echo "usage: $0 [--test [--mp] [--stay] [--failed | --changed]$modes]" >&2
    exit 2
}
MODE= STAY= MP= FAILED= CHANGED=
for arg in "$@"; do
    case "$arg" in
        --test) MODE=test ;;
        --stay) STAY=1 ;;
        --mp) MP=1 ;;
        --failed) FAILED=1 ;;
        --changed) CHANGED=1 ;;
        --*)
            case " ${MODES:-} " in
                *" ${arg#--} "*) MODE=${arg#--} ;;
                *) usage ;;
            esac
            ;;
        *) usage ;;
    esac
done
if { [ -n "$STAY" ] || [ -n "$MP" ] || [ -n "$FAILED" ] || [ -n "$CHANGED" ]; } && [ "$MODE" != test ]; then
    usage
fi
if [ -n "$FAILED" ] && [ -n "$CHANGED" ]; then
    usage
fi
if { [ -n "$FAILED" ] || [ -n "$CHANGED" ]; } && [ -n "${TESTS:-}" ]; then
    echo "TESTS picks the tests itself; leave it out with --failed or --changed" >&2
    exit 2
fi
if [ -n "$MP" ]; then
    CACHE="${CACHE:-$TMP_REAL/$CACHE_NAME-mpclient}"
    SERVER_CACHE="${SERVER_CACHE:-$TMP_REAL/$CACHE_NAME-mpserver}"
    # Off the default 16261, so a real server can keep running.
    SERVER_PORT=${SERVER_PORT:-16361}
else
    CACHE="${CACHE:-$TMP_REAL/$CACHE_NAME-client}"
fi
# What the run does, comma-separated: for --test TESTS name prefixes or exact "=<name>" names
# (from --failed or --changed when given), else the variable the conf names in
# MODE_SELECTION_<mode>.
SELECTION=
MARK=$TAG
# The test runs' settings, which the runner reads with the selection.
LEAKS=${LEAKS:-fail} ORDER=${ORDER:-} ROUNDS=${REPEAT:-1}
# Where --failed finds what failed last, one line per kind of run: "<test or test-mp>
# <name>:<runs>,...", each test that failed with the number of runs of that kind in a row it has
# failed.
FAILED_KEY="test${MP:+-mp}"
# Runs in a row a test may fail before the script says reruns aren't narrowing it down.
STUCK_RUNS=3

# The exact names of the tests that failed in the last run of this kind, as a selection.
select_failed() {
    local line names
    line=$(grep "^$FAILED_KEY " "$RUNS_FAILED" 2>/dev/null | tail -1 || true)
    if [ -z "$line" ]; then
        echo "--failed: no $FAILED_KEY run has been recorded in ${RUNS_FAILED#"$REPO/"} yet" >&2
        exit 2
    fi
    names=$(sed 's/:[0-9]*//g' <<< "${line#"$FAILED_KEY "}")
    if [ -z "$names" ]; then
        echo "--failed: nothing failed in the last $FAILED_KEY run; no tests to run"
        exit 0
    fi
    echo "--failed: rerunning what failed in the last $FAILED_KEY run: ${names//,/, }"
    SELECTION="=${names//,/,=}"
}

# Every file changed since HEAD, staged, unstaged or untracked, relative to the repository, the
# harness submodule's own changes included.
changed_files() {
    local submodule=${HARNESS#"$REPO/"}
    {
        git -C "$REPO" diff --name-only HEAD
        git -C "$REPO" ls-files --others --exclude-standard
        { git -C "$HARNESS" diff --name-only HEAD; git -C "$HARNESS" ls-files --others --exclude-standard; } \
            | sed "s|^|$submodule/|"
    } | sort -u
}

# Every file of the repository and the harness submodule, tracked or untracked, relative to the
# repository.
repo_files() {
    local submodule=${HARNESS#"$REPO/"}
    git -C "$REPO" ls-files --cached --others --exclude-standard
    git -C "$HARNESS" ls-files --cached --others --exclude-standard | sed "s|^|$submodule/|"
}

# Fails the run on a TEST_MAP glob that matches no file, such as one for a file since renamed,
# whose new name then runs every test until the conf says what covers it.
check_test_map() {
    local files entry glob file found stale=
    files=$(repo_files)
    for entry in ${TEST_MAP[@]+"${TEST_MAP[@]}"}; do
        glob=${entry%%=*}
        found=
        while read -r file; do
            # shellcheck disable=SC2053 # the glob is a pattern
            if [[ $file == $glob ]]; then
                found=1
                break
            fi
        done <<< "$files"
        if [ -z "$found" ]; then
            echo "--changed: TEST_MAP's $glob matches no file" >&2
            stale=1
        fi
    done
    if [ -n "$stale" ]; then
        echo "--changed: fix TEST_MAP in dev/harness.conf" >&2
        exit 2
    fi
}

# The test prefixes the conf's TEST_MAP gives for the changed files under the mod, the dev mod and
# the harness mod, saying why for each file. A changed file there that no glob covers runs every
# test; files elsewhere, such as docs and art, run none.
select_changed() {
    local roots=("${MOD_DIR#"$REPO/"}/" "${DEV_MOD_DIR#"$REPO/"}/" "${HARNESS_MOD_DIR#"$REPO/"}/")
    local file root under matched entry glob prefixes picked= everything= relevant=
    check_test_map
    while read -r file; do
        under=
        for root in "${roots[@]}"; do
            [[ $file == "$root"* ]] && under=1
        done
        [ -n "$file" ] && [ -n "$under" ] || continue
        relevant=1
        matched=
        for entry in ${TEST_MAP[@]+"${TEST_MAP[@]}"}; do
            glob=${entry%%=*}
            prefixes=${entry#*=}
            # shellcheck disable=SC2053 # the glob is a pattern
            if [[ $file == $glob ]]; then
                matched=1
                picked="$picked,$prefixes"
                echo "--changed: $file: ${prefixes:-no tests}"
            fi
        done
        if [ -z "$matched" ]; then
            echo "--changed: $file: no TEST_MAP glob covers it, so every test runs"
            everything=1
        fi
    done < <(changed_files)
    if [ -z "$relevant" ]; then
        echo "--changed: nothing under the mods changed since HEAD; no tests to run"
        exit 0
    fi
    if [ -n "$everything" ]; then
        SELECTION=
        return
    fi
    SELECTION=$(tr ',' '\n' <<< "$picked" | sed '/^$/d' | sort -u | paste -sd, -)
    if [ -z "$SELECTION" ]; then
        echo "--changed: no test covers the changed files; no tests to run"
        exit 0
    fi
    echo "--changed: running $SELECTION"
}

if [ "$MODE" = test ]; then
    SELECTION=${TESTS:-}
    if [ -n "$FAILED" ]; then
        select_failed
    elif [ -n "$CHANGED" ]; then
        select_changed
    fi
    case $LEAKS in
        fail | warn | off) ;;
        *) echo "LEAKS is fail, warn or off" >&2; exit 2 ;;
    esac
    if ! [[ $ROUNDS =~ ^[1-9][0-9]*$ ]]; then
        echo "REPEAT is a whole number of rounds from 1" >&2
        exit 2
    fi
    case $ORDER in
        "" | reverse) ;;
        shuffle)
            # Two of bash's 15-bit random numbers, so seeds don't repeat often.
            ORDER="shuffle:$(( (RANDOM * 32768 + RANDOM) % 2147483646 ))"
            echo "order: $ORDER (ORDER=$ORDER repeats it)"
            ;;
        shuffle:*)
            [[ ${ORDER#shuffle:} =~ ^[0-9]+$ ]] || { echo "ORDER=shuffle:<seed> takes a whole number" >&2; exit 2; }
            ;;
        *) echo "ORDER is reverse, shuffle or shuffle:<seed>" >&2; exit 2 ;;
    esac
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
# Only a game that died or hung outside a test: the runner fails a stuck test itself after its
# per-test limit (Runner.lua). A cold --mp run of a whole suite takes about 2.5 minutes, and REPEAT
# runs it that many times over. The other modes, such as a mod's long reports, keep the old cap.
if [ "$MODE" = test ]; then
    TIMEOUT=${TIMEOUT:-$((300 * ROUNDS))}
else
    TIMEOUT=${TIMEOUT:-1200}
fi

# What a --test run's verdict depends on: the kind of run, the selection and settings, the game
# install and its code, which a Steam update changes, and the contents of the files the game loads
# from the three mods, the harness and the conf. RUNS_LOG keeps it with each run.
run_fingerprint() {
    {
        printf '%s\n' "$MP" "$STAY" "$SELECTION" "$LEAKS" "$ORDER" "$ROUNDS" "$PZ"
        find "$PZ/Java/projectzomboid.jar" "$MOD_DIR" "$DEV_MOD_DIR" "$HARNESS_MOD_DIR" "$HARNESS/bin" \
            "$HARNESS/lib" "$HARNESS/java" "$REPO/dev/harness.conf" -type f -print0 | sort -z | xargs -0 md5 -r
    } | md5 -q
}

# The same run on the same files gives the same verdict, so a run that already got one repeats it
# rather than spend a game on it, unless RERUN is set. A run that never reached its verdict, such
# as one a Lua error stopped, doesn't count.
if [ "$MODE" = test ]; then
    RUN_FINGERPRINT=$(run_fingerprint)
    previous=$(grep " fingerprint=$RUN_FINGERPRINT\$" "$RUNS_LOG" 2>/dev/null | grep -v " passed=- " | tail -1 || true)
    if [ -n "$previous" ] && [ -z "${RERUN:-}" ]; then
        echo "this exact run already ran at ${previous%% *}, with $(grep -o 'passed=[^ ]* failed=[^ ]* skipped=[^ ]*' <<< "$previous"), and nothing it loads has changed since"
        echo "change the code or the selection first; REPEAT=<n> measures a flaky test, and RERUN=1 runs it again when the game rather than a test failed"
        exit "$(sed -n 's/.* exit=\([0-9]*\) .*/\1/p' <<< "$previous")"
    fi
fi
if [ -n "$MODE" ]; then
    run_precheck
fi
LOG="$CACHE/console.txt"
# The harness Lua reads the run from the first file, with --stay rerun requests from the second
# and with --mp the server to join from the third, written once the server has started
# (PZHarness/Runner.lua).
HARNESS_FILE="$CACHE/Lua/PZHarness.txt"
REQUEST_FILE="$CACHE/Lua/PZHarnessRerun.txt"
CONNECT_FILE="$CACHE/Lua/PZHarnessConnect.txt"

# Whether $1, relative to the dev mod, is one of the files a rerun loads again.
reloaded() {
    local pattern
    for pattern in "${RELOAD_FILES[@]}"; do
        # shellcheck disable=SC2053 # the pattern is a glob
        [[ $1 == $pattern ]] && return 0
    done
    return 1
}

# Why a kept game can't rerun the tests: it belongs to another cache dir, part of it has stopped,
# or something it loaded only at start changed since. Prints nothing if it can.
session_stale() {
    if [ "$SESSION_CACHE" != "$CACHE" ]; then
        echo "it runs with the cache dir $SESSION_CACHE"
        return
    fi
    local pid
    for pid in $SESSION_GAMES; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "its process $pid has stopped"
            return
        fi
    done
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
# The run's phases are timed from here, after any wait for another script's game (report_timing).
timing_mark start
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

# Sends a kept game the tests to run, the run's settings and the files to load again, in the
# conf's order. The id names the run in console.txt. With --mp the server loads the shared and
# server files again too, from its own cache dir.
request_rerun() {
    RUN_ID="$$-$(date +%s)"
    local pattern file relative server_files=()
    {
        echo "$RUN_ID"
        echo "$SELECTION"
        printf 'option leaks=%s\noption order=%s\noption rounds=%s\n' "$LEAKS" "$ORDER" "$ROUNDS"
        for pattern in "${RELOAD_FILES[@]}"; do
            for file in "$CACHE/mods/$DEV_MOD_FOLDER/"$pattern; do
                [ -f "$file" ] || continue
                echo "$file"
                relative=${file#"$CACHE/mods/$DEV_MOD_FOLDER/"}
                if [ -n "$MP" ] && [[ $relative == */media/lua/server/* || $relative == */media/lua/shared/* ]]; then
                    server_files+=("server $SERVER_CACHE/mods/$DEV_MOD_FOLDER/$relative")
                fi
            done
        done
        if [ ${#server_files[@]} -gt 0 ]; then
            printf '%s\n' "${server_files[@]}"
        fi
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
    # tests too.
    link_dev_mods
    mkdir -p "$CACHE/Lua"
    rm -f "$REQUEST_FILE" "$CONNECT_FILE"
    # Written when playing by hand too: the tests take their console tag from it. A --test world
    # is quiet (QUIET_WORLD, lib/harness.sh); the runner sets those options before the scenario's
    # own setSandbox, which may override them.
    local quiet=
    if [ "$MODE" = test ]; then
        quiet=$(IFS=,; echo "${QUIET_WORLD[*]+${QUIET_WORLD[*]}}")
    fi
    printf 'mode=%s\nselection=%s\nstay=%s\nmp=%s\nmark=%s\ntag=%s\nleaks=%s\norder=%s\nrounds=%s\nquiet=%s\n' \
        "$MODE" "$SELECTION" "$STAY" "$MP" "$MARK" "$TAG" "$LEAKS" "$ORDER" "$ROUNDS" "$quiet" > "$HARNESS_FILE"
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
    # menu. A multiplayer client joins the server instead.
    printf 'Version=1\nDebugScenario.ForceLaunch=%s\n' "$([ -n "$MODE" ] && [ -z "$MP" ] && echo true || echo false)" > "$CACHE/debug-options.ini"
    if [ -n "$MP" ]; then
        # The character the client kept of the last run's server, whose world is gone.
        rm -rf "$CACHE/Saves/Multiplayer"
    fi
}

# The server of --mp: the three mods, no zombies, a quiet world, not paused while nobody plays,
# open to the client without a whitelist, on its own ports. Every harness test world has no
# zombies, so nothing attacks the character during the tests. The server runs its sandbox file as
# Lua, so the lines go after the conf's options, and the quiet ones (QUIET_WORLD) only where the
# conf's hook set nothing.
prepare_mp_server() {
    local client_cache=$CACHE sandbox option
    CACHE=$SERVER_CACHE
    link_dev_mods
    prepare_server "$MOD_ID;$HARNESS_MOD_ID;$DEV_MOD_ID" "DefaultPort=$SERVER_PORT" \
        "UDPPort=$((SERVER_PORT + 1))" Open=true PauseEmpty=false
    sandbox="$CACHE/Server/${SERVER_NAME}_SandboxVars.lua"
    if [ -f "$sandbox" ]; then
        echo "SandboxVars.Zombies = 6" >> "$sandbox"
    else
        echo "SandboxVars = { Zombies = 6 }" > "$sandbox"
    fi
    for option in ${QUIET_WORLD[@]+"${QUIET_WORLD[@]}"}; do
        echo "if SandboxVars.${option%%=*} == nil then SandboxVars.${option%%=*} = ${option#*=} end" >> "$sandbox"
    done
    timing_mark server_start
    start_server
    CACHE=$client_cache
}

install_mod
# This run's part of console.txt: all of it after a launch; in a kept game, from this run's request
# on, copied to RUN_LOG on every poll. The same for the server's log with --mp. The checks read
# files rather than pipes into grep -q, whose early exit would make pipefail report a match as a
# miss.
RUN_ID=
RUN_LOG=$LOG
SERVER_LOG= SERVER_RUN_LOG= SERVER_PID=
if [ -n "$SESSION_PID" ]; then
    # shellcheck disable=SC2086 # the client's PID, then the server's
    set -- $SESSION_GAMES
    GAME_PID=$1
    if [ -n "$MP" ]; then
        SERVER_PID=$2
        SERVER_LOG="$SERVER_CACHE/server-console.txt"
        SERVER_RUN_LOG="$SERVER_CACHE/server-console-rerun.txt"
    fi
    request_rerun
    timing_mark launch
    RUN_LOG="$CACHE/console-rerun.txt"
    echo "rerunning the tests in the game kept open by --stay (pid $SESSION_GAMES)"
    keep_games_on_exit "$SESSION_PID"
else
    prepare_cache
    GAME=("$JAVA" "${JVM_COMMON[@]}" -XstartOnFirstThread -Xmx3072m -XX:+UseZGC)
    GAME_ARGS=(-debug -nosteam -cachedir="$CACHE")
    if [ -z "$MODE" ]; then
        cd "$PZ/Java"
        exec "${GAME[@]}" -cp "$GAME_CLASSPATH" zombie.gameStates.MainScreenState "${GAME_ARGS[@]}"
    fi
    LAUNCHER="$CACHE/launcher"
    compile_java "$HARNESS/java/ClickToStart.java" "$LAUNCHER"

    # Whatever fails from here on, the games started so far stop with the script; only a --stay run
    # that launched its client hands them on instead, below.
    stop_games_on_exit
    if [ -n "$MP" ]; then
        prepare_mp_server
        SERVER_RUN_LOG=$SERVER_LOG
    fi

    # GLFW finds no monitor while the display sleeps, and the game can't open its window.
    # caffeinate -u wakes the display, and -d -i keep it and the computer awake until this script
    # exits.
    caffeinate -d -i -u -w $$ &
    for _ in $(seq 10); do
        displays=$(system_profiler SPDisplaysDataType)
        [[ $displays == *"Display Asleep: Yes"* ]] || break
        sleep 1
    done

    # Only this mode's screenshots go, so one mode's run doesn't delete another's.
    rm -f "$LOG" "$CACHE/Screenshots/${MODE}"_*.png
    # Neither the game nor its caffeinate holds this script's stdin or output, so a caller reading
    # that output sees it end when the script exits, even if the game stays open with --stay. With
    # --mp the client boots while the server does and joins once it has started.
    timing_mark launch
    (cd "$PZ/Java" && exec "${GAME[@]}" -cp "$LAUNCHER:$GAME_CLASSPATH" ClickToStart "${GAME_ARGS[@]}" \
        < /dev/null > "$CACHE/stdout.txt" 2>&1) &
    GAME_PID=$!
    if [ -n "$STAY" ] && [ -n "$MP" ]; then
        # Owns the kept game's lock after this script exits: keeps the display awake while the
        # client runs, stops the server once the client has quit (it does after its idle time),
        # and exits once both are gone, so the lock is free only then.
        (caffeinate -d -i -w "$GAME_PID"; stop_pid "$SERVER_PID") < /dev/null > /dev/null 2>&1 &
        keep_games_on_exit $!
    elif [ -n "$STAY" ]; then
        # Keeps the display awake for the kept game, after this script exits.
        caffeinate -d -i -w "$GAME_PID" < /dev/null > /dev/null 2>&1 &
        keep_games_on_exit
    fi
fi

# The tests that failed in this run, or were running when it stopped, for the next --failed run of
# the same kind, each with how many such runs in a row it has failed; a run that never started its
# tests leaves the last record alone. A FAIL line names its test, as do the late failures of its
# server undos; one for a call outside any test names the handler, which no TEST line does.
record_failed_tests() {
    [ "$MODE" = test ] && logged "> $TAG START " || return 0
    local names previous name entry runs record= stuck=
    names=$(awk -v tag="$TAG" '
        index($0, "> TEST: ") { current = substr($0, index($0, "> TEST: ") + 8); ran[current] = 1; next }
        index($0, "> " tag " FAIL ") {
            name = substr($0, index($0, "> " tag " FAIL ") + length(tag) + 8)
            sub(/: .*/, "", name)
            if (name in ran) failed[name] = 1
            if (name == current) current = ""
        }
        index($0, "> " tag " PASS ") { current = "" }
        index($0, "> " tag " DONE ") { done = 1 }
        END {
            if (!done && current != "") failed[current] = 1
            for (name in failed) print name
        }' "$RUN_LOG" | sort | paste -sd, -)
    previous=$(grep "^$FAILED_KEY " "$RUNS_FAILED" 2>/dev/null | tail -1 || true)
    for name in ${names//,/ }; do
        runs=1
        for entry in ${previous//,/ }; do
            if [ "${entry%:*}" = "$name" ] && [[ ${entry##*:} =~ ^[0-9]+$ ]]; then
                runs=$((${entry##*:} + 1))
            fi
        done
        record="$record,$name:$runs"
        if [ "$runs" -ge "$STUCK_RUNS" ]; then
            stuck="$stuck $name ($runs)"
        fi
    done
    { grep -v "^$FAILED_KEY " "$RUNS_FAILED" 2>/dev/null || true; echo "$FAILED_KEY ${record#,}"; } > "$RUNS_FAILED.tmp"
    mv "$RUNS_FAILED.tmp" "$RUNS_FAILED"
    if [ -n "$names" ]; then
        echo "--failed reruns: ${names//,/, }"
    fi
    if [ -n "$stuck" ]; then
        echo "failed $STUCK_RUNS or more runs in a row:$stuck. Rerunning won't narrow it; read ${HARNESS#"$REPO/"}/docs/debugging.md and change approach first"
    fi
}

# On exit (exit_report, lib/harness.sh): records what failed for --failed, prints this run's phases
# and appends it to RUNS_LOG. A kept game's rerun has no boot or world phase, and only a game that
# quits has a quit phase. A run a Lua error stopped has a stopped phase instead of the run, up to
# the poll that saw the error.
report_timing() {
    [ -n "$MODE" ] || return 0
    record_failed_tests
    local counts
    counts=$(sed -n "s/.*> $TAG DONE \(passed=[0-9]* failed=[0-9]* skipped=[0-9]*\)\$/\1/p" "$RUN_LOG" 2>/dev/null | tail -1)
    report_run "$1" "$MODE${MP:+-mp}${SESSION_PID:+-rerun}" "${SELECTION:-all}" \
        "${counts:-passed=- failed=- skipped=-}" \
        "setup|launch|script start to the game's launch, or to the rerun request in a kept game" \
        "boot|lua|game launch to the harness's Lua" \
        "world|world|to the world loaded around the character" \
        "start|first|to the first test" \
        "run|done|to the last result" \
        "stopped|stopped|to the Lua error that stopped the run" \
        "quit|exit|to the game's exit, and with --mp the server's" \
        "server|server_ready|server launch to ready|server_start"
}

# The milestones in this run's log, each timed when a poll first sees it.
note_milestones() {
    local milestone pattern var
    for milestone in lua world first done; do
        case $milestone in
            lua) pattern="PZHarness: the dev mod registered" ;;
            world) pattern="PZHarness: starting after" ;;
            first) pattern="> TEST: " ;;
            done) pattern="> $MARK DONE" ;;
        esac
        var="TIMING_$milestone"
        if [ -z "${!var:-}" ] && logged "$pattern"; then
            timing_mark "$milestone"
        fi
    done
}

update_run_log() {
    if [ -n "$RUN_ID" ]; then
        sed -n "/> $TAG RUN $RUN_ID\$/,\$p" "$LOG" > "$RUN_LOG" 2>/dev/null || true
        if [ -n "$MP" ]; then
            sed -n "/> $TAG RUN $RUN_ID\$/,\$p" "$SERVER_LOG" > "$SERVER_RUN_LOG" 2>/dev/null || true
        fi
    fi
}
# Whether log $3 (this run's client log by default) has a line matching the extended regex $1, at
# or after the harness's first $MARK line if $2 is "harness".
logged() {
    local file=${3:-$RUN_LOG}
    [ -f "$file" ] || return 1
    RE=$1 FROM=$([ "${2:-}" = harness ] && echo "> $MARK " || true) awk '
        BEGIN { started = ENVIRON["FROM"] == "" }
        !started && index($0, ENVIRON["FROM"]) { started = 1 }
        started && $0 ~ ENVIRON["RE"] { found = 1; exit }
        END { exit !found }' "$file"
}
# In debug mode a Lua error stops the game at the error, so it never quits on its own. A stack
# trace through the mods' Lua, or any failure once the harness has started, ends the run at once
# instead of at the timeout. A Lua stack trace indents its frames once; a Java exception the game
# logs and goes on from, as multiplayer's action sync does, indents them twice and counts only in
# the scan after the run. A require warning names the mod on a WARN line instead.
lua_stopped() {
    logged "^[[:space:]]Lua\\($OUR_LUA_ERROR" \
        || logged '^Lua fail|dumping Lua stack trace|Error found in LUA file' harness
}
# A game without --stay quits when it is done; a kept one prints the DONE line and waits. A server
# goes on after a Lua error, so only the client's errors end the run early: a test waiting on the
# server gets its answer or gives up, the scan after the run finds the server's stack trace, and
# the games kept by --stay stay up for the next run.
STOPPED= DONE= SERVER_GONE=
SECONDS=0
while [ "$SECONDS" -lt "$TIMEOUT" ]; do
    kill -0 "$GAME_PID" 2>/dev/null || break
    if [ -n "$MP" ]; then
        if [ -z "${SERVER_QUIT:-}" ] && ! kill -0 "$SERVER_PID" 2>/dev/null; then
            SERVER_GONE=1
            break
        fi
        if [ ! -f "$CONNECT_FILE" ] && server_started; then
            timing_mark server_ready
            printf 'host=127.0.0.1\nport=%s\nuser=%s\npassword=%s\n' "$SERVER_PORT" "$SERVER_ADMIN" \
                "$SERVER_ADMIN_PASSWORD" > "$CONNECT_FILE.tmp"
            mv "$CONNECT_FILE.tmp" "$CONNECT_FILE"
        fi
    fi
    update_run_log
    note_milestones
    if lua_stopped; then
        STOPPED=1
        timing_mark stopped
        sleep 2 # lets the rest of the stack trace reach the log
        update_run_log
        break
    fi
    if logged "> $TAG DONE "; then
        if [ -n "$STAY" ]; then
            DONE=1
            break
        fi
        # The server saves and quits while the client does.
        quit_server
    fi
    sleep 0.5
done
# A client that quits right after its last line can be gone before a poll sees that line, and the
# loop then ends at its first check, so the log gets one more look.
update_run_log
note_milestones
if [ -n "$STOPPED" ]; then
    echo "FAIL: a Lua error stopped the game; the stack trace from $LOG:"
    grep -n -A20 'dumping Lua stack trace' "$RUN_LOG" | grep -v -E '^[0-9]+-\s+(se\.krka|java\.|zombie\.)' | head -40
    stop_games
    exit 1
fi
if [ -n "$SERVER_GONE" ]; then
    echo "FAIL: the server stopped; the end of $SERVER_CACHE/stdout.txt:"
    tail -n 20 "$SERVER_CACHE/stdout.txt"
    stop_games
    exit 1
fi
if [ -z "$DONE" ] && kill -0 "$GAME_PID" 2>/dev/null; then
    echo "FAIL: no result after ${TIMEOUT}s; stopping the game"
    stop_games
    exit 1
fi
# The server's log counts up to its exit: saving the world runs the mods' code too.
if [ -n "$MP" ] && [ -z "$STAY" ]; then
    stop_server
fi
# The quit phase runs until the client has exited and, with --mp, the server has saved and exited.
if ! kill -0 "$GAME_PID" 2>/dev/null; then
    timing_mark exit
fi

echo "log: $LOG"
if [ -n "$MP" ]; then
    echo "server log: $SERVER_LOG"
fi
if ! logged "$MARK"; then
    echo "FAIL: the game stopped before the harness ran; the harness's lines and the end of $CACHE/stdout.txt:"
    grep -o "PZHarness: .*" "$RUN_LOG" || true
    tail -n 20 "$CACHE/stdout.txt"
    exit 1
fi
grep -o "$MARK.*" "$RUN_LOG" | grep -v "^$TAG RUN " | uniq || true
# Anything the mod logs counts, from loading on. A mod mistake can also surface as an error in
# vanilla Lua, such as a crafting window drawing an item the mod defined badly, so every Lua error
# counts once the harness has started, and so does any exception logged through the three mods'
# Lua; before that, vanilla logs errors of its own.
if grep -n -E "$MOD_ERROR" "$RUN_LOG" \
    || sed -n "/> $MARK /,\$p" "$RUN_LOG" | grep -n -E "^ERROR: Lua|LuaManager.*Exception|-- file: |$OUR_LUA_ERROR"; then
    echo "FAIL: Lua errors were logged"
    exit 1
fi
# The server's log as validate-server.sh reads it, plus stack traces through the dev mod and the
# harness mod, and the failures the harness's server half reports.
if [ -n "$MP" ]; then
    # A stack trace repeats in several forms, so the first lines say enough.
    problems=$(server_problems "$SERVER_RUN_LOG" "$OUR_LUA_ERROR|$TAG SERVER FAIL" || true)
    if [ -n "$problems" ]; then
        head -30 <<< "$problems"
        echo "FAIL: the server logged problems"
        exit 1
    fi
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
if logged "$TAG DONE passed=0 failed=0 skipped=[0-9]+$"; then
    echo "FAIL: no test ran in this mode ($(sed -n "s/.*> $TAG DONE passed=0 failed=0 skipped=\([0-9]*\)\$/\1/p" "$RUN_LOG" | tail -1) skipped)"
    exit 1
fi
if ! logged "$TAG DONE passed=[1-9][0-9]* failed=0 skipped=[0-9]+$"; then
    echo "FAIL: not every test passed"
    exit 1
fi
echo "PASS"
