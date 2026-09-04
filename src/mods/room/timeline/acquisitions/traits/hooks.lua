-- Bounded ordinary Olympian/Hermes/Hammer offer chain. The bound native loot
-- is its sole correlation carrier; no global pending action or screen handle.
local ordinary = type(import) == "function" and import("mods/room/timeline/acquisitions/traits/ordinary.lua")
    or require("mods.room.timeline.acquisitions.traits.ordinary")

local hooks = {}

local function heroTraits()
    local hero = _G.CurrentRun and _G.CurrentRun.Hero
    return type(hero) == "table" and hero.Traits or nil
end

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

local function resolveFallback(session, _room, state, handle, payload, native)
    local offer = payload and payload.detail and payload.detail.traitOffer
    for _, fallback in ipairs(offer and offer.runtimeFallbacks or {}) do
        if fallback.availabilityContact == "traitEligibility" then
            local _, rebound, resolved = session.resolveFallback(state, handle, payload, "traitEligibility", fallback,
                function(key)
                    local declaration = _G.TraitData and _G.TraitData[key]
                    return declaration ~= nil and (type(_G.IsTraitEligible) ~= "function"
                        or _G.IsTraitEligible(declaration) == true)
                end, native)
            if rebound == nil then return nil end
            handle, payload = rebound, resolved
        end
    end
    return handle, payload
end

function hooks.attach(module, session, getState, report, room)
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
        _, payload = resolveFallback(session, room, state, handle, payload, loot)
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
        if ordinary.isCarrier(loot, offer) and reroll ~= true then ordinary.install(payload, loot) end
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
            session.complete(state, handle, ordinary.verify(payload, selected, heroTraits()), offer, selected)
            report(runtime)
        end
        return result
    end)
end

return hooks
