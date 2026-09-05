-- Bounded ordinary Olympian/Hermes/Hammer offer chain. The bound native loot
-- is its sole correlation carrier; no global pending action or screen handle.
local ordinary = type(import) == "function" and import("mods/room/timeline/acquisitions/traits/ordinary.lua")
    or require("mods.room.timeline.acquisitions.traits.ordinary")
local chaos = type(import) == "function" and import("mods/room/timeline/acquisitions/traits/chaos.lua")
    or require("mods.room.timeline.acquisitions.traits.chaos")

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
    chaos.attach(module, session, getState, report, room)
    local allTogetherPending = {}
    local activeAllTogether = nil

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

    local function setForCandidates(pending, candidates)
        for _, setKey in ipairs({ "earth", "fire", "air", "water" }) do
            local pair = pending.pairs[setKey]
            for _, candidate in pairs(candidates or {}) do
                if candidate == pair[1] or candidate == pair[2] then return setKey end
            end
        end
        return nil
    end

    module.hooks.wrap("GetRandomValue", "run-planner-steer-all-together", function(_, runtime, base,
        candidates, rng)
        local active = activeAllTogether
        local setKey = active and setForCandidates(active, candidates) or nil
        if setKey == nil then return base(candidates, rng) end
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
            session.complete(state, handle)
        end
        report(runtime)
        return result
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
        -- Concave Stone's second native selection is a consequential residual,
        -- not another terminal for this outer acquisition.
        if type(args) == "table" and args.DoubleBoonChance then return base(screen, button, args) end
        local state = getState(runtime)
        local loot = button and button.LootData
        local current = room.current(state)
        local handle, payload = boundNormal(room, state, current, loot)
        local offer = ordinary.offer(payload)
        local selected = button and button.Data and button.Data.Name
        local allTogether = ordinary.allTogetherResult(payload)
        local pendingForSelection = nil
        if ordinary.isCarrier(loot, offer) and ordinary.selectedKey(payload) == selected
            and allTogether ~= nil then
            pendingForSelection = {
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
            allTogetherPending[handle] = pendingForSelection
        end
        local result = base(screen, button, args)
        if ordinary.isCarrier(loot, offer) then
            if ordinary.selectedKey(payload) ~= selected then
                session.mismatch(state, "trait-selection", ordinary.selectedKey(payload), selected)
            else
                local pending = pendingForSelection
                if pending == nil then
                    session.complete(state, handle)
                else
                    pending.selectionReturned = true
                    if not pending.failed and pending.settled and pending.consumed.earth and pending.consumed.fire
                        and pending.consumed.air and pending.consumed.water then
                        allTogetherPending[handle] = nil
                        session.complete(state, handle)
                    end
                end
            end
            report(runtime)
        end
        return result
    end)
end

return hooks
