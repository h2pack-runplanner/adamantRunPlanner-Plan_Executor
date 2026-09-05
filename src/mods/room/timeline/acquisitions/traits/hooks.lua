-- Bounded ordinary Olympian/Hermes/Hammer offer chain. The bound native loot
-- is its sole correlation carrier; no global pending action or screen handle.
local ordinary = type(import) == "function" and import("mods/room/timeline/acquisitions/traits/ordinary.lua")
    or require("mods.room.timeline.acquisitions.traits.ordinary")
local chaosOffer = type(import) == "function"
        and import("mods/room/timeline/acquisitions/traits/chaos_offer.lua")
    or require("mods.room.timeline.acquisitions.traits.chaos_offer")
local seaStar = type(import) == "function" and import("mods/room/timeline/acquisitions/sea_star.lua")
    or require("mods.room.timeline.acquisitions.sea_star")
local concaveStoneModule = type(import) == "function" and import("mods/keepsakes/concave_stone.lua")
    or require("mods.keepsakes.concave_stone")

local hooks = {}

local function nativeName(value)
    return type(value) == "table" and (value.Name or value.ItemName or value.LootName) or nil
end

local function boundNormal(room, state, current, native)
    local handle = current and room.bound(state, current, native) or nil
    if handle == nil or type(room.peek) ~= "function" then return handle, nil end
    local payload = room.peek(state, handle)
    if not ordinary.isNormalPayload(payload) then return handle, nil end
    return handle, room.begin(state, handle)
end

function hooks.attach(module, session, getState, report, room)
    chaosOffer.attach(module, session, getState, report, room)
    local allTogetherPending = {}
    local activeAllTogether = nil
    local naturalSelectionPending = {}
    local activeNaturalDistribution = nil
    local targetedAcquisitionPending = {}
    local activeTargetedAcquisition = nil
    local activeTargetedRarity = nil
    local concaveStone = concaveStoneModule.create({
        module = module, session = session, getState = getState, room = room, ordinary = ordinary,
    })

    local function scopeIsCurrent(state, pending)
        return pending ~= nil and pending.context == room.current(state) and state.state == "synchronized"
    end

    -- C1 remains the only terminal. D3/D4 and Concave Stone merely delay it
    -- while their bounded native callbacks are still in flight.
    local function completeOuter(state, handle)
        concaveStone.completeOuter(state, handle)
    end

    local function discardPending(pending)
        if pending == nil then return end
        allTogetherPending[pending.handle] = nil
        if activeAllTogether == pending then activeAllTogether = nil end
    end

    local function pendingFor(state, originalTraitData)
        local traitKey = type(originalTraitData) == "table" and originalTraitData.Name or nil
        for handle, pending in pairs(allTogetherPending) do
            if pending.outerKey == traitKey and pending.context == room.current(state)
                and state.state == "synchronized" then
                return handle, pending
            end
        end
        return nil
    end

    local function discardNaturalSelection(pending)
        if pending == nil then return end
        naturalSelectionPending[pending.handle] = nil
        if activeNaturalDistribution == pending then activeNaturalDistribution = nil end
    end

    local function completeNaturalSelection(state, pending)
        if not pending.failed and pending.selectionReturned and pending.settled
            and pending.cursor == #pending.targets then
            naturalSelectionPending[pending.handle] = nil
            completeOuter(state, pending.handle)
        end
    end

    local function pendingForNative(state, pendingByHandle, originalTraitData)
        local traitKey = type(originalTraitData) == "table" and originalTraitData.Name or nil
        for _, pending in pairs(pendingByHandle) do
            if pending.outerKey == traitKey and scopeIsCurrent(state, pending) then return pending end
        end
        return nil
    end

    local function discardTargetedAcquisition(pending)
        if pending == nil then return end
        targetedAcquisitionPending[pending.handle] = nil
        if activeTargetedAcquisition == pending then activeTargetedAcquisition = nil end
        if activeTargetedRarity == pending then activeTargetedRarity = nil end
    end

    local function completeTargetedAcquisition(state, pending)
        if not pending.failed and pending.selectionReturned and pending.settled and pending.contacted then
            targetedAcquisitionPending[pending.handle] = nil
            completeOuter(state, pending.handle)
        end
    end

    local function setForCandidates(pending, candidates)
        for _, setKey in ipairs({ "earth", "fire", "air", "water" }) do
            local pair = pending.pairs[setKey]
            for _, candidate in pairs(candidates or {}) do
                if candidate == pair[1] or candidate == pair[2] then return setKey end
            end
        end
        return nil
    end

    local function consequenceScopes(payload, loot, offer, selected, handle, current)
        local allTogether = ordinary.allTogetherResultForKey(payload, selected)
        local naturalSelectionTargets = ordinary.naturalSelectionTargetsForKey(payload, selected)
        local allTogetherForSelection = nil
        local naturalSelectionForSelection = nil
        if ordinary.isCarrier(loot, offer) and allTogether ~= nil then
            allTogetherForSelection = {
                outerKey = selected,
                handle = handle,
                context = current,
                result = allTogether,
                consumed = {
                    earth = ordinary.isNull(allTogether.earth),
                    fire = ordinary.isNull(allTogether.fire),
                    air = ordinary.isNull(allTogether.air),
                    water = ordinary.isNull(allTogether.water),
                },
                selectionReturned = false,
            }
            allTogetherPending[handle] = allTogetherForSelection
        end
        if ordinary.isCarrier(loot, offer) and naturalSelectionTargets ~= nil then
            naturalSelectionForSelection = {
                handle = handle,
                outerKey = selected,
                context = current,
                targets = naturalSelectionTargets,
                cursor = 0,
                selectionReturned = false,
                settled = false,
                shuffled = false,
            }
        end
        local targetTraitKey = ordinary.targetTraitKeyForKey(payload, selected)
        local targetedAcquisitionForSelection = nil
        if ordinary.isCarrier(loot, offer) and targetTraitKey ~= nil then
            targetedAcquisitionForSelection = {
                handle = handle,
                outerKey = selected,
                context = current,
                target = targetTraitKey,
                contacted = false,
            }
        end
        return allTogetherForSelection, naturalSelectionForSelection, targetedAcquisitionForSelection
    end

    local function runSelectionCallback(_, callback, naturalSelectionForSelection,
        targetedAcquisitionForSelection)
        local result
        if naturalSelectionForSelection ~= nil or targetedAcquisitionForSelection ~= nil then
            if naturalSelectionForSelection ~= nil then
                naturalSelectionPending[naturalSelectionForSelection.handle] = naturalSelectionForSelection
            end
            if targetedAcquisitionForSelection ~= nil then
                targetedAcquisitionPending[targetedAcquisitionForSelection.handle] = targetedAcquisitionForSelection
            end
            local ok
            ok, result = pcall(callback)
            if not ok then
                discardNaturalSelection(naturalSelectionForSelection)
                discardTargetedAcquisition(targetedAcquisitionForSelection)
                error(result, 0)
            end
        else
            result = callback()
        end
        return result
    end

    local function callSelectionBase(state, base, screen, button, args, naturalSelectionForSelection,
        targetedAcquisitionForSelection)
        return runSelectionCallback(state, function() return base(screen, button, args) end,
            naturalSelectionForSelection, targetedAcquisitionForSelection)
    end

    local function settleSelection(state, payload, loot, offer, selected, handle, allTogetherForSelection,
        naturalSelectionForSelection, targetedAcquisitionForSelection, residual)
        if not ordinary.isCarrier(loot, offer) then return end
        if not residual and ordinary.selectedKey(payload) ~= selected then
            session.mismatch(state, "trait-selection", ordinary.selectedKey(payload), selected)
            return
        end
        if allTogetherForSelection == nil and naturalSelectionForSelection == nil
            and targetedAcquisitionForSelection == nil then
            completeOuter(state, handle)
        elseif allTogetherForSelection ~= nil then
            allTogetherForSelection.selectionReturned = true
            if not allTogetherForSelection.failed and allTogetherForSelection.settled
                and allTogetherForSelection.consumed.earth and allTogetherForSelection.consumed.fire
                and allTogetherForSelection.consumed.air and allTogetherForSelection.consumed.water then
                allTogetherPending[handle] = nil
                completeOuter(state, handle)
            end
        elseif naturalSelectionForSelection ~= nil then
            naturalSelectionForSelection.selectionReturned = true
            completeNaturalSelection(state, naturalSelectionForSelection)
        elseif targetedAcquisitionForSelection ~= nil then
            targetedAcquisitionForSelection.selectionReturned = true
            completeTargetedAcquisition(state, targetedAcquisitionForSelection)
        end
    end

    module.hooks.wrap("GetRandomValue", "run-planner-steer-all-together", function(_, runtime, base,
        candidates, rng)
        local active = activeAllTogether
        local setKey = active and setForCandidates(active, candidates) or nil
        if setKey == nil then return concaveStone.steerResidual(runtime, base, candidates, rng) end
        local state = getState(runtime)
        local expected = active.result[setKey]
        if ordinary.isNull(expected) then
            active.failed = true
            discardPending(active)
            session.mismatch(state, "all-together-grant", "exhausted " .. setKey, candidates)
            return base(candidates, rng)
        end
        local found = false
        for _, candidate in pairs(candidates or {}) do
            if candidate == expected then found = true; break end
        end
        if not found then
            active.failed = true
            discardPending(active)
            session.mismatch(state, "all-together-grant", expected, "native-ineligible")
            return base(candidates, rng)
        end
        active.consumed[setKey] = true
        return expected
    end)

    module.hooks.wrap("GrantBoons", "run-planner-complete-all-together", function(_, runtime, base,
        args, originalTraitData)
        local state = getState(runtime)
        local handle, pending = pendingFor(state, originalTraitData)
        if pending == nil then return base(args, originalTraitData) end
        pending.pairs = {
            earth = args and args.BoonSets and args.BoonSets[1] or {},
            fire = args and args.BoonSets and args.BoonSets[2] or {},
            air = args and args.BoonSets and args.BoonSets[3] or {},
            water = args and args.BoonSets and args.BoonSets[4] or {},
        }
        activeAllTogether = pending
        local ok, result = pcall(base, args, originalTraitData)
        activeAllTogether = nil
        if not ok then
            discardPending(pending)
            error(result, 0)
        end
        for _, setKey in ipairs({ "earth", "fire", "air", "water" }) do
            if not pending.failed and not ordinary.isNull(pending.result[setKey]) and not pending.consumed[setKey] then
                pending.failed = true
                discardPending(pending)
                session.mismatch(state, "all-together-grant", pending.result[setKey], "missing")
            end
        end
        pending.settled = true
        if not pending.failed and pending.selectionReturned and pending.consumed.earth and pending.consumed.fire
            and pending.consumed.air and pending.consumed.water then
            allTogetherPending[handle] = nil
            completeOuter(state, handle)
        end
        report(runtime)
        return result
    end)

    -- Natural Selection's one native shuffle determines every later round.
    -- The published successful sequence supplies its first-appearance order;
    -- entries absent from that sequence remain so native cap condemnation can
    -- remove them at the same point as vanilla.
    module.hooks.wrap("FYShuffle", "run-planner-steer-natural-selection-order", function(_, runtime, base,
        candidates)
        local pending = activeNaturalDistribution
        if pending == nil then return base(candidates) end
        if pending.shuffled then return base(candidates) end
        local state = getState(runtime)
        local available, ordered = {}, {}
        for _, candidate in ipairs(candidates or {}) do available[candidate] = true end
        local seen = {}
        for _, target in ipairs(pending.targets) do
            if not seen[target] then
                if not available[target] then
                    pending.failed = true
                    discardNaturalSelection(pending)
                    session.mismatch(state, "natural-selection-order", target, "native-ineligible")
                    return base(candidates)
                end
                seen[target] = true
                ordered[#ordered + 1] = target
            end
        end
        for _, candidate in ipairs(candidates or {}) do
            if not seen[candidate] then ordered[#ordered + 1] = candidate end
        end
        pending.shuffled = true
        return ordered
    end)

    module.hooks.wrap("IncreaseTraitLevel", "run-planner-consume-natural-selection-target", function(_, runtime,
        base, trait, ...)
        local pending = activeNaturalDistribution
        if pending ~= nil then
            local state = getState(runtime)
            local actual = type(trait) == "table" and trait.Name or nil
            local expected = pending.targets[pending.cursor + 1]
            if expected == nil then
                pending.failed = true
                discardNaturalSelection(pending)
                session.mismatch(state, "natural-selection-target", "end-of-sequence", actual)
            elseif actual ~= expected then
                pending.failed = true
                discardNaturalSelection(pending)
                session.mismatch(state, "natural-selection-target", expected, actual)
            else
                pending.cursor = pending.cursor + 1
            end
        end
        return base(trait, ...)
    end)

    module.hooks.wrap("DistributeLevels", "run-planner-complete-natural-selection", function(_, runtime, base,
        args, originalTraitData)
        local state = getState(runtime)
        local pending = pendingForNative(state, naturalSelectionPending, originalTraitData)
        if pending == nil then return base(args, originalTraitData) end
        pending.started = true
        activeNaturalDistribution = pending
        local ok, result = pcall(base, args, originalTraitData)
        activeNaturalDistribution = nil
        if not ok then
            discardNaturalSelection(pending)
            error(result, 0)
        end
        if not pending.failed and not pending.shuffled then
            pending.failed = true
            discardNaturalSelection(pending)
            session.mismatch(state, "natural-selection-order", "FYShuffle", "missing")
        end
        if not pending.failed and pending.cursor < #pending.targets then
            pending.failed = true
            discardNaturalSelection(pending)
            session.mismatch(state, "natural-selection-target", pending.targets[pending.cursor + 1], "missing")
        end
        pending.settled = true
        completeNaturalSelection(state, pending)
        report(runtime)
        return result
    end)

    -- Bridal Glow's acquire function runs on the native AddTraitToHero thread.
    -- Keep the exact selected outer trait's scope pending until that terminal
    -- function returns; only its AddRarityToTraits choice may consume the
    -- published target.
    module.hooks.wrap("HeraSuperchargeBoon", "run-planner-complete-targeted-acquisition", function(_, runtime,
        base, args, originalTraitData, contextArgs)
        local state = getState(runtime)
        local pending = pendingForNative(state, targetedAcquisitionPending, originalTraitData)
        if pending == nil then return base(args, originalTraitData, contextArgs) end
        pending.started = true
        local prior = activeTargetedAcquisition
        activeTargetedAcquisition = pending
        local ok, result = pcall(base, args, originalTraitData, contextArgs)
        activeTargetedAcquisition = prior
        if not ok then
            discardTargetedAcquisition(pending)
            error(result, 0)
        end
        if not pending.contacted then
            session.mismatch(state, "targeted-acquisition-target", pending.target, "missing native selection")
            discardTargetedAcquisition(pending)
        else
            pending.settled = true
            completeTargetedAcquisition(state, pending)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("AddRarityToTraits", "run-planner-scope-targeted-acquisition-rarity", function(_, runtime,
        base, source, args)
        local pending = activeTargetedAcquisition
        if pending == nil then return base(source, args) end
        local state = getState(runtime)
        if not scopeIsCurrent(state, pending) then
            discardTargetedAcquisition(pending)
            return base(source, args)
        end
        local prior = activeTargetedRarity
        activeTargetedRarity = pending
        local ok, result = pcall(base, source, args)
        activeTargetedRarity = prior
        if not ok then error(result, 0) end
        return result
    end)

    module.hooks.wrap("RemoveRandomValue", "run-planner-steer-targeted-acquisition", function(_, runtime, base,
        values, ...)
        local pending = activeTargetedRarity
        if pending == nil then return base(values, ...) end
        local state = getState(runtime)
        if not scopeIsCurrent(state, pending) then
            discardTargetedAcquisition(pending)
            return base(values, ...)
        end
        for index, value in ipairs(values or {}) do
            if type(value) == "table" and value.Name == pending.target then
                pending.contacted = true
                table.remove(values, index)
                return value
            end
        end
        return base(values, ...)
    end)

    module.hooks.wrap("HandleLootPickup", "run-planner-begin-ordinary-loot", function(_, runtime, base,
        currentRun, loot, args)
        if not ordinary.isNativeCarrier(loot) then return base(currentRun, loot, args) end
        local state = getState(runtime)
        local current = room.current(state)
        local handle = current and room.bound(state, current, loot) or nil
        local payload = handle and type(room.peek) == "function" and room.peek(state, handle) or nil
        if handle ~= nil and not ordinary.isNormalPayload(payload) then
            return base(currentRun, loot, args)
        end
        if handle ~= nil then
            payload = room.begin(state, handle)
        elseif current ~= nil and type(room.claimReady) == "function" then
            local claimedHandle = room.claimReady(state, current, {
                kind = "ordinaryTrait", gameName = nativeName(loot),
            }, loot, ordinary.normalRole)
            handle = claimedHandle
            payload = handle and room.begin(state, handle) or nil
        end
        if handle ~= nil and payload == nil then return base(currentRun, loot, args) end
        if handle ~= nil and not ordinary.isNormalPayload(payload) then
            return base(currentRun, loot, args)
        end
        local offer = ordinary.offer(payload)
        if not ordinary.isCarrier(loot, offer) then return base(currentRun, loot, args) end
        local result = base(currentRun, loot, args)
        report(runtime)
        return result
    end)

    module.hooks.wrap("CreateBoonLootButtons", "run-planner-install-ordinary-offer", function(_, runtime, base,
        screen, loot, reroll, args)
        local state = getState(runtime)
        local current = room.current(state)
        local _, payload = boundNormal(room, state, current, loot)
        local offer = ordinary.offer(payload)
        -- A native reroll intentionally abandons the frozen initial offer.
        if ordinary.isCarrier(loot, offer) and reroll ~= true then
            if ordinary.nativeRowsAvailable(offer) then
                ordinary.install(payload, loot)
            else
                session.mismatch(state, "trait-availability", "authored native rows", nativeName(loot))
            end
        end
        return base(screen, loot, reroll, args)
    end)

    module.hooks.wrap("CreateUpgradeChoiceButton", "run-planner-align-ordinary-rejected", function(_, runtime,
        base, screen, loot, index, item, args)
        local state = getState(runtime)
        local current = room.current(state)
        local _, payload = boundNormal(room, state, current, loot)
        if index == 1 and ordinary.isCarrier(loot, ordinary.offer(payload)) then
            ordinary.alignRejected(payload, screen, loot)
        end
        return base(screen, loot, index, item, args)
    end)

    module.hooks.wrap("HandleUpgradeChoiceSelection", "run-planner-complete-ordinary-offer", function(_, runtime,
        base, screen, button, args)
        local state = getState(runtime)
        local loot = button and button.LootData
        local current = room.current(state)
        local handle, payload = boundNormal(room, state, current, loot)
        local offer = ordinary.offer(payload)
        local selected = button and button.Data and button.Data.Name
        local seaStarScope = seaStar.scope(state, payload)
        local nested = type(args) == "table" and args.DoubleBoonChance == true
        if nested then
            local stone = concaveStone.active()
            local valid, pending = concaveStone.validateResidual(state, button, selected)
            if valid == nil or not valid then return base(screen, button, args) end
            local pendingForSelection, naturalSelectionForSelection,
                targetedAcquisitionForSelection = consequenceScopes(
                payload, loot, offer, selected, handle, current)
            local ok, result = pcall(callSelectionBase, state, base, screen, button, args,
                naturalSelectionForSelection, targetedAcquisitionForSelection)
            if not ok then
                stone.failed = true
                concaveStone.discard(stone)
                error(result, 0)
            end
            concaveStone.markResidualReturned(pending)
            settleSelection(
                state,
                payload,
                loot,
                offer,
                selected,
                handle,
                pendingForSelection,
                naturalSelectionForSelection,
                targetedAcquisitionForSelection,
                true
            )
            report(runtime)
            return result
        end

        if not ordinary.isCarrier(loot, offer) or ordinary.selectedKey(payload) ~= selected then
            local result = base(screen, button, args)
            if ordinary.isCarrier(loot, offer) then
                session.mismatch(state, "trait-selection", ordinary.selectedKey(payload), selected)
                report(runtime)
            end
            return result
        end

        local pendingForSelection, naturalSelectionForSelection, targetedAcquisitionForSelection = consequenceScopes(
            payload, loot, offer, selected, handle, current)
        local concaveResult = ordinary.concaveStoneResult(payload)
        local stone = nil
        if concaveResult ~= nil then
            stone = concaveStone.begin(handle, current, payload, concaveResult)
        end
        local ok, result = pcall(function()
            return seaStar.call(seaStarScope, function()
                return callSelectionBase(state, base, screen, button, args, naturalSelectionForSelection,
                    targetedAcquisitionForSelection)
            end, session.mismatch)
        end)
        if not ok then
            if stone ~= nil then
                stone.failed = true
                concaveStone.discard(stone)
            end
            error(result, 0)
        end
        if stone ~= nil then
            concaveStone.finishOuter(state, stone)
        end
        settleSelection(
            state,
            payload,
            loot,
            offer,
            selected,
            handle,
            pendingForSelection,
            naturalSelectionForSelection,
            targetedAcquisitionForSelection,
            false
        )
        report(runtime)
        return result
    end)

    return {
        -- Echo's native nested Boon menu is not an ordinary loot carrier, but
        -- its selected trait still uses the same bounded consequence path.
        runExternalSelection = function(runtime, payload, selected, handle, current, callback)
            local state = getState(runtime)
            local offer = ordinary.offer(payload)
            local carrier = { GodLoot = true }
            local allTogetherForSelection, naturalSelectionForSelection,
                targetedAcquisitionForSelection = consequenceScopes(
                payload, carrier, offer, selected, handle, current)
            local result = runSelectionCallback(state, callback, naturalSelectionForSelection,
                targetedAcquisitionForSelection)
            settleSelection(state, payload, carrier, offer, selected, handle,
                allTogetherForSelection, naturalSelectionForSelection, targetedAcquisitionForSelection, false)
            report(runtime)
            return result
        end,
    }
end

return hooks
