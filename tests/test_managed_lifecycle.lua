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
    lu.assertEquals(#boot.callbacks.wraps, 5)
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

function TestManagedLifecycle.testManagedHooksForceAndObserveOneCompiledDoorBatch()
    local route = {
        routeKey = "Underworld",
        entryInstructionId = "entry",
        biomes = { { biomeKey = "F", entryInstructionId = "entry", completionInstructionIds = {} } },
        instructions = {},
    }
    local entry = { id = "entry", kind = "authored", gameName = "F_Opening01", origin = { biomeKey = "F" } }
    local target = { id = "target", kind = "authored", gameName = "F_Combat02", origin = { biomeKey = "F" } }
    local leaf = { id = "leaf", kind = "authored", gameName = "F_Combat03", origin = { biomeKey = "F" } }
    local batch = {
        id = "batch", kind = "batch", parent = { instructionId = "entry" }, targets = {
            {
                exit = { exitKey = "exit1", index = 1, type = "TestDoor", behavior = "playerSelected" },
                room = { instructionId = "target" }, picked = true, continuation = "continuesSpine",
            },
            {
                exit = { exitKey = "exit2", index = 2, type = "TestDoor", behavior = "playerSelected" },
                room = { instructionId = "leaf" }, picked = false, continuation = "deadLeaf",
            },
        }, selectedContinuation = { kind = "normal", exitKey = "exit1", instructionId = "target" },
    }
    route.instructions = { entry, target, leaf, batch }
    local state = {
        initialized = true, state = "active", routeKey = "Underworld", cursor = "entry", program = route,
        instructionById = { entry = entry, target = target, leaf = leaf, batch = batch },
        batchByParent = { entry = batch },
        biomeByKey = { F = route.biomes[1] }, biomeIndexByKey = { F = 1 }, context = {},
    }
    local boot, currentRun = bootWithState(state)
    local game = boot.env.rom.game
    game.RoomData = {
        F_Opening01 = { Name = "F_Opening01" }, F_Combat02 = { Name = "F_Combat02" },
        F_Combat03 = { Name = "F_Combat03" },
    }
    game.CreateRoom = function(roomData) return { Name = roomData.Name } end
    local vanillaCalls = 0
    game.ChooseStartingRoom = function()
        vanillaCalls = vanillaCalls + 1
        return { Name = "VanillaStart" }
    end
    game.ChooseNextRoomData = function()
        vanillaCalls = vanillaCalls + 1
        return { Name = "VanillaNext" }
    end
    game.LeaveRoom = function(_, door) return door end
    createReplacement(boot, { count = 0 })

    local starting = game.ChooseStartingRoom(currentRun, { StartingBiome = "F" })
    lu.assertEquals(starting.Name, "F_Opening01")
    local doors = { { Name = "TestDoor" }, { Name = "TestDoor" } }
    local generated = game.ChooseNextRoomData(currentRun, {}, doors)
    lu.assertEquals(generated.__runPlannerInstructionId, "target")
    doors[1].Room = generated
    local leafRoom = game.ChooseNextRoomData(currentRun, {}, doors)
    doors[2].Room = leafRoom
    lu.assertEquals(leafRoom.__runPlannerInstructionId, "leaf")
    game.LeaveRoom(currentRun, doors[1])
    lu.assertEquals(state.cursor, "target")
    lu.assertEquals(vanillaCalls, 0)
end

function TestManagedLifecycle.testManagedAutomaticHostAndCompletionAdvanceOnlyAtStartRoom()
    local entry = { id = "entry", kind = "authored", gameName = "F_Opening01", origin = { biomeKey = "F" } }
    local preboss = { id = "preboss", kind = "authored", gameName = "F_PreBoss01", origin = { biomeKey = "F" } }
    local boss = { id = "boss", kind = "completion", gameName = "F_Boss01", origin = { biomeKey = "F" } }
    local batch = {
        id = "batch", kind = "batch", parent = { instructionId = "entry" }, targets = {
            {
                exit = { exitKey = "exit1", index = 1, type = "TestDoor", behavior = "automaticHostContinuation" },
                room = { instructionId = "preboss" }, picked = true, continuation = "startsCompletion",
            },
        }, selectedContinuation = { kind = "normal", exitKey = "exit1", instructionId = "preboss" },
    }
    local route = {
        routeKey = "Underworld", entryInstructionId = "entry", instructions = { entry, preboss, boss, batch },
        biomes = { { biomeKey = "F", entryInstructionId = "entry", completionInstructionIds = { "boss" } } },
    }
    local state = {
        initialized = true, state = "active", routeKey = "Underworld", cursor = "entry", program = route,
        instructionById = { entry = entry, preboss = preboss, boss = boss, batch = batch },
        batchByParent = { entry = batch }, biomeByKey = { F = route.biomes[1] },
        biomeIndexByKey = { F = 1 }, context = {},
    }
    local boot, currentRun = bootWithState(state)
    local game = boot.env.rom.game
    game.RoomData = {
        F_Opening01 = { Name = "F_Opening01" }, F_PreBoss01 = { Name = "F_PreBoss01" },
        F_Boss01 = { Name = "F_Boss01" },
    }
    game.CreateRoom = function(roomData) return { Name = roomData.Name } end
    game.ChooseNextRoomData = function() error("automatic target must be executor-owned") end
    game.LeaveRoom = function(_, door) return door end
    createReplacement(boot, { count = 0 })
    local door = { Name = "TestDoor" }
    door.Room = game.ChooseNextRoomData(currentRun, {}, { door })
    game.LeaveRoom(currentRun, door)
    lu.assertEquals(state.cursor, "entry")
    currentRun.CurrentRoom = door.Room
    game.StartRoom(currentRun, door.Room)
    lu.assertEquals(state.cursor, "preboss")
    local completionDoor = { Name = "AutomaticDoor", Room = { Name = "F_Boss01" } }
    game.LeaveRoom(currentRun, completionDoor)
    currentRun.CurrentRoom = completionDoor.Room
    game.StartRoom(currentRun, completionDoor.Room)
    lu.assertEquals(state.cursor, "boss")
end

return TestManagedLifecycle
