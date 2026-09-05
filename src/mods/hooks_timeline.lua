-- Deferred later-route NPC trait menus. F/G acquisition, Chaos, and nested
-- consequence contacts live in their focused timeline adapters.
local adapter = type(import) == "function" and import("mods/native_timeline_adapters.lua")
    or require("mods.native_timeline_adapters")
local hooks = {}

local function authoredTraitOption(offer, itemData)
    for _, option in ipairs(offer.options or {}) do
        if option.key == itemData.ItemName then return option end
    end
    return nil
end

function hooks.attach(module, session, getState, report, room)
    -- These four named menus are unreachable in F/G. Their source-specific
    -- wrappers remain until their biome routes publish complete consequences.
    local pendingDeferredNpcTrait

    local function attachNpcTraitChoice(functionName, giver)
        module.hooks.wrap(functionName, "run-planner-deferred-npc-trait-offer", function(_, runtime, base, source,
            args, screen)
            local state = getState(runtime)
            local handle = type(room.encounterHandle) == "function" and room.encounterHandle(state, source) or nil
            local payload = handle and room.begin(state, handle) or nil
            local resolution = payload and payload.transaction.resolution
            if resolution and resolution.kind == "traitOffer" and resolution.offer.giver == giver then
                if adapter.applyNpcTraitOffer(payload, args) then
                    pendingDeferredNpcTrait = { handle = handle, payload = payload }
                else
                    session.mismatch(state, "npc-trait-offer", "published " .. giver .. " trait offer", nil)
                end
            end
            local result = base(source, args, screen)
            report(runtime)
            return result
        end)
    end

    attachNpcTraitChoice("MedeaCurseChoice", "Medea")
    attachNpcTraitChoice("CirceBlessingChoice", "Circe")
    attachNpcTraitChoice("IcarusBenefitChoice", "Icarus")
    attachNpcTraitChoice("EchoChoice", "Echo")

    module.hooks.wrap("CreateUpgradeChoiceButton", "run-planner-deferred-npc-trait-option", function(_, runtime,
        base, screen, lootData, itemIndex, itemData, args)
        local pending = pendingDeferredNpcTrait
        local payload = pending and room.begin(getState(runtime), pending.handle) or pending and pending.payload
        local _, offer = adapter.expectedTrait(payload)
        if offer and type(offer.options) == "table" then
            local option = authoredTraitOption(offer, itemData)
            if option == nil then return base(screen, lootData, itemIndex, itemData, args) end
            itemData.Rarity, itemData.StackNum = option.rarity, option.effectiveLevel
            if option.replacement then
                itemData.TraitToReplace = option.replacement.replacedTraitKey
                itemData.OldRarity = option.replacement.oldRarity
            end
        end
        return base(screen, lootData, itemIndex, itemData, args)
    end)

    module.hooks.wrap("HandleUpgradeChoiceSelection", "run-planner-deferred-npc-trait-selection", function(_, runtime,
        base, screen, button, args)
        local state = getState(runtime)
        local selected = button and button.Data and button.Data.Name
        if pendingDeferredNpcTrait ~= nil then pendingDeferredNpcTrait.selected = selected end
        local result = base(screen, button, args)
        if pendingDeferredNpcTrait ~= nil then
            local pending = pendingDeferredNpcTrait
            pendingDeferredNpcTrait = nil
            local expected = adapter.expectedTrait(pending.payload)
            if expected == nil or expected.key ~= pending.selected then
                session.mismatch(state, "trait-selection", expected and expected.key, pending.selected)
            else
                session.complete(state, pending.handle)
            end
        end
        report(runtime)
        return result
    end)
end

return hooks
