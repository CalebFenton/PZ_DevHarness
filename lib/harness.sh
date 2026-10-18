# shellcheck shell=bash
# Sourced by the harness scripts and by a mod's own dev scripts. The harness sits in the mod's
# repository at dev/harness, and the mod describes itself in dev/harness.conf (see docs/adopting.md).
# PZ_APP overrides the game's Contents folder, and CACHE the cache dir that the calling script
# defaults to.

HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "$HARNESS/../.." && pwd)"
# shellcheck source=/dev/null
. "$REPO/dev/harness.conf"

PZ="${PZ_APP:-$HOME/Library/Application Support/Steam/steamapps/common/ProjectZomboid/Project Zomboid.app/Contents}"
JAVA="$PZ/PlugIns/jre-$(uname -m | sed 's/arm64/aarch64/')/Contents/Home/bin/java"

# The value of `key=` in a mod.info.
mod_info() {
    sed -n "s/^$2=//p" "$1/42/mod.info" | head -1
}

# An extended regex matching the text $1 literally.
literal_regex() {
    printf '%s' "$1" | sed 's/[][\.|$(){}?+*^]/\\&/g'
}

MOD_DIR="$REPO/$MOD_DIR"
MOD_FOLDER="$(basename "$MOD_DIR")"
MOD_ID="$(mod_info "$MOD_DIR" id)"
DEV_MOD_DIR="$REPO/$DEV_MOD_DIR"
DEV_MOD_FOLDER="$(basename "$DEV_MOD_DIR")"
DEV_MOD_ID="$(mod_info "$DEV_MOD_DIR" id)"
HARNESS_MOD_DIR="$HARNESS/mod"
HARNESS_MOD_FOLDER=PZTestHarness
HARNESS_MOD_ID="$(mod_info "$HARNESS_MOD_DIR" id)"

# Lua stack traces name a mod as "(MOD:<name in mod.info>)". MOD_ERROR matches the published mod,
# OUR_LUA_ERROR any of the three mods a harness run loads.
MOD_ERROR="\\(MOD:$(literal_regex "$(mod_info "$MOD_DIR" name)")\\)"
OUR_LUA_ERROR="\\(MOD:($(literal_regex "$(mod_info "$MOD_DIR" name)")|$(literal_regex "$(mod_info "$DEV_MOD_DIR" name)")|$(literal_regex "$(mod_info "$HARNESS_MOD_DIR" name)"))\\)"

# JVM arguments shared by the client and the dedicated server. Both run from "$PZ/Java", which
# GAME_CLASSPATH is relative to.
JVM_COMMON=(-Djava.awt.headless=true -Djava.library.path=. --enable-native-access=ALL-UNNAMED
    --add-exports=java.base/jdk.internal.misc=ALL-UNNAMED -Dzomboid.steam=0 -Dzomboid.znetlog=1
    -XX:-OmitStackTraceInFastThrow)
GAME_CLASSPATH=.:projectzomboid.jar

# The sandbox options of a --test world, as Key=value: the world fills itself in when a chunk or
# building first loads, and some of it at random, so a test could meet objects nobody placed and
# a run differ from the last. A conf that sets QUIET_WORLD itself (=() for none) replaces the
# list, and the mod's own sandbox settings win over it (docs/running.md, "A quiet world").
if ! declare -p QUIET_WORLD > /dev/null 2>&1; then
    QUIET_WORLD=(
        GeneratorSpawning=1   # None: no generators in garages and sheds (IsoCell) or in loot
        SurvivorHouseChance=1 # Never: no building stories, which furnish, barricade and stock houses
        VehicleStoryChance=1  # Never: no crash sites and roadside camps
        ZoneStoryChance=1     # Never: no campsites, picnics and other stories in zones
        AnimalRanchChance=1   # Never: no ranches with their animals, troughs and fences
        AnimalTrackChance=1   # Never: no animal tracks left on squares
        AnimalPathChance=1    # Never: no animal paths among the world's zones
        MaximumRatIndex=0     # no rats and cockroaches in buildings (RBBasic)
        CarSpawnRate=1        # None: no parked or jammed cars where fixtures go (IsoChunk.AddVehicles)
        AnnotatedMapChance=1  # Never: no annotated maps in loot, each of which makes a building a stash
        Alarm=1               # Never: no house alarms going off when a test enters a building
        Helicopter=1          # Never: no helicopter event
        MetaEvent=1           # Never: no distant gunshots and other random sounds
    )
fi

# The game reads depth maps by absolute path and refuses paths outside the mod folders and the
# cache dir without resolving symlinks (ZomboidFileSystem.validatePrefix), so a symlinked mod, or a
# cache under macOS's /var (really /private/var), loses its tile depth maps. Hence a real copy of
# the published mod, in a cache dir under a path with no symlink in it.
TMP_REAL="$(cd "${TMPDIR:-/tmp}" && pwd -P)"

# Compiles a dev Java file, and the files of its folder it uses, into a directory when one of
# those sources is newer than its class. The game's own Java has no compiler, so it needs a JDK's
# javac (or JAVAC); class files for Java 8 run on the game's newer JVM, and any JDK from 8 on can
# write them.
compile_java() {
    local source=$1 dir=$2
    local class folder
    class="$dir/$(basename "$source" .java).class"
    folder=$(dirname "$source")
    if [ ! -f "$class" ] || [ -n "$(find "$folder" -maxdepth 1 -name '*.java' -newer "$class")" ]; then
        mkdir -p "$dir"
        "${JAVAC:-javac}" -nowarn -Xlint:-options -source 8 -target 8 -sourcepath "$folder" -d "$dir" "$source"
    fi
}

install_mod() {
    mkdir -p "$CACHE/mods"
    # rsync copies only what changed; an old symlink in its place has to go first.
    if [ -L "$CACHE/mods/$MOD_FOLDER" ]; then
        rm "$CACHE/mods/$MOD_FOLDER"
    fi
    rsync -a --delete "$MOD_DIR/" "$CACHE/mods/$MOD_FOLDER/"
}

# The harness mod and the dev mod, for a client or a server of a harness run. Symlinks are enough
# for them: they have no tiles.
link_dev_mods() {
    mkdir -p "$CACHE/mods"
    ln -sfn "$HARNESS_MOD_DIR" "$CACHE/mods/$HARNESS_MOD_FOLDER"
    ln -sfn "$DEV_MOD_DIR" "$CACHE/mods/$DEV_MOD_FOLDER"
}

# Only one game process started by these scripts runs at a time, client or server, whichever mod
# started it: several copies of the scripts may run at once, and parallel games starve each other
# of memory and fight over the display. macOS has no flock, so the lock is a directory, which mkdir
# creates atomically, holding the owner's PID. A lock whose owner has died is taken over: a script
# killed outright never runs its EXIT trap, and the manual client execs into the game.
#
# A game kept open by run-client.sh --stay owns the lock itself once its script exits: the lock's
# pid is the owner's, and its "session" file holds the owner's PID, the cache dir and the PIDs of
# the game's processes. The owner is the game itself, or with --mp a keeper that exits once the
# client and the server have. The next script to want the game takes the lock and the game over;
# with the argument "reuse" it leaves the game running and sets SESSION_PID, SESSION_CACHE and
# SESSION_GAMES, and otherwise it stops the game.
GAME_LOCK="${TMPDIR:-/tmp}/PZ_DevHarness-game.lock"
# Taking over someone else's lock, a dead owner's or a kept game's, is a check then an act, and
# several waiters can check at once. This second lock lets one waiter at a time check and act, so
# a later one finds what the earlier one did and doesn't undo it.
GAME_LOCK_TAKEOVER="$GAME_LOCK.takeover"

acquire_game_lock() {
    local owner said=
    SESSION_PID= SESSION_CACHE= SESSION_GAMES=
    until mkdir "$GAME_LOCK" 2>/dev/null; do
        owner=$(cat "$GAME_LOCK/pid" 2>/dev/null || true)
        # A dead owner, or no pid at all for a while: the owner died between mkdir and writing it.
        if { [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; } \
            || { [ -z "$owner" ] && [ -d "$GAME_LOCK" ] && [ "$(age_of "$GAME_LOCK")" -gt 30 ]; }; then
            reap_game_lock "$owner" || sleep 1
            continue
        fi
        if claim_session; then
            break
        fi
        if [ -z "$said" ]; then
            echo "waiting for the game another dev script started (pid ${owner:-unknown}) to exit"
            said=1
        fi
        sleep 2
    done
    echo $$ > "$GAME_LOCK/pid"
    trap 'exit_report $?; release_game_lock' EXIT
    if [ -n "$SESSION_PID" ] && [ "${1:-}" != reuse ]; then
        echo "stopping the game kept open by --stay"
        stop_session
    fi
}

# Seconds since file $1 last changed, 0 if it's gone.
age_of() {
    local changed
    changed=$(stat -f %m "$1" 2>/dev/null) || { echo 0; return; }
    echo $(( $(date +%s) - changed ))
}

# Holds GAME_LOCK_TAKEOVER, or fails if another waiter does. A waiter killed while holding it
# leaves it behind, and a takeover lasts milliseconds, so an old one is removed.
begin_takeover() {
    mkdir "$GAME_LOCK_TAKEOVER" 2>/dev/null && return 0
    if [ "$(age_of "$GAME_LOCK_TAKEOVER")" -gt 10 ]; then
        rmdir "$GAME_LOCK_TAKEOVER" 2>/dev/null || true
    fi
    return 1
}

end_takeover() {
    rmdir "$GAME_LOCK_TAKEOVER"
}

# Removes the lock of owner $1, who has died, or with $1 empty the lock that has held no pid for
# a while, if it still does: another waiter may have removed it and taken a new one meanwhile.
# Fails if another waiter is taking over right now.
reap_game_lock() {
    begin_takeover || return 1
    if [ "$(cat "$GAME_LOCK/pid" 2>/dev/null || true)" = "$1" ] \
        && { [ -n "$1" ] || [ "$(age_of "$GAME_LOCK")" -gt 30 ]; }; then
        rm -rf "$GAME_LOCK"
    fi
    end_takeover
}

# Takes over the lock of a kept game nobody is using: its session file names it, and the lock's pid
# is the owner's own.
claim_session() {
    [ -f "$GAME_LOCK/session" ] && begin_takeover || return 1
    local pid= cache games
    { read -r pid && read -r cache && read -r games; } < "$GAME_LOCK/session" 2>/dev/null || true
    if [ -z "$pid" ] || [ "$(cat "$GAME_LOCK/pid" 2>/dev/null)" != "$pid" ]; then
        end_takeover
        return 1
    fi
    SESSION_PID=$pid SESSION_CACHE=$cache SESSION_GAMES=${games:-$pid}
    echo $$ > "$GAME_LOCK/pid"
    rm -f "$GAME_LOCK/session"
    end_takeover
}

release_game_lock() {
    if [ "$(cat "$GAME_LOCK/pid" 2>/dev/null)" = "$$" ]; then
        rm -rf "$GAME_LOCK"
    fi
}

# Stops the game with PID $1 and waits until it has exited, whether or not this script started it.
# A game can hang on its way out, as one stopped in the debug Lua error handler or a JVM whose
# shutdown hook never returns can, and would hold the lock forever; after STOP_GRACE seconds it is
# killed outright.
STOP_GRACE=30
stop_pid() {
    local polls=0
    kill "$1" 2>/dev/null || true
    while kill -0 "$1" 2>/dev/null; do
        if [ "$polls" -eq $((STOP_GRACE * 2)) ]; then
            echo "process $1 was still running ${STOP_GRACE}s after it was asked to stop, so it was killed"
            kill -9 "$1" 2>/dev/null || true
        fi
        polls=$((polls + 1))
        sleep 0.5
    done
    wait "$1" 2>/dev/null || true
}

# The client first, so it doesn't see its server go.
stop_session() {
    local pid
    for pid in $SESSION_GAMES; do
        stop_pid "$pid"
    done
    stop_pid "$SESSION_PID"
    SESSION_PID= SESSION_GAMES=
}

# The game processes of this script: GAME_PID, the client, and SERVER_PID, a dedicated server
# (start_server). Stops the client, then the server.
stop_games() {
    if [ -n "${GAME_PID:-}" ]; then
        stop_pid "$GAME_PID"
    fi
    if [ -n "${SERVER_PID:-}" ]; then
        stop_server
    fi
}

# Background jobs of a script ignore Ctrl-C, so a game started in the background would outlive the
# script. Stops the games when the script exits, and releases the lock only once they have exited.
stop_games_on_exit() {
    trap 'exit_report $?; stop_games; release_game_lock' EXIT
}

# For --stay: when the script exits, hands the lock to the kept game if all of it still runs, with
# $1 as the lock's owner (the client by default).
keep_games_on_exit() {
    LOCK_OWNER=${1:-$GAME_PID}
    trap 'exit_report $?; hand_lock_to_game' EXIT
}

hand_lock_to_game() {
    local games="$GAME_PID${SERVER_PID:+ $SERVER_PID}" pid running=1
    for pid in $games $LOCK_OWNER; do
        kill -0 "$pid" 2>/dev/null || running=
    done
    if [ -n "$running" ] && [ "$(cat "$GAME_LOCK/pid" 2>/dev/null)" = "$$" ]; then
        printf '%s\n%s\n%s\n' "$LOCK_OWNER" "$CACHE" "$games" > "$GAME_LOCK/session"
        echo "$LOCK_OWNER" > "$GAME_LOCK/pid"
        echo "the game stays open (pid $games); the next --stay run of the same kind reruns the tests in it"
    else
        stop_games
        release_game_lock
    fi
}

# Runs the conf's PRECHECK, normally the mod's dev/static-check.sh, from the repository, and fails
# the script if it fails, before it spends a game on code it rejects.
run_precheck() {
    declare -p PRECHECK > /dev/null 2>&1 && [ ${#PRECHECK[@]} -gt 0 ] || return 0
    if ! (cd "$REPO" && "${PRECHECK[@]}"); then
        echo "FAIL: PRECHECK (${PRECHECK[*]}) failed, so no game started" >&2
        exit 1
    fi
}

# Run timing --------------------------------------------------------------------------------------

# One line per run of the client and server scripts, for a look at where the time goes across many
# runs and for run-client.sh to know a run it has seen, and what failed in the last test run of
# each kind, for run-client.sh --failed. The mod's .gitignore lists both.
RUNS_LOG="$REPO/dev/.runs.log"
RUNS_FAILED="$REPO/dev/.runs-failed"

# Wall-clock seconds to a tenth: macOS's date has no fractions, and its bash no EPOCHREALTIME.
now() {
    perl -MTime::HiRes=time -e 'printf "%.1f\n", time'
}

# Notes the time of milestone $1 in TIMING_$1, the first time only, so a script can call it on
# every poll.
timing_mark() {
    local var="TIMING_$1"
    if [ -z "${!var:-}" ]; then
        printf -v "$var" '%s' "$(now)"
    fi
}

seconds_between() {
    awk -v from="$1" -v to="$2" 'BEGIN { printf "%.1f", to - from }'
}

# Prints a "timing:" line per phase and the total since TIMING_start, and appends the run to
# RUNS_LOG. $1 is the exit status, $2 the mode, $3 the selection, $4 the test counts; each further
# argument is a phase, "key|milestone|what": it runs from the last milestone reached before it
# (TIMING_start first) to its own, and a milestone the run never reached leaves its phase out. A
# fourth field, "|from", names the milestone a phase runs from instead, for one that overlaps the
# others, such as a server booting while the client does.
report_run() {
    local status=$1 mode=$2 selection=$3 counts=$4
    shift 4
    [ -n "${TIMING_start:-}" ] || return 0
    local previous=$TIMING_start fields= phase key milestone what from var at begin seconds
    for phase in "$@"; do
        IFS='|' read -r key milestone what from <<< "$phase"
        var="TIMING_$milestone"
        at=${!var:-}
        [ -n "$at" ] || continue
        if [ -n "$from" ]; then
            var="TIMING_$from"
            begin=${!var:-}
            [ -n "$begin" ] || continue
        else
            begin=$previous
            previous=$at
        fi
        seconds=$(seconds_between "$begin" "$at")
        echo "timing: $key $seconds s ($what)"
        fields="$fields $key=$seconds"
    done
    seconds=$(seconds_between "$TIMING_start" "$(now)")
    echo "timing: total $seconds s"
    printf '%s mode=%s selection=%s %s exit=%s%s total=%s%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$mode" \
        "$selection" "$counts" "$status" "$fields" "$seconds" "${RUN_FINGERPRINT:+ fingerprint=$RUN_FINGERPRINT}" >> "$RUNS_LOG"
}

# The EXIT traps call this first, with the script's exit status; a script that times its run
# defines report_timing, which calls report_run.
exit_report() {
    if declare -F report_timing > /dev/null; then
        report_timing "$1" || true
    fi
}

# Dedicated servers ------------------------------------------------------------------------------

SERVER_NAME=harness
# The server's admin, whom a harness client joins as: a -debug client needs the ConnectWithDebug
# capability (ConnectToServerState, ConnectToServer:OnConnected), which every role but moderator
# has.
SERVER_ADMIN=admin
SERVER_ADMIN_PASSWORD=admin

# A fresh world for the dedicated server of $CACHE: the published mod copied in, Server/
# $SERVER_NAME.ini with Mods=$1 (mod ids joined by ";") and the further ini lines given, then the
# conf's harness_server_setup hook, which can add files such as ${SERVER_NAME}_SandboxVars.lua.
prepare_server() {
    local mods=$1
    shift
    install_mod
    mkdir -p "$CACHE/Server"
    rm -f "$CACHE/Server/$SERVER_NAME"*
    {
        printf 'Mods=%s\nMap=Muldraugh, KY\nUPnP=false\nPublic=false\n' "$mods"
        if [ $# -gt 0 ]; then
            printf '%s\n' "$@"
        fi
    } > "$CACHE/Server/$SERVER_NAME.ini"
    if declare -F harness_server_setup > /dev/null; then
        harness_server_setup
    fi
    # A new world each time, so whatever the mod does for a new world runs every time.
    rm -rf "$CACHE/Saves/Multiplayer/$SERVER_NAME"
}

# Starts the dedicated server of $CACHE in the background, its console reading from file
# descriptor 3: SERVER_PID, and SERVER_LOG, its console.txt. java/FastServer.java starts it with
# more asset loader threads.
start_server() {
    SERVER_LOG="$CACHE/server-console.txt"
    rm -f "$SERVER_LOG"
    compile_java "$HARNESS/java/FastServer.java" "$CACHE/launcher"
    local fifo="$CACHE/stdin"
    rm -f "$fifo"
    mkfifo "$fifo"
    (cd "$PZ/Java" && exec "$JAVA" "${JVM_COMMON[@]}" -cp "$CACHE/launcher:$GAME_CLASSPATH" -Ddebug -Xmx4g FastServer \
        -cachedir="$CACHE" -servername "$SERVER_NAME" -adminpassword "$SERVER_ADMIN_PASSWORD" -nosteam \
        -debuglog=Mod,Lua < "$fifo" > "$CACHE/stdout.txt" 2>&1) &
    SERVER_PID=$!
    # Opening the FIFO waits for the server's end to open too; once both are open it can go. The
    # server never acts on the end of its input (GameServer.launchCommandHandler waits for input
    # forever), so it can outlive this script.
    exec 3>"$fifo"
    rm -f "$fifo"
    SERVER_CONSOLE=1 SERVER_QUIT=
}

server_started() {
    grep -q "SERVER STARTED" "$SERVER_LOG" 2>/dev/null
}

# Asks the server to save and exit, through its console if this script started it.
quit_server() {
    if [ -n "${SERVER_CONSOLE:-}" ] && [ -z "${SERVER_QUIT:-}" ]; then
        echo quit >&3 2>/dev/null || true
        SERVER_QUIT=1
    fi
}

# Stops the server and waits until it has exited: quit_server, then a signal if it is still up
# after a grace period. A signal alone also saves and exits (GameServer's shutdownHook), for a server
# without a console, such as one kept by --stay.
stop_server() {
    local waited=0
    if [ -n "${SERVER_CONSOLE:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        quit_server
        while kill -0 "$SERVER_PID" 2>/dev/null && [ "$waited" -lt 120 ]; do
            sleep 0.5
            waited=$((waited + 1))
        done
    fi
    stop_pid "$SERVER_PID"
    if [ -n "${SERVER_CONSOLE:-}" ]; then
        exec 3>&-
        SERVER_CONSOLE=
    fi
}

# Prints, with line numbers, the lines of server log $1 that are the mod's problems: a Lua stack
# trace through the mod, or a line matching the conf's SERVER_PROBLEMS that doesn't match
# SERVER_IGNORE, or one matching the extended regex $2 if given. Fails if there are none.
server_problems() {
    grep -n -E "$MOD_ERROR${SERVER_PROBLEMS:+|$SERVER_PROBLEMS}${2:+|$2}" "$1" \
        | { if [ -n "${SERVER_IGNORE:-}" ]; then grep -v -E "$SERVER_IGNORE"; else cat; fi; }
}
