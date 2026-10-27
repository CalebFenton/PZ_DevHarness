-- Development only, not published. The files bin/run-client.sh and the harness Lua talk through, in
-- <cachedir>/Lua: the run it asked for (PZHarness.txt, read once at load into PZHarness.run), a
-- --stay rerun request, the --mp server to join, and the tests' files, which the script reads back
-- for the suspects of a failure.

PZHarness = PZHarness or {}
local Run = {}

-- With --stay, run-client.sh writes this to rerun the tests; with --mp this once the server has
-- started, while the client waits at the main menu.
local REQUEST_FILE = "PZHarnessRerun.txt"
Run.CONNECT_FILE = "PZHarnessConnect.txt"
-- "<test>\t<file>" for every test of the mod, written as a run starts (Run.writeTestFiles).
local TEST_FILES_FILE = "PZHarnessTests.txt"

--- The key=value lines of <cachedir>/Lua/<name>, or nil without the file.
function Run.readKeys(name)
    local reader = getFileReader(name, false)
    if not reader then
        return nil
    end
    local keys = {}
    local line = reader:readLine()
    while line do
        local key, value = string.match(line, "^(%w+)=(.*)$")
        if key then
            keys[key] = value
        end
        line = reader:readLine()
    end
    reader:close()
    return keys
end

-- The run run-client.sh asked for: mode, selection, stay, mp, console mark and tag, the test
-- options and the --test world's sandbox options (`quiet`). Without the file, as in a game the
-- script didn't start, there is no mode and the tests print under a generic tag.
local function readRun()
    local run = { mode = "", selection = "", stay = false, mp = false, mark = "PZHarness", tag = "PZHarness" }
    for key, value in pairs(Run.readKeys("PZHarness.txt") or {}) do
        if key == "stay" or key == "mp" then
            run[key] = value ~= ""
        else
            run[key] = value
        end
    end
    return run
end

PZHarness.run = readRun()

-- What the dev mod registered; see PZHarness.register (Runner.lua).
PZHarness.config = PZHarness.config or { prefix = "", modes = {} }

--- The request run-client.sh writes to REQUEST_FILE: an id, the selection, "option <key>=<value>"
--- lines, then the Lua files to reload in load order (with --mp, "server "-prefixed server paths
--- too). Nil if there is none.
function Run.readRequest()
    local reader = getFileReader(REQUEST_FILE, false)
    if not reader then
        return nil
    end
    local request = { id = reader:readLine(), tests = reader:readLine(), options = {}, files = {}, serverFiles = {} }
    local line = reader:readLine()
    while line do
        local key, value = string.match(line, "^option (%w+)=(.*)$")
        local serverFile = string.match(line, "^server (.*)$")
        if key then
            request.options[key] = value
        else
            table.insert(serverFile and request.serverFiles or request.files, serverFile or line)
        end
        line = reader:readLine()
    end
    reader:close()
    return request
end

--- Writes the file that registered each test of `tests` (TimedActionTests entries by name) whose
--- name starts with the mod's prefix, which the script's suspects of a failure match '@<file>'
--- selections against.
function Run.writeTestFiles(tests)
    local writer = getFileWriter(TEST_FILES_FILE, true, false)
    for name, entry in pairs(tests) do
        if luautils.stringStarts(name, PZHarness.config.prefix) then
            writer:writeln(name .. "\t" .. tostring(entry.file or ""))
        end
    end
    writer:close()
end

return Run
