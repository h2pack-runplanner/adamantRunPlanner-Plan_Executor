-- Native Artificer source transformation.  Native code owns eligibility,
-- charge and reward-bag mutation, replacement construction, requiredness,
-- Forfeit, and source destruction.  This adapter only steers the published
-- replacement reward and observes the bounded materialization terminal.
local artificer = {}

local function nativeName(value)
    return type(value) == "table" and (value.Name or value.ItemName or value.LootName) or nil
end

local function roleFor(transaction, contact)
    if type(transaction) ~= "table" or transaction.kind ~= "acquisition" then return nil end
    for _, role in ipairs(transaction.roles or {}) do
        if role.gameName == contact.gameName and role.disposition == "artificer" then return role end
    end
    return nil
end

local function boundRole(payload, gameName)
    local detail = payload and payload.detail
    if type(detail) ~= "table" or detail.gameName ~= gameName or detail.disposition ~= "artificer" then
        return nil
    end
    return detail
end

local function claimSource(state, current, native, room)
    if current == nil or native == nil then return nil end
    local contact = { gameName = nativeName(native) }
    local handle = room.bound(state, current, native)
    if handle ~= nil then
        local payload = type(room.peek) == "function" and room.peek(state, handle) or nil
        -- An already-correlated native object belongs to that published
        -- owner, even when its disposition is not Artificer.  Ready claiming
        -- is deliberately unbound-only; never rebind a normal carrier merely
        -- because this presentation also occurred.
        return handle, payload
    end
    if type(room.claimReady) ~= "function" then return nil end
    return room.claimReady(state, current, {
        kind = "artificer", gameName = contact.gameName,
    }, native, roleFor)
end

local function childFor(state, current, sourceHandle, sourcePayload, source, room)
    local sourceRole = room.sourceRole(state, current, sourceHandle, nativeName(source))
    if sourceRole == nil then return nil end
    local child = room.resolve(state, current, {
        kind = "produced", source = sourceHandle, role = sourceRole,
    })
    if child ~= nil and type(room.peek) == "function" then return child, room.peek(state, child) end
    -- A replacement child consumed by Time Piece is intentionally absent from
    -- the execution DAG.  The source role carries the exact native
    -- materialization and reward steering payload needed at this contact.
    local replacement = sourcePayload and sourcePayload.detail
        and sourcePayload.detail.replacement
    if type(replacement) ~= "table" then return nil end
    return nil, {
        transaction = { reward = replacement.reward },
        detail = { gameName = replacement.gameName },
    }
end

local function hasNativeExclusions(exclusions)
    if type(exclusions) ~= "table" then return false end
    local found, count = {}, 0
    for key, value in pairs(exclusions) do
        if type(key) ~= "number" or key < 1 or key > 2 or key % 1 ~= 0
            or type(value) ~= "table" then
            return false
        end
        local exclusion = value.RewardType
        if exclusion ~= "Devotion" and exclusion ~= "SpellDrop" or found[exclusion] then return false end
        found[exclusion] = true
        count = count + 1
    end
    return count == 2 and found.Devotion and found.SpellDrop
end

local function isNativeRewardChoice(rewardStore, exclusions, args)
    local ignoresForcedReward = args == true
        or type(args) == "table" and args.IgnoreForcedReward == true
    return rewardStore == "RunProgress"
        and hasNativeExclusions(exclusions)
        and ignoresForcedReward
end

function artificer.attach(module, session, getState, report, room)
    local pending = {}
    local rewardSelections = {}
    local activeSpawn

    local function discardSelection(selection)
        for index = #rewardSelections, 1, -1 do
            if rewardSelections[index] == selection then
                table.remove(rewardSelections, index)
                return
            end
        end
    end

    local function discardAction(action)
        if action == nil then return end
        discardSelection(action.selection)
        if pending[action.objectId] == action then pending[action.objectId] = nil end
    end

    local function failSpawn(action, observed)
        if action == nil or action.spawnFailure then return end
        action.spawnFailure = true
        local expected = action.childPayload and action.childPayload.detail
        expected = expected and expected.gameName or "published Artificer replacement"
        session.mismatch(action.state, "artificer-replacement", expected, observed)
    end

    local function observeReplacement(action, result)
        if action == nil or result == nil or action.spawned then return end
        action.spawned = true
        local expected = action.childPayload and action.childPayload.detail
        expected = expected and expected.gameName or nil
        local observed = nativeName(result)
        action.spawnVerified = expected ~= nil and expected == observed
        if not action.spawnVerified then failSpawn(action, observed) end
    end

    module.hooks.wrap("ConvertMetaRewardPresentation", "run-planner-artificer-accepted", function(_, runtime,
        base, target)
        local state = getState(runtime)
        local current = room.current(state)
        local sourceHandle, sourcePayload = claimSource(state, current, target, room)
        local child, childPayload
        if sourceHandle ~= nil and boundRole(sourcePayload, nativeName(target)) ~= nil then
            child, childPayload = childFor(state, current, sourceHandle, sourcePayload, target, room)
            if childPayload ~= nil then sourcePayload = room.begin(state, sourceHandle) end
            if sourcePayload == nil then sourceHandle, child, childPayload = nil, nil, nil end
        else
            sourceHandle, sourcePayload = nil, nil
        end
        local action, selection
        if sourceHandle ~= nil and sourcePayload ~= nil and childPayload ~= nil
            and type(target) == "table" and target.ObjectId ~= nil then
            action = {
                state = state, handle = sourceHandle, sourcePayload = sourcePayload,
                child = child, childPayload = childPayload, source = target,
                objectId = target.ObjectId, spawned = false, spawnVerified = false,
            }
            pending[target.ObjectId] = action
            selection = { action = action, payload = childPayload }
            action.selection = selection
            rewardSelections[#rewardSelections + 1] = selection
        end
        -- The native conversion presentation returns before its caller invokes
        -- ChooseRoomReward. Keep this exact child request alive across that
        -- return; the capability below consumes it only at that native contact.
        local ok, result = pcall(base, target)
        if not ok then
            discardAction(action)
            error(result, 0)
        end
        if result == false then discardAction(action) end
        report(runtime)
        return result
    end)

    local function observeCreatedReplacement(runtime, result)
        if activeSpawn ~= nil then observeReplacement(activeSpawn, result) end
        report(runtime)
        return result
    end

    module.hooks.wrap("CreateLoot", "run-planner-artificer-replacement-loot", function(_, runtime, base, args)
        local result = base(args)
        return observeCreatedReplacement(runtime, result)
    end)

    module.hooks.wrap("CreateConsumableItem", "run-planner-artificer-replacement-consumable",
        function(_, runtime, base, ...)
            local result = base(...)
            return observeCreatedReplacement(runtime, result)
        end)

    module.hooks.wrap("SpawnRoomReward", "run-planner-artificer-replacement-spawn", function(_, runtime, base,
        eventSource, args)
        local sourceId = type(args) == "table" and args.IgnoreRoomSpawnOnLootPoint == true
            and args.SpawnRewardOnId or nil
        local action = sourceId and pending[sourceId]
        local prior = activeSpawn
        activeSpawn = action
        local ok, result = pcall(base, eventSource, args)
        activeSpawn = prior
        if not ok then
            discardAction(action)
            error(result, 0)
        end
        -- A native Artificer choice occurs before this spawn. If no exact
        -- choice consumed the request, this bounded action has failed; do not
        -- let its selection leak into a later unrelated reward choice.
        if action ~= nil then discardSelection(action.selection) end
        -- Some native versions return the created carrier directly; the
        -- normal path is observed through CreateLoot/CreateConsumableItem.
        observeReplacement(action, result)
        if action ~= nil and not action.spawned then failSpawn(action, nil) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("Destroy", "run-planner-artificer-source-destroyed", function(_, runtime, base, args)
        local result = base(args)
        local objectId = type(args) == "table" and args.Id or nil
        local action = objectId and pending[objectId]
        if action ~= nil then
            if result ~= false and action.spawnVerified then
                discardAction(action)
                room.complete(action.state, action.handle)
            else
                discardAction(action)
            end
            report(runtime)
        end
        return result
    end)

    return {
        consumeRewardSelection = function(_run, _nativeRoom, rewardStore, exclusions, args)
            local selection = rewardSelections[#rewardSelections]
            if selection == nil or not isNativeRewardChoice(rewardStore, exclusions, args) then return nil end
            table.remove(rewardSelections)
            return selection.payload
        end,
    }
end

return artificer
