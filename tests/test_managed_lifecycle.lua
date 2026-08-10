-- luacheck: globals TestManagedLifecycle

local lu = require("luaunit")
local data = require("mods/data")
local session = require("mods/session")
local bootHarness = dofile("../../adamant-ModpackLib/tests/harness/plugin_boot_harness.lua")

TestManagedLifecycle = {}

local PLUGIN_GUID = "adamantRunPlanner-Plan_Executor-lifecycle-test"
local MODULE_ID = "Plan_Executor_Lifecycle_Test"

local function cacheState(currentRun)
    return currentRun._AdamantModpackLibCache[PLUGIN_GUID]["execution-session"]
end

local function recordFor(boot, module)
    return boot:getRuntimeRegistry().modules.records[module]
end

local function createReplacement(boot, reads)
    local module = assert(boot.lib.createModule({
        pluginGuid = PLUGIN_GUID,
        modpack = "run-planner",
        id = MODULE_ID,
        name = MODULE_ID,
    }))
    module.data.define({})
    module.status.define(data.buildStatus())
    module.ui.tab(function() end)
    session.defineCache(module)
    session.registerLifecycle(module)
    session.registerHooks(module, {
        inbox = { load = function()
            reads.count = reads.count + 1
            error("the lifecycle projection must not read the inbox")
        end },
        game = boot.env.rom.game,
    })
    local ok, err = module.activate()
    lu.assertTrue(ok, tostring(err))
    return boot:getLiveModule(PLUGIN_GUID)
end

local function bootWithState(state)
    local currentRun = { Revision = "test-revision", CurrentRoom = { RoomSetName = "F", Name = "F_Opening01" } }
    local boot = bootHarness.boot({
        libSrcDir = "../../adamant-ModpackLib/src",
        CurrentRun = currentRun,
        modUtilWrapMode = "functional",
    })
    boot.env.rom.game.StartNewRun = function()
        return currentRun
    end
    boot.env.rom.game.StartRoom = function(_, room)
        return room
    end
    currentRun._AdamantModpackLibCache = {
        [PLUGIN_GUID] = {
            ["execution-session"] = state,
        },
    }
    return boot, currentRun
end

local function sessionLogs(logs)
    local matched = {}
    for _, line in ipairs(logs) do
        if line:find("[" .. MODULE_ID .. "] state=", 1, true) then
            matched[#matched + 1] = line
        end
    end
    return matched
end

local function assertReplacement(state, expectedStatus, expectedLogCount)
    local boot, currentRun = bootWithState(state)
    local logs, reads = {}, { count = 0 }
    boot.env.print = function(line) logs[#logs + 1] = tostring(line) end

    local oldModule = createReplacement(boot, reads)
    local oldRecord = recordFor(boot, oldModule)
    local startDispatcher = boot.env.rom.game.StartNewRun
    lu.assertEquals(cacheState(currentRun), state)
    lu.assertStrContains(oldRecord.runtime.status.read("ExecutionSessionStatus"), expectedStatus)
    lu.assertEquals(#sessionLogs(logs), expectedLogCount)

    local newModule = createReplacement(boot, reads)
    local newRecord = recordFor(boot, newModule)
    lu.assertEquals(boot:getLiveModule(PLUGIN_GUID), newModule)
    lu.assertEquals(cacheState(currentRun), state)
    lu.assertEquals(boot.env.rom.game.StartNewRun, startDispatcher)
    lu.assertEquals(#boot.callbacks.wraps, 2)
    lu.assertEquals(#oldRecord.effectReceipts, 0)
    lu.assertStrContains(newRecord.runtime.status.read("ExecutionSessionStatus"), expectedStatus)
    lu.assertEquals(reads.count, 0)
    lu.assertEquals(#sessionLogs(logs), expectedLogCount)
    return boot, currentRun, reads, logs
end

function TestManagedLifecycle.testActualManagedReplacementReprojectsActiveCacheAndRetiresOldHooks()
    local state = {
        initialized = true,
        state = "active",
        reason = nil,
        routeKey = "Underworld",
        cursor = "f-entry",
        startingRoomObserved = true,
        context = { startingBiome = "F", roomSetName = "F", roomName = "F_Opening01" },
    }
    local boot, currentRun, reads, logs = assertReplacement(state, "state=active", 1)
    local result = boot.env.rom.game.StartNewRun(nil, { StartingBiome = "F" })
    lu.assertEquals(result, currentRun)
    lu.assertEquals(reads.count, 0)
    lu.assertEquals(#sessionLogs(logs), 1)
end

function TestManagedLifecycle.testActualManagedReplacementReprojectsInactiveCacheWithoutReread()
    assertReplacement({
        initialized = true,
        state = "inactive",
        reason = "dream-run",
        context = { gameVersion = "test-revision" },
    }, "state=inactive reason=dream-run", 1)
end

function TestManagedLifecycle.testActualManagedReplacementLeavesUninitializedCacheUnprojected()
    local state = { initialized = false, state = "inactive", reason = "not-started", context = {} }
    local boot, currentRun, reads, logs = assertReplacement(state, "not-started", 0)
    lu.assertEquals(cacheState(currentRun), state)
    lu.assertEquals(reads.count, 0)
    lu.assertEquals(#sessionLogs(logs), 0)
end

return TestManagedLifecycle
