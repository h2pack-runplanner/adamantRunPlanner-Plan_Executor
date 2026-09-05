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
        local result = base(screen, button, args)
        if ordinary.isCarrier(loot, offer) then
            if ordinary.selectedKey(payload) ~= selected then
                session.mismatch(state, "trait-selection", ordinary.selectedKey(payload), selected)
            else
                session.complete(state, handle)
            end
            report(runtime)
        end
        return result
    end)
end

return hooks
