-- Gate-B execution session.
--
-- The planner owns the frozen, occurrence-addressed program. This module is a
-- thin compiler/observer: it realizes room copies and physical door peers at
-- their vanilla seams, then records the first mismatch without repairing the
-- run or finding a replacement instruction.

local session = {}
session.CACHE_NAME = "ExecutionSession"
session.BIOME_ROUTE = { F = "Underworld", G = "Underworld" }
local expectedRoom
local nextTrace
local plannedRoleFor
local consumeTraceStep
local mismatch

local function newState()
    return {
        initialized = false, state = "inactive", reason = "not-started",
        plan = nil, roomsById = {}, currentRoomId = nil, generation = nil,
        firstMismatch = nil, roomObserved = false, rewardObserved = false,
        diagnostics = {}, pendingExit = nil,
        encounterPhase = nil,
        -- The frozen trace is ordered data.  Keep one cursor instead of
        -- rediscovering the next lifecycle action from the live room.
        traceCursor = nil,
        lastConfirmedAction = nil,
        -- Runtime identities are intentionally ephemeral.  The published plan
        -- contains only semantic offer keys; object and kit ids never escape
        -- this active session.
        shopItemsByObjectId = {}, shopItemsByKitId = {},
    }
end

local function shopContents(state)
    local room = expectedRoom(state)
    return room and room.contents and room.contents.shop or nil
end

local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, entry in pairs(value) do copy[key] = deepCopy(entry) end
    return copy
end

local function retained(values, expected)
    local result = {}
    for _, value in pairs(values or {}) do
        local key = type(value) == "table" and value.Name or value
        if key == expected then result[#result + 1] = value end
    end
    return result
end

local function retainedAny(values, expected)
    local result = {}
    for _, value in pairs(values or {}) do
        local key = type(value) == "table" and value.Name or value
        if expected[key] then result[#result + 1] = value end
    end
    return result
end

local function inventoryArgs(args, storeData)
    local copy = deepCopy(args or {})
    copy.StoreData = storeData
    return copy
end

-- Selection is constrained before FillInShopOptions constructs records.  This
-- preserves vanilla's costs, types, and payload assembly; it never filters a
-- finished inventory after a different legal roll was already committed.
function session.prepareInventoryGeneration(state, args, refillOnly)
    if state.state ~= "synchronized" then return { kind = "passThrough", args = args } end
    local room = expectedRoom(state)
    local shop = room and room.contents and room.contents.shop or nil
    local well = room and room.contents and room.contents.stygianWell or nil
    if refillOnly and shop and shop.travelDealRefill then
        local refill = state.pendingTravelDealRefill
        if refill == nil then return { kind = "passThrough", args = args } end
        local storeData = deepCopy((args or {}).StoreData)
        local group = storeData and storeData.GroupsOf and storeData.GroupsOf[refill.slotIndex + 1]
        if group == nil then
            mismatch(state, "travel-deal-refill", { kind = "slot", index = refill.slotIndex }, { kind = "slot", index = nil })
            return { kind = "failed", args = args }
        end
        if group.OptionsData then group.OptionsData = retained(group.OptionsData, refill.optionKey) end
        if group.Options then group.Options = retained(group.Options, refill.optionKey) end
        return { kind = "handled", family = "worldShopRefill", refill = refill, args = inventoryArgs(args, storeData), sources = { refill.reward.source } }
    end
    if shop ~= nil then
        local storeData = deepCopy((args or {}).StoreData)
        if type(storeData) ~= "table" or type(storeData.GroupsOf) ~= "table" then return { kind = "passThrough", args = args } end
        for index, offer in ipairs(shop.offers or {}) do
            local group = storeData.GroupsOf[index]
            if group == nil then
                mismatch(state, "world-shop-options", { kind = "slot", index = index - 1 }, { kind = "slot", index = nil })
                return { kind = "failed", args = args }
            end
            if group.OptionsData then group.OptionsData = retained(group.OptionsData, offer.optionKey) end
            if group.Options then group.Options = retained(group.Options, offer.optionKey) end
        end
        local sources = {}
        for _, offer in ipairs(shop.offers or {}) do if offer.source ~= nil then sources[#sources + 1] = offer.source end end
        return { kind = "handled", family = "worldShop", shop = shop, args = inventoryArgs(args, storeData), sources = sources }
    end
    if well ~= nil then
        local initial = {}
        for _, offer in ipairs(well.offers or {}) do
            if offer.generationKey ~= "travelDealRefill" then initial[offer.generationKey] = offer end
        end
        local healing, left, right = initial["initial:healing"], initial["initial:secondLeft"], initial["initial:secondRight"]
        if healing == nil or left == nil or right == nil then
            mismatch(state, "stygian-well-options", { kind = "initialInventory" }, { kind = "missing" })
            return { kind = "failed", args = args }
        end
        local storeData = deepCopy((args or {}).StoreData)
        if type(storeData) ~= "table" then return { kind = "passThrough", args = args } end
        if storeData.HealingOffers and storeData.HealingOffers.WeightedList then
            storeData.HealingOffers.WeightedList = retained(storeData.HealingOffers.WeightedList, healing.offerKey)
        end
        local otherKeys = { [left.offerKey] = true, [right.offerKey] = true }
        storeData.Traits = retainedAny(storeData.Traits, otherKeys)
        storeData.Consumables = retainedAny(storeData.Consumables, otherKeys)
        return { kind = "handled", family = "stygianWell", well = well, args = inventoryArgs(args, storeData), sources = {} }
    end
    return { kind = "passThrough", args = args }
end

function session.chooseInventoryGod(_, generation)
    if generation == nil or type(generation.sources) ~= "table" then return nil end
    local source = generation.sources[1]
    if type(source) ~= "string" then return nil end
    table.remove(generation.sources, 1)
    return source
end

-- The native builder owns eligibility and option records.  Its fixed Traits
-- then Consumables emission does not represent the Well's two physical slots,
-- so sequence the already-native selected records before its caller consumes
-- the generated inventory.
function session.orderWellInventoryGeneration(generation, store)
    if generation == nil or generation.kind ~= "handled" or generation.family ~= "stygianWell" then return store end
    if type(store) ~= "table" or type(store.StoreOptions) ~= "table" then return store end
    local byName = {}
    for _, option in ipairs(store.StoreOptions) do
        local key = type(option) == "table" and (option.Name or option.ItemName) or nil
        if type(key) == "string" then
            if byName[key] ~= nil then return store end
            byName[key] = option
        end
    end
    local offers = {}
    for _, offer in ipairs(generation.well.offers or {}) do offers[offer.generationKey] = offer end
    local ordered = {}
    for _, generationKey in ipairs({ "initial:healing", "initial:secondLeft", "initial:secondRight" }) do
        local option = offers[generationKey] and byName[offers[generationKey].offerKey]
        if option == nil then return store end
        ordered[#ordered + 1] = option
    end
    store.StoreOptions = ordered
    return store
end

function session.verifyInventoryGeneration(state, generation, store)
    if generation == nil or generation.kind ~= "handled" then return generation end
    if type(store) ~= "table" or type(store.StoreOptions) ~= "table" then
        mismatch(state, "inventory-generation", { kind = generation.family }, { kind = "missing" })
        return { kind = "failed" }
    end
    local expected = generation.family == "stygianWell" and (function()
        local initial = {}
        for _, offer in ipairs(generation.well.offers or {}) do
            if offer.generationKey ~= "travelDealRefill" then initial[#initial + 1] = offer end
        end
        return initial
    end)()
        or generation.family == "worldShopRefill" and { generation.refill }
        or generation.shop.offers
    local offset = generation.family == "worldShopRefill" and generation.refill.slotIndex or 0
    for index, offer in ipairs(expected or {}) do
        local option = store.StoreOptions[index + offset]
        local key = type(option) == "table" and (option.Name or option.ItemName) or nil
        local optionKey = generation.family == "stygianWell" and offer.offerKey or offer.optionKey
        if key ~= optionKey then
            mismatch(state, "inventory-generation", { kind = "option", key = optionKey }, { kind = "option", key = key })
            return { kind = "failed" }
        end
        if offer.source ~= nil or (offer.reward and offer.reward.source ~= nil) then
            local source = offer.source or offer.reward.source
            local observed = option.Args and option.Args.ForceLootName or nil
            if observed ~= source then
                mismatch(state, "inventory-generation", { kind = "source", key = source }, { kind = "source", key = observed })
                return { kind = "failed" }
            end
        end
        option.__runPlannerShopOfferKey = offer.offerKey or generation.refill.sourceOfferKey
        option.__runPlannerShopOptionKey = offer.optionKey or offer.offerKey
        if generation.family == "stygianWell" then
            option.__runPlannerWellGenerationKey, option.__runPlannerTwistResultKey = offer.generationKey, offer.twistResultKey
        end
    end
    return { kind = "handled" }
end

function session.applyPurgingPoolInventory(state, currentRoom)
    if state.state ~= "synchronized" then return { kind = "passThrough" } end
    local room = expectedRoom(state)
    local pool = room and room.contents and room.contents.purgingPool or nil
    -- OpenSellTraitMenu returns nil.  Its native contract is to populate the
    -- current room's SellOptions before it constructs the screen.
    if pool == nil or type(currentRoom) ~= "table" or type(currentRoom.SellOptions) ~= "table" then return { kind = "passThrough" } end
    local available, selected = {}, {}
    for _, option in pairs(currentRoom.SellOptions) do if type(option) == "table" then available[option.Name] = option end end
    for _, slot in ipairs(pool.traits or {}) do
        if slot.traitKey ~= nil then
            local option = available[slot.traitKey]
            if option == nil then
                mismatch(state, "purging-pool-options", { kind = "trait", key = slot.traitKey }, { kind = "trait", key = nil })
                return { kind = "failed" }
            end
            option.__runPlannerPoolSlotKey = slot.slotKey
            selected[#selected + 1] = option
        end
    end
    currentRoom.SellOptions = selected
    return { kind = "handled" }
end

function session.noteWorldShopSpawn(state, itemData, kitId, currentRun)
    if state.state ~= "synchronized" or type(itemData) ~= "table" then return end
    local offerKey = itemData.__runPlannerShopOfferKey
    if type(offerKey) ~= "string" then return end
    local spawned = currentRun and currentRun.CurrentRoom and currentRun.CurrentRoom.Store
        and currentRun.CurrentRoom.Store.SpawnedStoreItems or nil
    if type(spawned) ~= "table" then return end
    for _, entry in pairs(spawned) do
        if type(entry) == "table" and entry.KitId == kitId and entry.ObjectId ~= nil then
            state.shopItemsByObjectId[entry.ObjectId] = offerKey
            state.shopItemsByKitId[kitId] = offerKey
            return
        end
    end
end

function session.beginWorldShopRemoval(state, args)
    if state.state ~= "synchronized" or type(args) ~= "table" then return nil end
    local offerKey = state.shopItemsByObjectId[args.Id]
    local shop = shopContents(state)
    local refill = shop and shop.travelDealRefill or nil
    if offerKey ~= nil and refill ~= nil and refill.sourceOfferKey == offerKey then return refill end
    return nil
end

function session.verifyTravelDealRefillSlot(state, replacedIndex)
    local refill = state.pendingTravelDealRefill
    if state.state ~= "synchronized" or refill == nil then return true end
    local expected = refill.slotIndex + 1 -- native StoreOptions is one-based.
    if replacedIndex ~= expected then
        mismatch(state, "travel-deal-refill", { kind = "slot", index = expected }, { kind = "slot", index = replacedIndex })
        return false
    end
    return true
end

function session.observeWorldShopRemoval(state, args, _)
    if state.state ~= "synchronized" or type(args) ~= "table" then return end
    local offerKey = state.shopItemsByObjectId[args.Id]
    if offerKey == nil then return end
    state.shopItemsByObjectId[args.Id] = nil
    session.observeWorldShopPurchase(state, offerKey)
end

local function bounded(value)
    local text = value == nil and "none" or tostring(value)
    return #text > 128 and text:sub(1, 125) .. "..." or text
end

local function roomName(room)
    return type(room) == "table" and (room.GenusName or room.Name) or nil
end

mismatch = function(state, checkpoint, expected, observed, beforeApply, disposition, triggeringAgency)
    if state.firstMismatch ~= nil then return end
    state.firstMismatch = {
        checkpoint = checkpoint, expected = expected, observed = observed,
        beforeApply = beforeApply ~= false,
        disposition = disposition or "conformanceDiscrepancy",
        triggeringAgency = triggeringAgency or "game",
        lastConfirmedAction = state.lastConfirmedAction,
    }
    state.state, state.reason = "desynchronized", "first-mismatch"
end

local function confirmAction(state, kind, key)
    state.lastConfirmedAction = { kind = kind, key = key }
end

expectedRoom = function(state)
    return state.currentRoomId and state.roomsById[state.currentRoomId] or nil
end

local function copyRoomData(source)
    local copy = {}
    for key, value in pairs(source) do copy[key] = value end
    return copy
end

local function copyArray(values)
    local copy = {}
    for index, value in ipairs(values or {}) do copy[index] = value end
    return copy
end

local function restoreArray(values, copy)
    for index in pairs(values) do values[index] = nil end
    for index, value in ipairs(copy) do values[index] = value end
end

local function rewardName(value)
    return type(value) == "table" and (value.Name or value.RewardType) or value
end

local function sourceExists(game, source)
    if type(source) ~= "string" then return true end
    return type(game) == "table" and type(game.LootData) == "table" and game.LootData[source] ~= nil
end

local function indexPlan(state, plan)
    state.roomsById = {}
    state.producedChildren = {}
    for _, room in ipairs(plan.rooms or {}) do
        state.roomsById[room.id] = room
        for _, step in ipairs(room.trace or {}) do
            if step.kind == "acquireReward" then for _, role in ipairs(step.roles or {}) do
                if role.producer ~= nil then
                    local key = role.producer.sourceOwner .. "\0" .. role.producer.sourceRole
                    state.producedChildren[key] = state.producedChildren[key] or {}
                    table.insert(state.producedChildren[key], { action = step, role = role })
                end
            end end
        end
    end
    state.currentRoomId = plan.rooms[1] and plan.rooms[1].id or nil
end

local function producedChild(state, owner, role, kind)
    local rows = state.producedChildren and state.producedChildren[owner .. "\0" .. role] or nil
    if type(rows) ~= "table" then return nil end
    for _, child in ipairs(rows) do if child.role and child.role.producer and child.role.producer.kind == kind then return child end end
    return nil
end

function session.beginTimePiece(state, usee)
    local _, role = plannedRoleFor(state, type(usee) == "table" and usee.Name or nil)
    if state.state ~= "synchronized" or role == nil or role.disposition ~= "timePiece" then return nil end
    state.pendingTimePiece = { id = usee.ObjectId, role = role }
    return true
end

-- Artificer is a player-triggered replacement.  Its source action is settled
-- by the native gift branch, then the linked child becomes the next trace
-- acquisition which ChooseRoomReward/SpawnRoomReward realize normally.
function session.beginArtificerReplacement(state, target)
    -- ConvertMetaRewardPresentation is reached only after the native Gift
    -- handler accepted a MetaConversionEligible target and deliberately
    -- clears that flag.  Do not use CanReceiveGift: it is also UI polling.
    if state.state ~= "synchronized" or type(target) ~= "table" then return nil end
    local action, role = plannedRoleFor(state, target.Name)
    if action == nil or role == nil or role.disposition ~= "artificer" then return nil end
    local child = producedChild(state, action.sourceOwner, role.role, "artificerReplacement")
    if child == nil then
        mismatch(state, "artificer-child", { kind = "producer", key = target.Name }, { kind = "producer", key = nil })
        return nil
    end
    state.pendingArtificer = { sourceId = target.ObjectId, child = child }
    confirmAction(state, "artificer", target.Name)
    consumeTraceStep(state, "acquireReward")
    return child
end

function session.chooseArtificerReward(state, currentRun, room, game, base, rewardStoreName, previouslyChosenRewards, args)
    local pending = state.pendingArtificer
    if state.state ~= "synchronized" or pending == nil then return { kind = "passThrough" } end
    local child = pending.child
    local action = child and child.action or nil
    if action == nil then return { kind = "passThrough" } end
    return session.chooseRoomRewardFor(state, action.reward, currentRun, room, game, base,
        rewardStoreName, previouslyChosenRewards, args)
end

function session.captureArtificerReplacement(state, args, item)
    local pending = state.pendingArtificer
    if pending == nil then return end
    if type(args) ~= "table" or args.SpawnRewardOnId ~= pending.sourceId then return end
    session.captureProducedChild(state, item, pending.child)
    state.pendingArtificer = nil
end

-- Sea Star leaves native construction in charge.  This only binds the one
-- planned source object to its already-compiled child and verifies that the
-- native nonrecursive guard was applied to that result.
function session.beginSeaStarDuplicate(state, source)
    if state.state ~= "synchronized" or type(source) ~= "table" then return nil end
    local action, role = plannedRoleFor(state, source.Name)
    if action == nil or role == nil then return nil end
    local child = producedChild(state, action.sourceOwner, role.role, "seaStarDuplicate")
    if child == nil then return nil end
    state.pendingSeaStar = { sourceId = source.ObjectId, source = source, child = child }
    -- This is the native gate immediately preceding its own RandomChance;
    -- it does not manufacture a pickup or select any planner alternative.
    source.CanDuplicate = true
    return child
end

function session.consumeSeaStarDuplicateRng(state)
    local pending = state.pendingSeaStar
    if state.state ~= "synchronized" or pending == nil or pending.rngArmed ~= true then return nil end
    pending.rngArmed = nil
    return true
end

function session.armSeaStarDuplicateRng(state)
    local pending = state.pendingSeaStar
    if state.state ~= "synchronized" or pending == nil then return nil end
    pending.rngArmed = true
    return true
end

function session.captureSeaStarDuplicate(state, item)
    local pending = state.pendingSeaStar
    if pending == nil or pending.captured then return end
    session.captureProducedChild(state, item, pending.child)
    if state.state == "synchronized" then
        pending.captured, pending.result = true, item
    end
end

function session.finishSeaStarDuplicate(state, source)
    local pending = state.pendingSeaStar
    if pending == nil then return end
    if source ~= pending.source or type(source) ~= "table" or source.ObjectId ~= pending.sourceId
        or pending.captured ~= true or type(pending.result) ~= "table"
        or pending.result.CanDuplicate ~= false then
        mismatch(state, "sea-star-duplicate", { kind = "nonrecursive", key = pending.child.role.gameName },
            { kind = "nonrecursive", key = pending.result and pending.result.Name or nil }, false)
        return
    end
    state.pendingSeaStar = nil
end
function session.finishTimePiece(state, usee)
    local pending = state.pendingTimePiece
    if pending == nil then return end
    if type(usee) ~= "table" or usee.ObjectId ~= pending.id then
        mismatch(state, "time-piece", { kind = "object", key = pending.id }, { kind = "object", key = usee and usee.ObjectId }, false)
        return
    end
    state.pendingTimePiece = nil
    confirmAction(state, "timePiece", pending.role.gameName)
    consumeTraceStep(state, "acquireReward")
end

function session.prepareProducedChild(state, owner, role, kind)
    local child = producedChild(state, owner, role, kind)
    if child ~= nil then state.pendingProducedChild = child end
    return child
end

-- Echo runs while AddTraitToHero is still resolving the selected source
-- acquisition. Bind that active source role to its explicit child and require
-- the child to be the immediately following trace action; never search a room.
function session.beginEchoLastReward(state)
    if state.state ~= "synchronized" or state.pendingEchoLastReward ~= nil then return nil end
    local source = state.pendingAcquisition
    local sourceAction, sourceRole = source and source.action or nil, source and source.role or nil
    if sourceAction == nil or sourceRole == nil then
        mismatch(state, "echo-last-reward", { kind = "producer", key = "echoLastReward" }, { kind = "producer", key = nil }, false)
        return nil
    end
    local child = producedChild(state, sourceAction.sourceOwner, sourceRole.role, "echoLastReward")
    local room = expectedRoom(state)
    local immediate = room and room.trace and room.trace[(state.traceCursor or 1) + 1] or nil
    if child == nil or child.action ~= immediate then
        mismatch(state, "echo-last-reward", { kind = "producer", key = "immediate-child" }, { kind = "producer", key = nil }, false)
        return nil
    end
    state.pendingEchoLastReward = child
    return state.pendingEchoLastReward
end

function session.captureEchoLastReward(state, item)
    local pending = state.pendingEchoLastReward
    if pending == nil then return end
    session.captureProducedChild(state, item, pending)
    if state.state == "synchronized" then pending.item = item end
end

function session.finishEchoLastReward(state)
    local pending = state.pendingEchoLastReward
    if pending == nil or state.state ~= "synchronized" then return end
    if type(pending.item) ~= "table" then
        mismatch(state, "echo-last-reward", { kind = "pickup", key = pending.role.gameName }, { kind = "pickup", key = nil }, false)
        return
    end
    state.pendingEchoLastReward = nil
end
function session.captureProducedChild(state, item, expectedChild)
    local child = expectedChild or state.pendingProducedChild
    if child == nil then return end
    local name = type(item) == "table" and (item.Name or item.ItemName) or nil
    local role = child.role or child
    if name ~= role.gameName then
        mismatch(state, "produced-pickup", { kind = role.producer.kind, key = role.gameName }, { kind = role.producer.kind, key = name }, false)
        return
    end
    if expectedChild == nil then state.pendingProducedChild = nil end
end

local function roomIsExpected(state, room)
    local expected = expectedRoom(state)
    if expected == nil then return false end
    local marker = type(room) == "table" and room.__runPlannerExecutionRoomId or nil
    return marker == expected.id and roomName(room) == expected.gameName
end

local function markedRoomData(game, state, expected, metadata)
    if type(game) ~= "table" or type(game.RoomData) ~= "table" then return nil end
    local declaration = game.RoomData[expected.gameName]
    if type(declaration) ~= "table" then return nil end
    local copy = copyRoomData(declaration)
    copy.__runPlannerExecutionRoomId = expected.id
    copy.__runPlannerExecutionPlanFingerprint = state.plan.planFingerprint
    copy.__runPlannerExecutionOwner = expected.owner
    copy.__runPlannerExecutionKind = expected.kind
    if metadata then for key, value in pairs(metadata) do copy[key] = value end end
    if expected.contents then
        copy.__runPlannerExecutionEncounterPhases = expected.contents.encounterPhases
        copy.__runPlannerExecutionRequiredObjects = expected.contents.requiredObjects
        local encounters = {}
        for _, phase in ipairs(expected.contents.encounterPhases or {}) do
            encounters[#encounters + 1] = phase.encounterKey
        end
        if #encounters > 0 then copy.LegalEncounters = encounters end
    end
    return copy
end

local RESOURCE_TOOL_BY_TRAIT = {
    FireEssence = "ToolPickaxe2",
    AirEssence = "ToolExorcismBook2",
    EarthEssence = "ToolShovel2",
    WaterEssence = "ToolFishingRod2",
}

function session.applyResourceSuccesses(state, createdRoom)
    if state.state ~= "synchronized" or type(createdRoom) ~= "table" then return end
    local room = state.roomsById[createdRoom.__runPlannerExecutionRoomId]
    if room == nil then return end
    -- The planner owns only the one successful route-wide placement. Reset
    -- every native roll for this marked occurrence, then re-enable exactly
    -- the compiled success(es); meta-only gathering remains out of scope.
    createdRoom.PickaxePointSuccess = false
    createdRoom.ExorcismPointSuccess = false
    createdRoom.ShovelPointSuccess = false
    createdRoom.FishingPointSuccess = false
    for _, resource in ipairs(room.contents and room.contents.resources or {}) do
        if resource.grantedTraitKey == "FireEssence" then createdRoom.PickaxePointSuccess = true
        elseif resource.grantedTraitKey == "AirEssence" then createdRoom.ExorcismPointSuccess = true
        elseif resource.grantedTraitKey == "EarthEssence" then createdRoom.ShovelPointSuccess = true
        elseif resource.grantedTraitKey == "WaterEssence" then createdRoom.FishingPointSuccess = true
        end
    end
end

function session.beginResourceElementGrant(state, toolName)
    if state.state ~= "synchronized" then return nil end
    local room = expectedRoom(state)
    local resources = room and room.contents and room.contents.resources or nil
    if type(resources) ~= "table" then return nil end
    for _, resource in ipairs(resources) do
        if RESOURCE_TOOL_BY_TRAIT[resource.grantedTraitKey] == toolName then
            return resource
        end
    end
    return nil
end

function session.verifyResourceElementGrant(state, resource, result)
    if state.state ~= "synchronized" or resource == nil then return end
    if result ~= resource.grantedTraitKey then
        mismatch(state, "resource-element", { kind = "trait", key = resource.grantedTraitKey },
            { kind = "trait", key = result }, false)
    end
end

function session.newState() return newState() end

function session.startNewRun(state, dependencies)
    if state.initialized then return end
    state.initialized = true
    local currentRun, args = dependencies.currentRun, dependencies.args or {}
    if dependencies.enabled == false then state.reason = "module-disabled"; return end
    if currentRun and currentRun.IsDreamRun then state.reason = "dream-run"; return end
    local biomeKey = args.StartingBiome
        or (currentRun and currentRun.CurrentRoom and currentRun.CurrentRoom.RoomSetName)
    local routeKey = session.BIOME_ROUTE[biomeKey]
    if routeKey == nil then state.reason = "unsupported-route"; return end
    state.routeKey = routeKey
    local ok, planOrCode = dependencies.inbox.load()
    if not ok then state.reason = "plan-unavailable:" .. bounded(planOrCode); return end
    if type(planOrCode) ~= "table" or planOrCode.kind ~= "ready" then state.reason = "unsupported-plan"; return end
    if planOrCode.routeKey ~= routeKey or planOrCode.extent.biomeKeys[1] ~= "F" then
        state.reason = "unsupported-extent"; return
    end
    if biomeKey ~= "F" then state.reason = "unsupported-starting-biome"; return end
    state.plan = planOrCode
    indexPlan(state, planOrCode)
    if state.currentRoomId == nil then state.reason = "unsupported-plan"; return end
    state.state, state.reason = "synchronized", "plan-frozen"
end

function session.chooseStartingRoom(state, _currentRun, args, game)
    if state.state ~= "synchronized" then return nil end
    local expected = expectedRoom(state)
    if expected == nil then
        mismatch(state, "starting-room", { kind = "room", key = nil }, { kind = "room", key = nil })
        return nil
    end
    local data = markedRoomData(game, state, expected, { __runPlannerExecutionStartingRoom = true })
    if data == nil then
        mismatch(state, "starting-room", { kind = "room", key = expected.gameName }, { kind = "room", key = nil })
        return nil
    end
    local createRoom = game.CreateRoom or _G.CreateRoom
    if type(createRoom) ~= "function" then
        mismatch(state, "starting-room", { kind = "CreateRoom", key = expected.gameName }, { kind = "CreateRoom", key = nil })
        return nil
    end
    return createRoom(data, args)
end

local function selectedTarget(outgoing)
    if outgoing.kind ~= "batch" then return nil end
    for _, target in ipairs(outgoing.targets) do if target.picked then return target end end
    return nil
end

local function generatedAll(state, outgoing)
    if state.generation == nil or state.generation.owner ~= outgoing.owner then return false end
    for _, target in ipairs(outgoing.targets) do
        if not state.generation.generated[target.index] then return false end
    end
    return true
end

local function generatedTargetContact(state, room)
    local expected = expectedRoom(state)
    if expected == nil or expected.outgoing.kind ~= "batch" or state.generation == nil then return nil end
    if state.generation.owner ~= expected.outgoing.owner then return nil end
    local marker = type(room) == "table" and room.__runPlannerExecutionRoomId or nil
    if marker == nil then return nil end
    for _, target in ipairs(expected.outgoing.targets) do
        if target.room.id == marker and state.generation.generated[target.index] then
            if roomName(room) == target.room.gameName then
                return state.roomsById[target.room.id]
            end
            return nil
        end
    end
    return nil
end

local function currentRoomContact(state, currentRun, room)
    local expected = expectedRoom(state)
    local observed = room or (currentRun and currentRun.CurrentRoom)
    if expected == nil then return false, nil, observed end
    local generated = room ~= nil and generatedTargetContact(state, room) or nil
    if generated ~= nil then return true, generated, observed end
    if type(observed) == "table" and observed.__runPlannerExecutionRoomId ~= nil
        and observed.__runPlannerExecutionRoomId ~= expected.id then
        return false, expected, observed
    end
    return roomIsExpected(state, observed), expected, observed
end

function session.chooseNextRoomData(state, currentRun, _args, otherDoors, game)
    if state.state ~= "synchronized" then return { kind = "passThrough" } end
    local matched, expected, observed = currentRoomContact(state, currentRun)
    if not matched then
        mismatch(state, "outgoing-generation", { kind = "room", key = expected and expected.id },
            { kind = "room", key = roomName(observed) })
        return { kind = "failed" }
    end
    local outgoing = expected.outgoing
    if outgoing.kind ~= "batch" then
        if outgoing.kind ~= "fixed" then return { kind = "passThrough" } end
        local target = state.roomsById[outgoing.target.id]
        local data = target and markedRoomData(game, state, target, { __runPlannerExecutionFixedSuccessor = true }) or nil
        if data == nil then
            mismatch(state, "fixed-generation", { kind = "room", key = outgoing.target.id }, { kind = "room", key = nil })
            return { kind = "failed" }
        end
        return { kind = "handled", roomData = data }
    end
    if type(otherDoors) ~= "table" then
        mismatch(state, "door-generation", { kind = "targets", key = #outgoing.targets }, { kind = "targets", key = nil })
        return { kind = "failed" }
    end
    state.generation = state.generation or { owner = outgoing.owner, generated = {} }
    if state.generation.owner ~= outgoing.owner then
        mismatch(state, "door-generation", { kind = "batch", key = outgoing.owner },
            { kind = "batch", key = state.generation.owner })
        return { kind = "failed" }
    end
    local targetToGenerate
    for _, target in ipairs(outgoing.targets) do
        local door = otherDoors[target.index]
        if door == nil then
            mismatch(state, "door-generation", { kind = "door", key = target.index }, { kind = "door", key = nil })
            return { kind = "failed" }
        end
        if not state.generation.generated[target.index] then
            if target.type ~= "" and door.Name ~= nil and door.Name ~= target.type then
                mismatch(state, "door-generation", { kind = "door", key = target.type }, { kind = "door", key = door.Name })
                return { kind = "failed" }
            end
            targetToGenerate = target
            break
        end
    end
    if targetToGenerate == nil then return { kind = "passThrough" } end
    local targetRoom = state.roomsById[targetToGenerate.room.id]
    local data = targetRoom and markedRoomData(game, state, targetRoom, {
        __runPlannerExecutionBatchOwner = outgoing.owner,
        __runPlannerExecutionExitKey = targetToGenerate.exitKey,
        __runPlannerExecutionExitIndex = targetToGenerate.index,
        __runPlannerExecutionExitType = targetToGenerate.type,
        __runPlannerExecutionPicked = targetToGenerate.picked,
    }) or nil
    if data == nil then
        mismatch(state, "door-generation", { kind = "room", key = targetToGenerate.room.id }, { kind = "room", key = nil })
        return { kind = "failed" }
    end
    state.generation.generated[targetToGenerate.index] = true
    return { kind = "handled", roomData = data }
end

function session.prepareBatchRewardStore(state, currentRun)
    if state.state ~= "synchronized" then return { kind = "passThrough" } end
    local matched, expected, observed = currentRoomContact(state, currentRun)
    if not matched then
        mismatch(state, "reward-store", { kind = "room", key = expected and expected.id },
            { kind = "room", key = roomName(observed) })
        return { kind = "failed" }
    end
    if expected.outgoing.kind ~= "batch" or expected.outgoing.resolvedSharedRewardStoreKey == nil then
        return { kind = "passThrough" }
    end
    currentRun.NextRewardStoreName = expected.outgoing.resolvedSharedRewardStoreKey
    return { kind = "handled" }
end

local function expectedReward(room)
    return room and room.contents and room.contents.incomingReward or nil
end

nextTrace = function(state)
    local room = expectedRoom(state)
    return room and room.trace and room.trace[state.traceCursor or 1] or nil
end

function session.prepareTraitOfferOption(state, itemIndex, itemData)
    if state.state ~= "synchronized" then return { kind = "passThrough" } end
    local action = nextTrace(state)
    if action == nil or action.kind ~= "acquireReward" then return { kind = "passThrough" } end
    local role
    for _, candidate in ipairs(action.roles or {}) do if candidate.traitOffer ~= nil then role = candidate; break end end
    if role == nil or role.traitOffer.kind == "fallbackGold" then return { kind = "passThrough" } end
    local option = role.traitOffer.options[itemIndex]
    if type(itemData) ~= "table" or option == nil then
        mismatch(state, "trait-offer", { kind = "option", key = option and option.key }, { kind = "option", key = nil })
        return { kind = "failed" }
    end
    itemData.ItemName, itemData.Rarity = option.key, option.rarity
    if option.effectiveLevel ~= nil then itemData.StackNum = option.effectiveLevel end
    if option.replacement ~= nil then
        itemData.TraitToReplace, itemData.OldRarity = option.replacement.replacedTraitKey, option.replacement.oldRarity
    end
    state.pendingAcquisition = state.pendingAcquisition or { action = action, role = role, selected = role.traitOffer.selected }
    return { kind = "handled" }
end

function session.observeTraitSelection(state, selectedTrait)
    if state.state ~= "synchronized" then return end
    local pending = state.pendingAcquisition
    if pending == nil then
        mismatch(state, "trait-selection", { kind = "planned", key = nil }, { kind = "trait", key = selectedTrait }, true, "playerDivergence", "player")
        return
    end
    local offer = pending.role.traitOffer
    if offer.kind == "fallbackGold" then
        if selectedTrait ~= "FallbackGold" then
            mismatch(state, "trait-selection", { kind = "trait", key = "FallbackGold" }, { kind = "trait", key = selectedTrait }, true, "playerDivergence", "player")
            return
        end
        pending.selectedTrait = selectedTrait
        confirmAction(state, "trait", selectedTrait)
        return
    end
    local expected = offer.options[tonumber(pending.selected:sub(7))]
    if expected == nil or selectedTrait ~= expected.key then
        mismatch(state, "trait-selection", { kind = "trait", key = expected and expected.key }, { kind = "trait", key = selectedTrait }, true, "playerDivergence", "player")
        return
    end
    pending.selectedTrait = selectedTrait
    confirmAction(state, "trait", selectedTrait)
end

function session.verifyTraitAcquisition(state, heroTraits)
    if state.state ~= "synchronized" or state.pendingAcquisition == nil then return end
    local pending = state.pendingAcquisition
    if pending.role.traitOffer.kind == "fallbackGold" then
        if pending.selectedTrait ~= "FallbackGold" then
            mismatch(state, "trait-acquisition", { kind = "trait", key = "FallbackGold" }, { kind = "trait", key = pending.selectedTrait }, false)
            return
        end
        state.pendingAcquisition = nil
        consumeTraceStep(state, "acquireReward")
        return
    end
    local found = nil
    for _, trait in pairs(heroTraits or {}) do
        if type(trait) == "table" and (trait.Name == pending.selectedTrait or trait.TraitName == pending.selectedTrait) then found = trait; break end
    end
    local expected = pending.role.traitOffer.options[tonumber(pending.role.traitOffer.selected:sub(7))]
    local replacedStillPresent = false
    if expected.replacement then
        for _, trait in pairs(heroTraits or {}) do
            if type(trait) == "table" and trait.Name == expected.replacement.replacedTraitKey then replacedStillPresent = true end
        end
    end
    if found == nil or (expected.rarity ~= nil and found.Rarity ~= expected.rarity)
        or (expected.effectiveLevel ~= nil and found.StackNum ~= expected.effectiveLevel)
        or replacedStillPresent then
        mismatch(state, "trait-acquisition", { kind = "trait", key = pending.selectedTrait }, { kind = "trait", key = nil }, false)
        return
    end
    state.pendingAcquisition = nil
    consumeTraceStep(state, "acquireReward")
end

plannedRoleFor = function(state, itemName)
    local action = nextTrace(state)
    if action == nil or action.kind ~= "acquireReward" then return nil end
    for _, role in ipairs(action.roles or {}) do
        if role.gameName == itemName then return action, role end
    end
    return action, nil
end

-- UseLoot is the common natural acquisition seam for Boons, Devotions,
-- Hammers and Poms. Resource-cost loot belongs to Gate D and passes through.
function session.prepareLootUse(state, usee)
    if state.state ~= "synchronized" then return { kind = "passThrough" } end
    if type(usee) ~= "table" then return { kind = "passThrough" } end
    if usee.ResourceCosts ~= nil and usee.IgnorePurchase ~= true then return { kind = "passThrough" } end
    local action, role = plannedRoleFor(state, usee.Name)
    if action == nil then
        mismatch(state, "acquisition", { kind = "planned", key = nil }, { kind = "loot", key = usee.Name }, true, "playerDivergence", "player")
        return { kind = "failed" }
    end
    if role == nil then
        mismatch(state, "acquisition", { kind = "role", key = action.roles[1] and action.roles[1].gameName }, { kind = "loot", key = usee.Name }, true, "playerDivergence", "player")
        return { kind = "failed" }
    end
    if role.traitOffer then
        local offer = role.traitOffer
        if offer.kind == "fallbackGold" then
            usee.UpgradeOptions = { { ItemName = "FallbackGold", Rarity = "Common" } }
        else
            usee.UpgradeOptions = {}
            for index, option in ipairs(offer.options) do
                local item = { ItemName = option.key, Rarity = option.rarity, StackNum = option.effectiveLevel }
                if option.replacement then item.TraitToReplace, item.OldRarity = option.replacement.replacedTraitKey, option.replacement.oldRarity end
                usee.UpgradeOptions[index] = item
            end
        end
        state.pendingAcquisition = { action = action, role = role, selected = offer.selected }
    elseif role.levelResolution then
        local resolution = role.levelResolution
        usee.StackOnly, usee.StackNum, usee.UpgradeOptions = true, resolution.levelCount, {}
        for index, key in ipairs(resolution.offeredTargets) do usee.UpgradeOptions[index] = { ItemName = key } end
        state.pendingPom = { action = action, role = role, resolution = resolution, selectedBefore = nil }
    else
        state.pendingSimpleAcquisition = { action = action, role = role }
    end
    return { kind = "handled" }
end

function session.completeSimpleAcquisition(state, itemName)
    local pending = state.pendingSimpleAcquisition
    if state.state ~= "synchronized" or pending == nil then return end
    if pending.contactReached ~= true then return end
    if pending.role.gameName ~= itemName then
        mismatch(state, "acquisition", { kind = "loot", key = pending.role.gameName }, { kind = "loot", key = itemName }, false)
        return
    end
    confirmAction(state, "acquisition", itemName)
    state.pendingSimpleAcquisition = nil
    consumeTraceStep(state, "acquireReward")
end

function session.markSimpleAcquisitionContact(state, itemName)
    local pending = state.pendingSimpleAcquisition
    if pending and pending.role.gameName == itemName then pending.contactReached = true end
end

function session.observePomSelection(state, traitKey, heroTraits)
    local pending = state.pendingPom
    if state.state ~= "synchronized" or pending == nil then return end
    if pending.resolution.selectedTarget ~= traitKey then
        mismatch(state, "pom-selection", { kind = "trait", key = pending.resolution.selectedTarget }, { kind = "trait", key = traitKey }, true, "playerDivergence", "player")
        return
    end
    for _, trait in pairs(heroTraits or {}) do
        if type(trait) == "table" and traitKey == trait.Name then pending.selectedBefore = trait.StackNum; break end
    end
    if type(pending.selectedBefore) ~= "number" then
        mismatch(state, "pom-selection", { kind = "trait", key = traitKey }, { kind = "trait", key = nil }, false)
        return
    end
    confirmAction(state, "pom", traitKey)
end

function session.verifyPomResolution(state, heroTraits)
    if state.state ~= "synchronized" or state.pendingPom == nil then return end
    local pending = state.pendingPom
    local selected = pending.resolution.selectedTarget
    if selected == nil then
        state.pendingPom = nil
        consumeTraceStep(state, "acquireReward")
        return
    end
    local trait = nil
    for _, value in pairs(heroTraits or {}) do
        if type(value) == "table" and (value.Name == selected or value.TraitName == selected) then trait = value; break end
    end
    local observed = trait and trait.StackNum or nil
    local prior = pending.selectedBefore
    if trait == nil or type(prior) ~= "number" or observed ~= prior + pending.resolution.levelCount then
        mismatch(state, "pom-acquisition", { kind = "traitLevel", key = selected }, { kind = "traitLevel", key = observed }, false)
        return
    end
    state.pendingPom = nil
    consumeTraceStep(state, "acquireReward")
end

-- Automatic outcomes are still performed by the game.  These helpers only
-- bind the already-published target to the game's narrow random seam.
local function sourceName(value)
    return type(value) == "table" and (value.Name or value.SourceName) or value
end

function session.prepareSteadyGrowth(state, source, args, heroTraits)
    if state.state ~= "synchronized" then return { kind = "passThrough" } end
    local step = nextTrace(state)
    if step == nil or step.kind ~= "steadyGrowth" then return { kind = "passThrough" } end
    local target
    for _, trait in pairs(heroTraits or {}) do
        if type(trait) == "table" and (trait.Name == step.target or trait.TraitName == step.target) then target = trait; break end
    end
    if target == nil or type(args) ~= "table" or sourceName(source) ~= step.source then
        mismatch(state, "steady-growth", { kind = "trait", key = step.target }, { kind = "trait", key = nil })
        return { kind = "failed" }
    end
    args.ForceUpgrade = { target }
    state.pendingSteadyGrowth = { step = step, priorRarity = target.Rarity }
    return { kind = "handled" }
end

function session.verifySteadyGrowth(state, heroTraits, returnedTrait)
    local pending = state.pendingSteadyGrowth
    if state.state ~= "synchronized" or pending == nil then return end
    local step = pending.step
    for _, trait in pairs(heroTraits or {}) do
        if type(trait) == "table" and (trait.Name == step.target or trait.TraitName == step.target) then
            local nextRarity = type(_G.GetUpgradedRarity) == "function" and _G.GetUpgradedRarity(pending.priorRarity) or nil
            if nextRarity == nil or trait.Rarity ~= nextRarity
                or type(returnedTrait) ~= "table" or returnedTrait.Name ~= step.target
                or returnedTrait.Rarity ~= nextRarity then
                mismatch(state, "steady-growth", { kind = "rarity", key = nextRarity }, { kind = "rarity", key = trait.Rarity }, false)
                return
            end
            state.pendingSteadyGrowth = nil
            consumeTraceStep(state, "steadyGrowth")
            return
        end
    end
    mismatch(state, "steady-growth", { kind = "trait", key = step.target }, { kind = "trait", key = nil }, false)
end

function session.prepareEmbryo(state)
    if state.state ~= "synchronized" then return nil end
    local step = nextTrace(state)
    if step == nil or step.kind ~= "transcendentEmbryo" then return nil end
    state.pendingEmbryo = step
    return { target = step.target, rarity = step.rarity }
end

function session.verifyEmbryo(state, trait, traitDictionary)
    local step = state.pendingEmbryo
    if state.state ~= "synchronized" or step == nil then return end
    local key = type(trait) == "table" and (trait.Name or trait.TraitName) or trait
    if key ~= step.target or type(trait) ~= "table" or trait.Rarity ~= step.rarity
        or trait.FromChaosKeepsake ~= true or type(traitDictionary) ~= "table"
        or type(traitDictionary[step.target]) ~= "table" then
        mismatch(state, "transcendent-embryo", { kind = "trait", key = step.target }, { kind = "trait", key = key }, false)
        return
    end
    state.pendingEmbryo = nil
    consumeTraceStep(state, "transcendentEmbryo")
end

function session.chooseRoomRewardFor(state, reward, currentRun, room, game, base, rewardStoreName, previouslyChosenRewards, args)
    if state.state ~= "synchronized" then return { kind = "passThrough" } end
    local matched, expected, observed = currentRoomContact(state, currentRun, room)
    if not matched then
        mismatch(state, "reward", { kind = "room", key = expected and expected.id }, { kind = "room", key = roomName(observed) })
        return { kind = "failed" }
    end
    if reward == nil then reward = expectedReward(expected) end
    if reward == nil then return { kind = "passThrough" } end
    for _, source in ipairs({ reward.source, reward.spurnedSource }) do
        if source ~= nil and not sourceExists(game, source) then
            mismatch(state, "reward-source", { kind = "loot", key = source }, { kind = "loot", key = nil })
            return { kind = "failed" }
        end
    end
    if reward.resolvedStoreKey ~= nil and rewardStoreName ~= reward.resolvedStoreKey then
        mismatch(state, "reward-store", { kind = "rewardStore", key = reward.resolvedStoreKey }, { kind = "rewardStore", key = rewardStoreName })
        return { kind = "failed" }
    end
    local priorities = currentRun and currentRun.RewardPriorities
    local prior = type(priorities) == "table" and copyArray(priorities) or nil
    if prior ~= nil then table.insert(priorities, 1, reward.rewardType) end
    local ok, actual = pcall(base, currentRun, room, rewardStoreName, previouslyChosenRewards, args)
    if prior ~= nil then restoreArray(priorities, prior) end
    if not ok then error(actual, 0) end
    if rewardName(actual) ~= reward.rewardType then
        mismatch(state, "reward-selected", { kind = "reward", key = reward.rewardType }, { kind = "reward", key = rewardName(actual) }, false)
        return { kind = "failed", value = actual }
    end
    if reward.source ~= nil and type(room) == "table" then room.ForceLootName = reward.source end
    if reward.spurnedSource ~= nil and type(room) == "table" and type(room.Encounter) == "table" then
        room.Encounter.LootAName, room.Encounter.LootBName = reward.source, reward.spurnedSource
    end
    state.rewardObserved = true
    return { kind = "handled", value = actual }
end

function session.chooseRoomReward(state, currentRun, room, game, base, rewardStoreName, previouslyChosenRewards, args)
    return session.chooseRoomRewardFor(state, nil, currentRun, room, game, base,
        rewardStoreName, previouslyChosenRewards, args)
end

-- Source selection is a property of the resolved incoming reward, not a
-- second planner decision. Apply it at the game's reward setup seam so the
-- normal Boon/Devotion setup path receives the frozen source pair.
function session.prepareRewardSource(state, currentRun, room)
    if state.state ~= "synchronized" then return { kind = "passThrough" } end
    local matched, expected, observed = currentRoomContact(state, currentRun, room)
    if not matched then
        mismatch(state, "reward-source", { kind = "room", key = expected and expected.id },
            { kind = "room", key = roomName(observed) })
        return { kind = "failed" }
    end
    local reward = expectedReward(expected)
    if reward == nil or reward.source == nil then return { kind = "passThrough" } end
    if type(room) == "table" then
        if reward.spurnedSource ~= nil and type(room.Encounter) == "table" then
            room.Encounter.LootAName, room.Encounter.LootBName = reward.source, reward.spurnedSource
        else
            room.ForceLootName = reward.source
        end
    end
    return { kind = "handled" }
end

local function countInRange(value, count)
    if type(value) ~= "table" or type(count) ~= "number" then return false end
    if value.kind == "exact" then return count == value.count end
    return value.kind == "range" and count >= value.min and count <= value.max
end

local function liveCounter(currentRun, field)
    if type(currentRun) ~= "table" then return nil end
    if field == "roomHistoryOrdinal" then
        if type(currentRun.RoomHistory) ~= "table" then return nil end
        return #currentRun.RoomHistory
    end
    local gameFields = {
        biomeDepthCache = "BiomeDepthCache",
        routeEncounterDepth = "EncounterDepth",
    }
    if field == "biomeEncounterDepth" then
        -- StartEncounter treats an absent cache as the baseline depth one.
        return currentRun.BiomeEncounterDepth or 1
    end
    local gameField = gameFields[field]
    return gameField == nil and nil or currentRun[gameField]
end

local function liveBag(currentRun, storeKey)
    if type(currentRun) ~= "table" then return nil end
    if type(currentRun.RewardStores) ~= "table" then return nil end
    local store = currentRun.RewardStores[storeKey]
    if type(store) ~= "table" then return nil end
    return #store
end

local function sameArray(expected, observed, key)
    if type(observed) ~= "table" or #expected ~= #observed then return false end
    local actual, wanted = {}, {}
    for _, value in ipairs(observed) do actual[key(value)] = (actual[key(value)] or 0) + 1 end
    for _, value in ipairs(expected) do wanted[key(value)] = (wanted[key(value)] or 0) + 1 end
    for value, count in pairs(wanted) do if actual[value] ~= count then return false end end
    return true
end

local function traitKey(value) return type(value) == "table" and (value.Name or value.TraitName or value.Key) or value end

-- Each field has one bounded adapter to its live owner.  Returning nil is
-- intentional: it turns an unsupported contact into a conformance mismatch
-- instead of quietly dropping a published field.
local function callLive(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if not ok then return nil end
    return value
end

local function keysOfEnabled(values)
    if type(values) ~= "table" then return nil end
    local result = {}
    for key, enabled in pairs(values) do if enabled then result[#result + 1] = key end end
    return result
end

local function liveArcana(currentRun)
    local state, cards = _G.GameState and _G.GameState.MetaUpgradeState, _G.MetaUpgradeCardData
    if type(state) ~= "table" or type(cards) ~= "table" then return nil end
    local temporary = currentRun.TemporaryMetaUpgrades
    if type(temporary) ~= "table" then return nil end
    local order = _G.TraitRarityData and _G.TraitRarityData.RarityUpgradeOrder
    if type(order) ~= "table" then return nil end
    local result = {}
    for key, entry in pairs(state) do
        if type(entry) == "table" and entry.Equipped then
            local card = cards[key]
            if type(card) ~= "table" then return nil end
            local rarity = order[entry.RarityLevel or entry.Level or 1]
            if type(rarity) ~= "string" then return nil end
            local origin = temporary[key] and "temporary"
                or (card.AutoEquipRequirements ~= nil and "automatic" or "manual")
            result[#result + 1] = { key = key, origin = origin, rarity = rarity }
        end
    end
    return result
end

local function liveDiagnostic(currentRun, diagnostic)
    if type(currentRun) ~= "table" then return nil end
    local hero = currentRun.Hero
    local traits = type(hero) == "table" and hero.Traits
    if type(traits) ~= "table" then return nil end
    local equipped = {}
    for _, trait in pairs(traits) do
        if type(trait) == "table" then
            equipped[#equipped + 1] = {
                traitKey = traitKey(trait), rarity = trait.Rarity,
                level = trait.StackNum,
            }
            if trait.IsHammerTrait == true then
                equipped[#equipped].hammerRank = trait.Rarity == "Legendary" and "RankII" or "RankI"
            end
        end
    end
    local slots = {}
    local liveSlots = type(hero) == "table" and hero.SlottedTraits
    if type(liveSlots) ~= "table" then return nil end
    for _, expected in ipairs(diagnostic.traits.slots) do
        slots[#slots + 1] = { slot = expected.slot, traitKey = traitKey(liveSlots[expected.slot]) }
    end
    local acquired = callLive("GetInteractedGodsThisRun")
    local effective = callLive("GetEligibleLootNames")
    local cap = callLive("ReachedMaxGods")
    local arcana = liveArcana(currentRun)
    local configured = _G.GameState and _G.GameState.ShrineUpgrades
    local disabled = currentRun.ShrineUpgradesDisabled
    if type(acquired) ~= "table" or type(effective) ~= "table" or type(cap) ~= "boolean"
        or arcana == nil or type(configured) ~= "table" or type(disabled) ~= "table" then return nil end
    local effectiveRanks = {}
    for key in pairs(diagnostic.vows.effectiveRanks) do
        local rank = callLive("GetNumShrineUpgrades", key)
        if type(rank) ~= "number" then return nil end
        effectiveRanks[key] = rank
    end
    local configuredRanks = {}
    for key in pairs(diagnostic.vows.configuredRanks) do
        if type(configured[key]) ~= "number" then return nil end
        configuredRanks[key] = configured[key]
    end
    local forfeitRank = callLive("GetNumShrineUpgrades", "BoonSkipShrineUpgrade")
    if type(forfeitRank) ~= "number" or type(currentRun.BiomeBoonSkipCount) ~= "number" then return nil end
    local forfeit = forfeitRank <= 0 and "inactive" or (currentRun.BiomeBoonSkipCount >= forfeitRank and "consumed" or "available")
    return {
        godPool = {
            acquiredSourceKeys = acquired, effectiveSourceKeys = effective, capNarrowed = cap,
        },
        traits = {
            equipped = equipped, slots = slots, elements = hero.Elements,
            godRarityCounts = hero.GodBoonRarities,
            upgradableCount = hero.UpgradableTraitCount,
            bannedTraitKeys = keysOfEnabled(currentRun.BannedTraits),
        },
        arcana = { active = arcana },
        vows = {
            configuredRanks = configuredRanks, effectiveRanks = effectiveRanks,
            disabledKeys = keysOfEnabled(disabled),
        },
        forfeit = forfeit,
    }
end

-- Gate D deliberately publishes only the retained facts which have a direct
-- game owner.  This adapter does not reconstruct chronology or infer a Hex
-- layout from planner-only state.
local function liveGateDDiagnostic(currentRun, diagnostic)
    local gameState = _G.GameState
    local hero = type(currentRun) == "table" and currentRun.Hero or nil
    if type(gameState) ~= "table" or type(hero) ~= "table"
        or type(currentRun.KeepsakeCache) ~= "table"
        or type(currentRun.BlockedKeepsakes) ~= "table"
        or type(gameState.LastAwardTrait) ~= "string"
        or type(gameState.FatedStatus) ~= "string"
        or type(currentRun.NumTalentPoints) ~= "number" then return nil end
    local spell = hero.SlottedSpell
    if spell ~= nil and type(spell) ~= "table" then return nil end
    -- Native opening runs allocate only NumTalentPoints. The remaining Hex
    -- fields first exist when the spell/talent system touches them, so absent
    -- values have their documented zero/false meaning while no spell is held.
    if spell ~= nil and (type(currentRun.InvestedTalentPoints) ~= "number"
        or type(currentRun.AllSpellInvestedCache) ~= "boolean") then return nil end
    local invested, closed = currentRun.InvestedTalentPoints, currentRun.AllSpellInvestedCache
    if spell == nil and invested == nil then invested = 0 end
    if spell == nil and closed == nil then closed = false end
    local talents = spell and spell.Talents or {}
    if type(talents) ~= "table" then return nil end
    local talentKeys = {}
    local function collectTalents(node)
        if type(node) ~= "table" then return end
        local trait = type(_G.TraitData) == "table" and _G.TraitData[node.Name] or nil
        if type(node.Name) == "string" and (node.Rarity == "Rare" or node.Rarity == "Epic"
            or node.Name == "OlympianSpellCountTalent" or (type(trait) == "table" and trait.IsDuoBoon == true)) then
            talentKeys[#talentKeys + 1] = node.Name
        end
        for _, child in ipairs(node) do collectTalents(child) end
    end
    collectTalents(talents)
    local live = {
        keepsakes = {
            currentKey = gameState.LastAwardTrait,
            usedKeys = currentRun.KeepsakeCache,
            blockedKeys = currentRun.BlockedKeepsakes,
            fatedStatus = gameState.FatedStatus,
        },
        hexProgress = {
            spellTraitKey = spell and spell.Name or nil,
            layoutKey = talents.Name,
            talentKeys = talentKeys,
            closed = closed,
            bankedPathPoints = currentRun.NumTalentPoints,
            investedPathPoints = invested,
        },
        artificer = nil,
    }
    if diagnostic.artificer ~= nil then
        local trait = callLive("GetHeroTrait", "MetaToRunMetaUpgrade")
        if type(trait) ~= "table" or type(trait.MetaConversionUses) ~= "number"
            or type(currentRun.MetaConversionUses) ~= "number" then return nil end
        live.artificer = {
            usedCount = currentRun.MetaConversionUses,
            remainingCount = trait.MetaConversionUses,
        }
    end
    return live
end

local function equalMap(expected, observed)
    if type(observed) ~= "table" then return false end
    for key, value in pairs(expected) do if observed[key] ~= value then return false end end
    for key in pairs(observed) do if expected[key] == nil then return false end end
    return true
end

local function sameStringSet(expected, observed)
    if type(expected) ~= "table" or type(observed) ~= "table" then return false end
    local expectedSet, observedSet = {}, {}
    for _, value in ipairs(expected) do expectedSet[value] = (expectedSet[value] or 0) + 1 end
    for _, value in ipairs(observed) do observedSet[value] = (observedSet[value] or 0) + 1 end
    return equalMap(expectedSet, observedSet)
end

local function traitMatches(expected, observed)
    if type(observed) ~= "table" then return false end
    for _, field in ipairs({ "traitKey", "rarity", "level", "hammerRank" }) do
        if expected[field] ~= nil and observed[field] ~= expected[field] then return false end
    end
    return true
end

function session.observeRunState(state, currentRun, checkpoint)
    if state.state ~= "synchronized" then return false end
    local expected = expectedRoom(state)
    if expected == nil then return false end
    for _, step in ipairs(expected.trace or {}) do
        if step.checkpoint == checkpoint and step.runState ~= nil then
            local diagnostic = step.runState
            for field, expectedValue in pairs(diagnostic.counters) do
                local observed = liveCounter(currentRun, field)
                if observed == nil or observed ~= expectedValue then
                    mismatch(state, checkpoint, { kind = field, key = expectedValue }, { kind = field, key = observed }, false)
                    return false
                end
            end
            for _, bag in ipairs(diagnostic.bags or {}) do
                local observed = liveBag(currentRun, bag.storeKey)
                if observed == nil or not countInRange(bag.remaining, observed) then
                    mismatch(state, checkpoint, { kind = "bag", key = bag.storeKey }, { kind = "bag", key = observed }, false)
                    return false
                end
            end
            if not sameArray(diagnostic.rewardPriorities, currentRun.RewardPriorities, tostring) then
                mismatch(state, checkpoint, { kind = "rewardPriorities", key = diagnostic.rewardPriorities },
                    { kind = "rewardPriorities", key = currentRun.RewardPriorities }, false)
                return false
            end
            local gateD = liveGateDDiagnostic(currentRun, diagnostic)
            if gateD == nil
                or gateD.keepsakes.currentKey ~= diagnostic.keepsakes.currentKey
                or not sameArray(diagnostic.keepsakes.usedKeys, gateD.keepsakes.usedKeys, tostring)
                or not sameArray(diagnostic.keepsakes.blockedKeys, gateD.keepsakes.blockedKeys, tostring)
                or gateD.keepsakes.fatedStatus ~= diagnostic.keepsakes.fatedStatus
                or gateD.hexProgress.spellTraitKey ~= diagnostic.hexProgress.spellTraitKey
                or gateD.hexProgress.layoutKey ~= diagnostic.hexProgress.layoutKey
                or not sameStringSet(diagnostic.hexProgress.talentKeys, gateD.hexProgress.talentKeys)
                or gateD.hexProgress.closed ~= diagnostic.hexProgress.closed
                or gateD.hexProgress.bankedPathPoints ~= diagnostic.hexProgress.bankedPathPoints
                or gateD.hexProgress.investedPathPoints ~= diagnostic.hexProgress.investedPathPoints
                or ((diagnostic.artificer == nil) ~= (gateD and gateD.artificer == nil))
                or (diagnostic.artificer ~= nil and (gateD.artificer.usedCount ~= diagnostic.artificer.usedCount
                    or gateD.artificer.remainingCount ~= diagnostic.artificer.remainingCount)) then
                mismatch(state, checkpoint, { kind = "gateD-run-state", key = diagnostic },
                    { kind = "gateD-run-state", key = gateD }, false)
                return false
            end
            local live = liveDiagnostic(currentRun, diagnostic)
            if live == nil then
                mismatch(state, checkpoint, { kind = "runStateObserver", key = "complete-v4" }, { kind = "runStateObserver", key = nil }, false)
                return false
            end
            if not sameArray(diagnostic.godPool.acquiredSourceKeys, live.godPool.acquiredSourceKeys, tostring)
                or not sameArray(diagnostic.godPool.effectiveSourceKeys, live.godPool.effectiveSourceKeys, tostring)
                or live.godPool.capNarrowed ~= diagnostic.godPool.capNarrowed then
                mismatch(state, checkpoint, { kind = "godPool", key = diagnostic.godPool }, { kind = "godPool", key = live.godPool }, false)
                return false
            end
            for _, expectedTrait in ipairs(diagnostic.traits.equipped) do
                local actual
                for _, candidate in ipairs(live.traits.equipped) do if candidate.traitKey == expectedTrait.traitKey then actual = candidate; break end end
                if not traitMatches(expectedTrait, actual) then
                    mismatch(state, checkpoint, { kind = "trait:" .. expectedTrait.traitKey, key = expectedTrait }, { kind = "trait:" .. expectedTrait.traitKey, key = actual }, false)
                    return false
                end
            end
            if #diagnostic.traits.equipped ~= #live.traits.equipped or not sameArray(diagnostic.traits.slots, live.traits.slots, function(value) return value.slot .. "=" .. tostring(value.traitKey) end)
                or not equalMap(diagnostic.traits.elements, live.traits.elements)
                or not equalMap(diagnostic.traits.godRarityCounts, live.traits.godRarityCounts)
                or diagnostic.traits.upgradableCount ~= live.traits.upgradableCount
                or not sameArray(diagnostic.traits.bannedTraitKeys, live.traits.bannedTraitKeys, tostring) then
                mismatch(state, checkpoint, { kind = "traits", key = diagnostic.traits }, { kind = "traits", key = live.traits }, false)
                return false
            end
            if not sameArray(diagnostic.arcana.active, live.arcana.active, function(value)
                return tostring(value.key or value.Name) .. "|" .. tostring(value.origin or value.Origin) .. "|" .. tostring(value.rarity or value.Rarity)
            end) or not equalMap(diagnostic.vows.configuredRanks, live.vows.configuredRanks)
                or not equalMap(diagnostic.vows.effectiveRanks, live.vows.effectiveRanks)
                or not sameArray(diagnostic.vows.disabledKeys, live.vows.disabledKeys, tostring)
                or diagnostic.forfeit ~= live.forfeit then
                mismatch(state, checkpoint, { kind = "retained-state", key = diagnostic.forfeit }, { kind = "retained-state", key = live.forfeit }, false)
                return false
            end
            state.diagnostics[checkpoint] = true
            return true
        end
    end
    return false
end

consumeTraceStep = function(state, kind)
    local room = expectedRoom(state)
    local trace = room and room.trace or nil
    local index = state.traceCursor or 1
    local step = type(trace) == "table" and trace[index] or nil
    if step == nil or step.kind ~= kind then
        mismatch(state, "trace-cursor",
            { kind = "traceStep", key = step and step.kind or nil },
            { kind = "traceStep", key = kind }, false)
        return false
    end
    state.traceCursor = index + 1
    return true
end

function session.observeRoom(state, currentRun, room)
    if state.state ~= "synchronized" then return end
    local matched, expected, observed = currentRoomContact(state, currentRun, room)
    if not matched then
        mismatch(state, "room-entered", { kind = "room", key = expected and expected.id }, { kind = "room", key = roomName(observed) })
        return
    end
    state.roomObserved, state.rewardObserved, state.generation, state.encounterPhase = true, false, nil, nil
    state.traceCursor = 1
    state.reason = "room-entry-observed"
    if not consumeTraceStep(state, "roomEntered") then return end
    session.observeRunState(state, currentRun, "roomEntered")
end

-- Encounter declarations are already resolved by the planner.  Observe the
-- game's normal phase boundaries; do not start, end, or substitute combat.
local function encounterName(value)
    return type(value) == "table" and (value.Name or value.EncounterName) or value
end

function session.observeEncounterStart(state, currentRun, room, encounter)
    if state.state ~= "synchronized" then return end
    local matched, expected, observed = currentRoomContact(state, currentRun, room)
    if not matched then
        mismatch(state, "encounter-start", { kind = "room", key = expected and expected.id },
            { kind = "room", key = roomName(observed) })
        return
    end
    local step = expected.trace and expected.trace[state.traceCursor or 1] or nil
    local phase = step and step.kind == "encounterStart" and { slotKey = step.phase, encounterKey = step.encounter } or nil
    if phase == nil or encounterName(encounter) ~= phase.encounterKey then
        mismatch(state, "encounter-start", { kind = "encounter", key = phase and phase.encounterKey },
            { kind = "encounter", key = encounterName(encounter) }, false)
        return
    end
    state.encounterPhase = phase.slotKey
    consumeTraceStep(state, "encounterStart")
end

function session.observeEncounterEnd(state, currentRun, room, encounter)
    if state.state ~= "synchronized" then return end
    local expected = expectedRoom(state)
    local step = expected and expected.trace and expected.trace[state.traceCursor or 1] or nil
    local phase = expected and expected.contents and expected.contents.encounterPhases or {}
    local expectedEncounter
    for _, candidate in ipairs(phase) do if candidate.slotKey == (step and step.phase) then expectedEncounter = candidate.encounterKey end end
    if step == nil or step.kind ~= "encounterEnd" or step.phase ~= state.encounterPhase
        or encounterName(encounter) ~= expectedEncounter then
        mismatch(state, "encounter-end", { kind = "phase", key = step and step.phase },
            { kind = "encounter", key = encounterName(encounter) }, false)
        return
    end
    consumeTraceStep(state, "encounterEnd")
end

function session.observeEncounterInteraction(state, currentRun, room)
    if state.state ~= "synchronized" then return end
    local matched, expected, observed = currentRoomContact(state, currentRun, room)
    if not matched then
        mismatch(state, "encounter-interaction", { kind = "room", key = expected and expected.id }, { kind = "room", key = roomName(observed) })
        return
    end
    local step = nextTrace(state)
    local found = false
    for _, phase in ipairs(expected.contents.encounterPhases or {}) do if phase.slotKey == (step and step.phaseKey) then found = true end end
    if step == nil or step.kind ~= "encounterInteraction" or not found then
        mismatch(state, "encounter-interaction", { kind = "phase", key = step and step.phaseKey }, { kind = "phase", key = nil }, false, "playerDivergence", "player")
        return
    end
    confirmAction(state, "encounterInteraction", step.phaseKey)
    consumeTraceStep(state, "encounterInteraction")
end

-- Gate D interaction rows are deliberately closed.  These observers record
-- player participation at the native interaction seam; they never invoke an
-- interaction or repair the resulting game state.
function session.observeStygianWellPurchase(state, offerKey)
    if state.state ~= "synchronized" then return end
    local step = nextTrace(state)
    if step == nil or step.kind ~= "stygianWellPurchase" or step.offerKey ~= offerKey then
        mismatch(state, "stygian-well-purchase", { kind = "offer", key = step and step.offerKey }, { kind = "offer", key = offerKey }, true, "playerDivergence", "player")
        return
    end
    confirmAction(state, "stygianWellPurchase", offerKey)
    consumeTraceStep(state, "stygianWellPurchase")
end

function session.recordWellTwistMismatch(state, target)
    if state.state ~= "synchronized" then return end
    mismatch(state, "stygian-well-twist", { kind = "result", key = target }, { kind = "result", key = nil })
end

function session.observeWorldShopPurchase(state, offerKey)
    if state.state ~= "synchronized" then return end
    local step = nextTrace(state)
    if step == nil or step.kind ~= "worldShopPurchase" or step.offerKey ~= offerKey then
        mismatch(state, "world-shop-purchase", { kind = "offer", key = step and step.offerKey }, { kind = "offer", key = offerKey }, true, "playerDivergence", "player")
        return
    end
    confirmAction(state, "worldShopPurchase", offerKey)
    consumeTraceStep(state, "worldShopPurchase")
end

function session.observePurgingPoolSale(state, soldTraitKey)
    if state.state ~= "synchronized" then return end
    local step = nextTrace(state)
    if step == nil or step.kind ~= "purgingPoolSale" or step.traitKey ~= soldTraitKey then
        mismatch(state, "purging-pool-sale", { kind = "trait", key = step and step.traitKey }, { kind = "trait", key = soldTraitKey }, true, "playerDivergence", "player")
        return
    end
    confirmAction(state, "purgingPoolSale", soldTraitKey)
    consumeTraceStep(state, "purgingPoolSale")
end

function session.beginKeepsakeRackChange(state, keepsakeKey)
    if state.state ~= "synchronized" then return end
    local step = nextTrace(state)
    if step == nil or step.kind ~= "keepsakeRackChange" or step.keepsakeKey ~= keepsakeKey then
        mismatch(state, "keepsake-rack", { kind = "keepsake", key = step and step.keepsakeKey }, { kind = "keepsake", key = keepsakeKey }, true, "playerDivergence", "player")
        return
    end
    state.pendingRackKeepsake = keepsakeKey
    state.pendingRackResults = step.equipResults
    return step
end

function session.verifyKeepsakeRackChange(state, keepsakeKey, hero)
    local expected = state.pendingRackKeepsake
    if state.state ~= "synchronized" or expected == nil then return end
    if keepsakeKey ~= expected then
        mismatch(state, "keepsake-rack", { kind = "keepsake", key = expected }, { kind = "keepsake", key = keepsakeKey }, false)
        return
    end
    if state.pendingRackExpectedTrait ~= nil then
        local found = nil
        for _, trait in ipairs(type(hero) == "table" and hero.Traits or {}) do
            if type(trait) == "table" and trait.Name == state.pendingRackExpectedTrait then found = trait; break end
        end
        if state.pendingRackSelectionApplied ~= true or found == nil then
            mismatch(state, "keepsake-equip-result", { kind = "trait", key = state.pendingRackExpectedTrait }, { kind = "trait", key = nil }, false)
            return
        end
    end
    confirmAction(state, "keepsakeRackChange", expected)
    consumeTraceStep(state, "keepsakeRackChange")
    state.pendingRackKeepsake, state.pendingRackResults = nil, nil
    state.pendingRackExpectedTrait, state.pendingRackSelectionApplied = nil, nil
end

function session.beginRackEquipResult(state)
    local results = state.pendingRackResults
    if state.state ~= "synchronized" or type(results) ~= "table" then return nil end
    local target = results.jeweledPom and results.jeweledPom.traitKey
        or (results.experimentalHammer and results.experimentalHammer.kind == "selected" and results.experimentalHammer.traitKey)
        or (results.transcendentEmbryo and results.transcendentEmbryo.blessingKey)
    if target == nil then return nil end
    state.pendingRackExpectedTrait = target
    return target
end

function session.selectRackEquipResult(state, values)
    local expected = state.pendingRackExpectedTrait
    if state.state ~= "synchronized" or expected == nil or type(values) ~= "table" then return nil end
    for _, value in ipairs(values) do
        if value == expected then
            state.pendingRackSelectionApplied = true
            return value
        end
    end
    -- Other native helpers may select unrelated random arrays while the
    -- rack closes. Only an array containing our target is the result seam.
    return nil
end

function session.verifyRackEquipResult(state, trait)
    local expected = state.pendingRackExpectedTrait
    if state.state ~= "synchronized" or expected == nil or state.pendingRackSelectionApplied ~= true then return end
    local actual = type(trait) == "table" and (trait.Name or trait.TraitName) or nil
    if actual ~= expected then
        mismatch(state, "keepsake-equip-result", { kind = "trait", key = expected }, { kind = "trait", key = actual }, false)
        return
    end
    -- The close observer owns trace consumption. This contact proves the
    -- native equip result, but must not make a failed close look committed.
end

function session.observeFountainUse(state, observedTarget)
    if state.state ~= "synchronized" then return end
    local step = nextTrace(state)
    if step == nil or step.kind ~= "fountainUse" then
        mismatch(state, "fountain-use", { kind = "fountain", key = nil }, { kind = "fountain", key = observedTarget }, true, "playerDivergence", "player")
        return
    end
    if observedTarget ~= nil and step.aromaticPhialTarget ~= nil and step.aromaticPhialTarget ~= observedTarget then
        mismatch(state, "aromatic-phial", { kind = "trait", key = step.aromaticPhialTarget }, { kind = "trait", key = observedTarget })
        return
    end
    state.pendingFountainUse = step
    state.pendingPhialTarget = step.aromaticPhialTarget
end

function session.completeFountainUse(state)
    local step = state.pendingFountainUse
    if state.state ~= "synchronized" or step == nil then return end
    confirmAction(state, "fountainUse", step.aromaticPhialTarget)
    consumeTraceStep(state, "fountainUse")
    state.pendingFountainUse = nil
end

function session.preparePhialRarity(state, args, heroTraits)
    local targetKey = state.pendingPhialTarget
    if state.state ~= "synchronized" or targetKey == nil then return { kind = "passThrough" } end
    local target
    for _, trait in pairs(heroTraits or {}) do
        if type(trait) == "table" and (trait.Name == targetKey or trait.TraitName == targetKey) then target = trait; break end
    end
    if target == nil or type(args) ~= "table" then
        mismatch(state, "aromatic-phial", { kind = "trait", key = targetKey }, { kind = "trait", key = nil })
        return { kind = "failed" }
    end
    args.ForceUpgrade = { target }
    state.pendingPhialRarity = { target = targetKey, priorRarity = target.Rarity }
    return { kind = "handled" }
end

function session.verifyPhialRarity(state, heroTraits, returnedTrait)
    local pending = state.pendingPhialRarity
    if state.state ~= "synchronized" or pending == nil then return end
    for _, trait in pairs(heroTraits or {}) do
        if type(trait) == "table" and (trait.Name == pending.target or trait.TraitName == pending.target) then
            local expected = type(_G.GetUpgradedRarity) == "function" and _G.GetUpgradedRarity(pending.priorRarity) or nil
            if expected == nil or trait.Rarity ~= expected or type(returnedTrait) ~= "table" or returnedTrait.Name ~= pending.target then
                mismatch(state, "aromatic-phial", { kind = "rarity", key = expected }, { kind = "rarity", key = trait.Rarity }, false)
                return
            end
            state.pendingPhialTarget, state.pendingPhialRarity = nil, nil
            session.completeFountainUse(state)
            return
        end
    end
    mismatch(state, "aromatic-phial", { kind = "trait", key = pending.target }, { kind = "trait", key = nil }, false)
end

-- SetupRoomMultipleEncountersData remains responsible for cloning descriptor
-- RoomChanges and normal encounter setup.  Verify its resulting ordered list
-- after vanilla has resolved it; a plan never hand-builds Encounter records.
function session.verifyEncounterAssembly(state, currentRun, room)
    if state.state ~= "synchronized" then return end
    local matched, expected, observed = currentRoomContact(state, currentRun, room)
    if not matched then
        mismatch(state, "encounter-assembly", { kind = "room", key = expected and expected.id },
            { kind = "room", key = roomName(observed) })
        return
    end
    local actual = type(room) == "table" and room.Encounters or nil
    local phases = expected.contents and expected.contents.encounterPhases or {}
    if #phases <= 1 then return end
    if type(actual) ~= "table" then
        mismatch(state, "encounter-assembly", { kind = "phaseCount", key = #phases },
            { kind = "phaseCount", key = nil })
        return
    end
    for index, phase in ipairs(phases) do
        if encounterName(actual[index]) ~= phase.encounterKey then
            mismatch(state, "encounter-assembly", { kind = "encounter", key = phase.encounterKey },
                { kind = "encounter", key = encounterName(actual[index]) }, false)
            return
        end
    end
end

function session.beginMultipleEncounterResolution(state, currentRun, room)
    if state.state ~= "synchronized" then return end
    local matched = currentRoomContact(state, currentRun, room)
    if matched then state.encounterResolution = 0 end
end

function session.chooseResolvedEncounter(state, currentRun, room, game)
    if state.state ~= "synchronized" or state.encounterResolution == nil then return nil end
    local expected = expectedRoom(state)
    local index = state.encounterResolution + 1
    local phase = expected and expected.contents and expected.contents.encounterPhases[index] or nil
    if phase == nil or type(game) ~= "table" or type(game.EncounterData) ~= "table" then
        mismatch(state, "encounter-resolution", { kind = "encounter", key = phase and phase.encounterKey },
            { kind = "encounter", key = nil })
        return nil
    end
    local declaration = game.EncounterData[phase.encounterKey]
    if type(declaration) ~= "table" then
        mismatch(state, "encounter-resolution", { kind = "encounter", key = phase.encounterKey },
            { kind = "encounter", key = nil })
        return nil
    end
    state.encounterResolution = index
    return declaration
end

function session.endMultipleEncounterResolution(state)
    state.encounterResolution = nil
end

function session.observeBeforeRoomExit(state, currentRun)
    if state.state ~= "synchronized" or state.pendingExit == nil then return false end
    -- The hook is normally reached once.  Keeping a completed checkpoint
    -- observable makes repeated diagnostic calls harmless (and does not
    -- advance or search the trace); only an attempt to skip its predecessor
    -- is a cursor violation.
    local expected = expectedRoom(state)
    local step = expected and expected.trace and expected.trace[state.traceCursor or 1] or nil
    if not consumeTraceStep(state, "beforeRoomExit") then return false end
    return session.observeRunState(state, currentRun, "beforeRoomExit")
end

function session.observeCleanup(state, currentRun)
    if state.state ~= "synchronized" then return end
    local expected = expectedRoom(state)
    if expected == nil then return end
    local step = nextTrace(state)
    while step and step.kind == "acquireReward" do
        local required = false
        for _, role in ipairs(step.roles or {}) do if role.settlement ~= nil then required = true end end
        if required then
            mismatch(state, "acquisition-window-close", { kind = "requiredPickup", key = step.id }, { kind = "pickup", key = nil }, false, "playerDivergence", "player")
            return
        end
        consumeTraceStep(state, "acquireReward")
        step = nextTrace(state)
    end
    if step and step.kind == "cleanup" then consumeTraceStep(state, "cleanup") end
end

function session.observeExit(state, currentRun, door)
    if state.state ~= "synchronized" then return end
    local matched, expected, observed = currentRoomContact(state, currentRun)
    if not matched then
        mismatch(state, "selected-exit", { kind = "room", key = expected and expected.id }, { kind = "room", key = roomName(observed) })
        return
    end
    local outgoing = expected.outgoing
    if outgoing.kind == "terminal" then
        state.pendingExit = { sourceId = expected.id, completed = true }
        return
    end
    local room = type(door) == "table" and door.Room or nil
    local marker = type(room) == "table" and room.__runPlannerExecutionRoomId or nil
    local destination, target
    if outgoing.kind == "batch" then
        target = selectedTarget(outgoing)
        local alternate = nil
        for _, candidate in ipairs(outgoing.targets) do
            if candidate.room.id == marker then alternate = candidate; break end
        end
        local validSelected = target ~= nil and marker == target.room.id
            and generatedAll(state, outgoing)
            and type(room) == "table" and room.__runPlannerExecutionBatchOwner == outgoing.owner
            and (door == nil or door.Name == nil or target.type == "" or door.Name == target.type)
        if not validSelected then
            local disposition = alternate ~= nil and alternate ~= target
                and "playerDivergence" or "conformanceDiscrepancy"
            local agency = alternate ~= nil and alternate ~= target and "player" or "game"
            mismatch(state, "selected-exit", { kind = "exit", key = target and target.exitKey },
                { kind = "exit", key = type(room) == "table" and room.__runPlannerExecutionExitKey or nil }, true, disposition, agency)
            return
        end
        destination = state.roomsById[target.room.id]
    else
        if marker ~= outgoing.target.id then
            mismatch(state, "selected-exit", { kind = "room", key = outgoing.target.id },
                { kind = "room", key = marker or roomName(room) })
            return
        end
        destination = state.roomsById[outgoing.target.id]
    end
    if destination == nil then mismatch(state, "selected-exit", { kind = "room", key = nil }, { kind = "room", key = nil }); return end
    state.pendingExit = { sourceId = expected.id, destinationId = destination.id }
end

function session.commitExit(state)
    if state.state ~= "synchronized" or state.pendingExit == nil then return end
    local pending = state.pendingExit
    state.pendingExit = nil
    if pending.completed then
        state.state, state.reason = "completed", "extent-complete"
        return
    end
    state.currentRoomId = pending.destinationId
    state.generation, state.roomObserved, state.rewardObserved, state.traceCursor = nil, false, false, nil
end

function session.status(state)
    local mismatchState = state.firstMismatch
    return {
        state = state.state, reason = state.reason, route = state.routeKey or "none",
        planFingerprint = state.plan and state.plan.planFingerprint or "none",
        checkpoint = mismatchState and mismatchState.checkpoint or "none",
        expected = mismatchState and mismatchState.expected or "none",
        observed = mismatchState and mismatchState.observed or "none",
        disposition = mismatchState and mismatchState.disposition or "none",
        triggeringAgency = mismatchState and mismatchState.triggeringAgency or "none",
    }
end

function session.defineCache(moduleRef)
    moduleRef.cache.define({ [session.CACHE_NAME] = { domain = "currentRun", key = "execution-session", factory = newState } })
end

function session.get(runtime)
    return runtime.data.cache.currentRun.get(session.CACHE_NAME)
end

return session
