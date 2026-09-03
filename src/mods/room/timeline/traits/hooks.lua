-- Bounded ordinary Olympian/Hermes/Hammer offer chain. The bound native loot
-- is its sole correlation carrier; no global pending action or screen handle.
local ordinary = type(import) == "function" and import("mods/room/timeline/traits/ordinary.lua")
    or require("mods.room.timeline.traits.ordinary")

local hooks = {}

local function heroTraits()
    local hero = _G.CurrentRun and _G.CurrentRun.Hero
    return type(hero) == "table" and hero.Traits or nil
end

local function resolveFallback(session, room, state, handle, payload, native)
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
    local producerScope

    module.hooks.wrap("SpawnRoomReward", "execution-c1-scope-ordinary-producer", function(_, runtime, base, source, args)
        local state = getState(runtime)
        local current = room.current(state)
        local reward = current and current.occurrence.overview.incomingReward
        local prior = producerScope
        if current and reward then
            producerScope = {
                state = state, current = current,
                handle = room.resolve(state, current, {
                    kind = "producer", producerLifecycleKey = reward.producerLifecycleKey,
                    rewardType = reward.rewardType,
                }),
            }
        end
        local ok, result = pcall(base, source, args)
        producerScope = prior
        if not ok then error(result, 0) end
        return result
    end)

    module.hooks.wrap("CreateLoot", "execution-c1-bind-ordinary-loot", function(_, runtime, base, args)
        local result = base(args)
        local scope = producerScope
        if scope and ordinary.isNativeCarrier(result) then
            local handle = room.resolve(scope.state, scope.current, {
                kind = "materialized", source = scope.handle, gameName = result.Name,
            })
            room.bind(scope.state, scope.current, handle, result)
            -- One producer materializes one C1 loot carrier. Do not let a
            -- later BonusLoot/trait consequence inherit this source scope.
            if producerScope == scope then producerScope = nil end
        end
        return result
    end)

    module.hooks.wrap("HandleLootPickup", "execution-c1-begin-ordinary-loot", function(_, runtime, base, currentRun, loot, args)
        if not ordinary.isNativeCarrier(loot) then return base(currentRun, loot, args) end
        local state = getState(runtime)
        local current = room.current(state)
        local handle = current and room.bound(state, current, loot) or nil
        local payload = handle and room.begin(state, handle) or nil
        handle, payload = resolveFallback(session, room, state, handle, payload, loot)
        local offer = ordinary.offer(payload)
        if not ordinary.isCarrier(loot, offer) then return base(currentRun, loot, args) end
        local result = base(currentRun, loot, args)
        report(runtime)
        return result
    end)

    module.hooks.wrap("CreateBoonLootButtons", "execution-c1-install-ordinary-offer", function(_, runtime, base, screen, loot, reroll, args)
        local state = getState(runtime)
        local current = room.current(state)
        local handle = current and room.bound(state, current, loot) or nil
        local payload = handle and room.begin(state, handle) or nil
        local offer = ordinary.offer(payload)
        -- A native reroll intentionally abandons the frozen initial offer.
        if ordinary.isCarrier(loot, offer) and reroll ~= true then ordinary.install(payload, loot) end
        return base(screen, loot, reroll, args)
    end)

    module.hooks.wrap("CreateUpgradeChoiceButton", "execution-c1-align-ordinary-rejected", function(_, runtime, base, screen, loot, index, item, args)
        local state = getState(runtime)
        local current = room.current(state)
        local handle = current and room.bound(state, current, loot) or nil
        local payload = handle and room.begin(state, handle) or nil
        if index == 1 and ordinary.isCarrier(loot, ordinary.offer(payload)) then ordinary.alignRejected(payload, screen, loot) end
        return base(screen, loot, index, item, args)
    end)

    module.hooks.wrap("HandleUpgradeChoiceSelection", "execution-c1-complete-ordinary-offer", function(_, runtime, base, screen, button, args)
        -- Concave Stone's second native selection is a consequential residual,
        -- not another terminal for this outer acquisition.
        if type(args) == "table" and args.DoubleBoonChance then return base(screen, button, args) end
        local state = getState(runtime)
        local loot = button and button.LootData
        local current = room.current(state)
        local handle = current and room.bound(state, current, loot) or nil
        local payload = handle and room.begin(state, handle) or nil
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
