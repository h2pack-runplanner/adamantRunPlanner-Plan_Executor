-- ShipCombat adapter witnesses: exact phase count, full wheel cohort, and a
-- non-blocking divergent player choice.
-- luacheck: globals TestThessaly
local lu = require("luaunit")
local thessaly = require("mods.room.timeline.encounters.thessaly")
local navigation = require("mods.navigation.hooks")
local acquisitionBinding = require("mods.room.timeline.acquisitions.binding")
local directPickups = require("mods.room.timeline.acquisitions.pickups.hooks")
local timelineBindings = require("mods.room.timeline.bindings")

TestThessaly = {}

function TestThessaly.testIndexesSelectedWheelAcquisitionByItsExactWheel()
    local transaction = {
        kind = "acquisition", owner = "picked", sourceOwner = "picked",
        reward = { rewardType = "MaxHealthDrop", producerLifecycleKey = "RoomReward" },
        producerLifecycleKey = "RoomReward", roles = {},
        window = { kind = "shipPostCombat", wheelKey = "wheel2" },
    }
    local index = assert(timelineBindings.index({ transactionsByOwner = { picked = transaction } }))
    local row = assert(timelineBindings.resolve(index, {
        kind = "rewardWheelAcquisition", wheelKey = "wheel2",
    }))
    lu.assertEquals(row.transaction, transaction)
    lu.assertNil(timelineBindings.resolve(index, {
        kind = "rewardWheelAcquisition", wheelKey = "wheel1",
    }))
end

local function capture()
    local callbacks = {}
    return {
        hooks = { wrap = function(name, _, callback) callbacks[name] = callback end },
    }, callbacks
end

local function fixture(offerCount, pickedOfferKey)
    local phase = { slotKey = "Combat1", encounterKey = "ShipEncounter" }
    local offers = {
        {
            offerKey = "offer1",
            reward = { rewardType = "ZeusUpgrade", source = "Zeus", producerLifecycleKey = "wheel1" },
        },
        {
            offerKey = "offer2",
            reward = { rewardType = "MaxHealthDrop", producerLifecycleKey = "wheel1" },
        },
    }
    while #offers > offerCount do table.remove(offers) end
    local wheel = {
        wheelKey = "wheel1", phaseKey = "Combat1", phaseOwner = "phase-owner",
        offerCount = offerCount, storeKey = "RunProgress", offers = offers,
        pickedOfferKey = pickedOfferKey,
    }
    local active = { occurrence = { overview = {
        encounterPhases = { { slotKey = "Intro" }, phase }, rewardWheels = { wheel },
    } } }
    return active, phase, wheel
end

function TestThessaly.testExactPublishedPhaseCountBypassesNativeThirdPhaseRoll()
    for _, expectedCount in ipairs({ 2, 3 }) do
        local active = fixture(1, "offer1")
        active.occurrence.overview.encounterPhases = {
            { slotKey = "Intro" }, { slotKey = "Combat1" },
        }
        if expectedCount == 3 then
            active.occurrence.overview.encounterPhases[3] = { slotKey = "Combat2" }
        end
        local state = { state = "synchronized" }
        local nativeRoom = { MultipleEncountersData = { {}, {}, {
            GameStateRequirements = { ChanceToPlay = 0.6 },
        } } }
        local room = {
            encounterAt = function(_, index, destination)
                lu.assertEquals(destination, nativeRoom)
                return active.occurrence.overview.encounterPhases[index]
            end,
        }
        local shipCombat = thessaly.create()
        local third = nativeRoom.MultipleEncountersData[3]
        local restore = shipCombat.preparePhases(state, room, nativeRoom)
        local observed = #nativeRoom.MultipleEncountersData
        if expectedCount == 3 then
            lu.assertNil(nativeRoom.MultipleEncountersData[3].GameStateRequirements)
        end
        restore()
        lu.assertEquals(observed, expectedCount)
        lu.assertEquals(nativeRoom.MultipleEncountersData[3], third)
        lu.assertEquals(third.GameStateRequirements, { ChanceToPlay = 0.6 })
    end
end

local function runWheel(offerCount, pickedOfferKey, selectedIndex)
    local module, callbacks = capture()
    local active, phase, wheel = fixture(offerCount, pickedOfferKey)
    local state = { state = "synchronized" }
    local nativeEncounter = {}
    local windows, completed, mismatches = {}, {}, {}
    local handle = {}
    local room = {
        current = function() return active end,
        encounterPhase = function(_, value) return value == nativeEncounter and phase or nil end,
        window = function(_, value) windows[#windows + 1] = value; return true end,
        resolve = function(_, context, contact)
            lu.assertEquals(context, active)
            lu.assertEquals(contact, { kind = "rewardWheel", wheelKey = "wheel1" })
            return handle
        end,
        bind = function(_, context, value, native)
            lu.assertEquals(context, active)
            lu.assertEquals(value, handle)
            lu.assertNotNil(native)
            return handle
        end,
        begin = function(_, value)
            lu.assertEquals(value, handle)
            return { transaction = { pickedOfferKey = wheel.pickedOfferKey } }
        end,
    }
    local session = {
        complete = function(_, value) completed[#completed + 1] = value end,
        mismatch = function(_, checkpoint, expected, observed)
            mismatches[#mismatches + 1] = { checkpoint, expected, observed }
            state.state = "desynchronized"
        end,
    }
    local shipCombat = thessaly.create()
    navigation.attach(module, session, function() return state end, function() end, {}, room, nil,
        shipCombat.rewardContext)
    shipCombat.attach(module, session, function() return state end, function() end, room)

    local nativeRoom = { Encounter = nativeEncounter }
    local obstacles = {}
    local chosenRewards = {}
    local selected
    local result = callbacks.ShipsEncounterSetup(nil, {}, function()
        lu.assertEquals(callbacks.RandomChance(nil, {}, function() return false end, 0.25), offerCount == 2)
        lu.assertEquals(callbacks.ChooseNextRewardStore(nil, {}, function() return "MetaProgress" end, {}),
            "RunProgress")
        for index = 1, offerCount do
            local rewardType = callbacks.ChooseRoomReward(nil, {}, function() return "wrong" end,
                {}, nativeRoom, "MetaProgress", chosenRewards, { IgnoreForcedReward = true })
            chosenRewards[index] = rewardType
            callbacks.SetupRoomReward(nil, {}, function()
                nativeRoom.ForceLootName = "wrong-source"
                return true
            end, {}, nativeRoom, {}, { AlwaysSetupForceLootName = true })
            local obstacle = {}
            obstacles[index] = obstacle
            callbacks.CreateDoorRewardPreview(nil, {}, function() return true end, obstacle, rewardType)
        end
        selected = obstacles[selectedIndex]
        callbacks.UseShipWheel(nil, {}, function(value) return value end, selected)
        return "native-result"
    end, nativeEncounter, {})
    return {
        result = result, chosenRewards = chosenRewards, obstacles = obstacles,
        selected = selected, windows = windows, completed = completed, mismatches = mismatches,
    }
end

function TestThessaly.testForcesOneAndTwoOfferWheelCohortsAndCompletesExactChoice()
    local one = runWheel(1, "offer1", 1)
    lu.assertEquals(one.result, "native-result")
    lu.assertEquals(one.chosenRewards, { "ZeusUpgrade" })
    lu.assertEquals(one.obstacles[1].__runPlannerOfferKey, "offer1")
    lu.assertEquals(one.windows, { "shipPreCombat:wheel1", "shipPostCombat:wheel1" })
    lu.assertEquals(#one.completed, 1)
    lu.assertEquals(one.mismatches, {})

    local two = runWheel(2, "offer2", 2)
    lu.assertEquals(two.chosenRewards, { "ZeusUpgrade", "MaxHealthDrop" })
    lu.assertEquals(two.obstacles[2].__runPlannerOfferKey, "offer2")
    lu.assertEquals(#two.completed, 1)
    lu.assertEquals(two.mismatches, {})
end

function TestThessaly.testDivergentWheelChoiceDoesNotBlockNativeUse()
    local result = runWheel(2, "offer2", 1)
    lu.assertEquals(result.selected, result.obstacles[1])
    lu.assertEquals(result.completed, {})
    lu.assertEquals(result.mismatches, { { "ship-wheel-selection", "offer2", "offer1" } })
end

function TestThessaly.testSelectedWheelRewardBindsAndCompletesThroughStandardPickupLifecycle()
    local module, callbacks = capture()
    local active, phase, wheel = fixture(1, "offer1")
    wheel.offers[1].reward = { rewardType = "MaxHealthDrop", producerLifecycleKey = "RoomReward" }
    local state = { state = "synchronized" }
    local encounter, choiceHandle, pickupHandle = {}, {}, {}
    local nativeBindings, completed = {}, {}
    local choicePayload = { transaction = {
        kind = "chooseRewardWheel", pickedOfferKey = "offer1",
    } }
    local pickupRole = {
        role = "self", disposition = "normal", lifecyclePoint = "roomRewardPickup",
        kind = "consumable", gameName = "MaxHealthDrop",
    }
    local pickupPayload = { transaction = {
        kind = "acquisition", roles = { pickupRole },
    }, detail = pickupRole }
    local room = {
        current = function() return active end,
        encounterPhase = function(_, native) return native == encounter and phase or nil end,
        window = function() return true end,
        resolve = function(_, context, contact)
            lu.assertEquals(context, active)
            if contact.kind == "rewardWheel" then return choiceHandle end
            if contact.kind == "rewardWheelAcquisition" then
                lu.assertEquals(contact.wheelKey, "wheel1")
                return pickupHandle
            end
            if contact.kind == "materialized" then
                lu.assertEquals(contact.source, pickupHandle)
                lu.assertEquals(contact.gameName, "MaxHealthDrop")
                return pickupHandle
            end
        end,
        bind = function(_, context, handle, native)
            lu.assertEquals(context, active)
            nativeBindings[native] = handle
            return handle
        end,
        bound = function(_, context, native)
            lu.assertEquals(context, active)
            return nativeBindings[native]
        end,
        begin = function(_, handle)
            return handle == choiceHandle and choicePayload or pickupPayload
        end,
        peek = function(_, handle)
            return handle == pickupHandle and pickupPayload or choicePayload
        end,
        releaseCompletedBinding = function() return true end,
    }
    local session = {
        complete = function(_, handle) completed[#completed + 1] = handle; return true end,
        mismatch = function() error("unexpected mismatch") end,
    }
    local shipCombat = thessaly.create()
    navigation.attach(module, session, function() return state end, function() end, {}, room, nil,
        shipCombat.rewardContext)
    shipCombat.attach(module, session, function() return state end, function() end, room)
    acquisitionBinding.attach(module, session, function() return state end, function() end, room,
        shipCombat.takeRewardProducer)
    directPickups.attach(module, session, function() return state end, function() end, room, {
        scope = function() return {} end,
        call = function(_, callback) return callback() end,
        activate = function() end,
        requireConsumed = function() return true end,
    })

    local wheelObstacle = {}
    callbacks.ShipsEncounterSetup(nil, {}, function()
        callbacks.RandomChance(nil, {}, function() return false end, 1)
        callbacks.ChooseNextRewardStore(nil, {}, function() return "wrong" end, {})
        local rewardType = callbacks.ChooseRoomReward(nil, {}, function() return "wrong" end,
            {}, { Encounter = encounter }, "RunProgress", {}, { IgnoreForcedReward = true })
        callbacks.CreateDoorRewardPreview(nil, {}, function() end, wheelObstacle, rewardType)
        callbacks.UseShipWheel(nil, {}, function() return true end, wheelObstacle)
    end, encounter, {})
    local pickup = callbacks.SpawnRoomReward(nil, {}, function()
        return callbacks.CreateConsumableItem(nil, {}, function()
            return { Name = "MaxHealthDrop" }
        end, {})
    end, {}, {})
    callbacks.UseConsumableItem(nil, {}, function(item)
        callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, item, {})
        return true
    end, pickup, {}, {})

    lu.assertEquals(completed, { choiceHandle, pickupHandle })
    lu.assertNil(shipCombat.takeRewardProducer(state, active))
end
