require "PZHarness/TestWorld"
require "PZHarness/TestReads"

-- Development only, not published. The job kit (server/PZHarness/ServerJobs.lua): a job of the
-- mod's job action (the `jobAction` test setting) done on the authority by the server's character,
-- as the server does the one a client's action asks for, to see the authority refuse on its own
-- what a menu would have greyed out, or what a job leaves in the same call.
local T = PZHarness.Test

-- A job's `with` as the server's handler takes it (T.job).
local function plainWith(with)
    if type(with) == "table" and with.kind and with.x then
        return T.at(with, { feature = with.kind })
    end
    return with
end

--- Queues the job `job` of `feature` at its target on `at` (a handle, square or { x, y, z }), done
--- on the authority by the server's character (PZHarness.job). `with` is what the job works with:
--- a name or slot as it is; an item the server finds, { type, inTarget } (carried, or in the
--- target's container) or { id }; or a fixture handle with a `kind`, that feature's target at its
--- place. So the call needs no earlier answer and can go out in a T.batch. `opts`: `via` "job" (the
--- default: as complete() does it once the character is at the job) or "complete" (the action
--- built and completed, its keeps() and reach included); `build`, only whether the action builds;
--- `floor`, the job at the square's floor rather than the topmost target; `targetOf`, the target
--- found as that feature's, for a job the action must turn down (a feature it has none of); `xp`,
--- perk names whose XP to read before and after; `reads` ({ [label] = { name = handler, args } }),
--- read before and after in the same call. The answer { ok, reason, built, xpBefore, xpAfter,
--- before, after } lands in self.server["PZHarness.job"] and, given `label`, self.reads[label].
function T.job(self, feature, job, at, with, label, opts)
    opts = opts or {}
    T.read(self, "PZHarness.job", { feature = feature, job = job, at = T.at(at), with = plainWith(with), via = opts.via,
        build = opts.build, floor = opts.floor, targetOf = opts.targetOf, xp = opts.xp, reads = opts.reads }, label)
end

--- Checks that the answer `answer` ({ ok, reason }) succeeded: "`what` failed (reason)" if not.
function T.expectOk(answer, what)
    return T.expect(answer ~= nil and answer.ok == true, what .. " failed (" .. tostring(answer and answer.reason) .. ")")
end

--- Checks that the answer `answer` was refused for `reason`: "`what` (reason)" if not.
function T.expectRefused(answer, reason, what)
    local got = answer and answer.reason
    return T.expect(answer ~= nil and answer.ok ~= true and got == reason, what .. " (" .. tostring(got) .. ")")
end

return T
