-- Consequential acquisition and trait transaction contacts.
local adapter = type(import) == "function" and import("mods/native_timeline_adapters.lua")
    or require("mods/native_timeline_adapters")
local chaos = type(import) == "function" and import("mods/chaos.lua") or require("mods/chaos")
local hooks = {}

local function authoredOptionIndex(optionKey)
    return type(optionKey) == "string" and tonumber(optionKey:match("(%d+)$")) or nil
end

local function authoredTraitKey(offer, index)
    local option = offer.options and offer.options[index]
    if option == nil then return nil end
    return option.key
end

local function physicalTraitIndex(lootData, offer, optionKey)
    local authoredIndex = authoredOptionIndex(optionKey)
    local traitKey = authoredIndex and authoredTraitKey(offer, authoredIndex)
    if traitKey == nil then return nil end
    for index, option in ipairs(lootData and lootData.UpgradeOptions or {}) do
        if option.ItemName == traitKey then return index end
    end
    return nil
end

local function alignBlockedTraitOption(screen, lootData, offer)
    if type(screen) ~= "table" or type(screen.BlockedIndexes) ~= "table"
        or type(offer) ~= "table" or type(offer.options) ~= "table" then
        return
    end

    local rejectedIndex = physicalTraitIndex(lootData, offer, offer.rejected)
    if rejectedIndex ~= nil then
        screen.BlockedIndexes = { rejectedIndex }
        return
    end

    local selectedIndex = physicalTraitIndex(lootData, offer, offer.selected)
    if selectedIndex == nil then return end

    local selectedBlockPosition
    local blocked = {}
    for position, index in ipairs(screen.BlockedIndexes) do
        blocked[index] = true
        if index == selectedIndex then selectedBlockPosition = position end
    end
    if selectedBlockPosition == nil then return end

    for index = 1, #offer.options do
        if index ~= selectedIndex and not blocked[index] then
            screen.BlockedIndexes[selectedBlockPosition] = index
            return
        end
    end
    table.remove(screen.BlockedIndexes, selectedBlockPosition)
end

local function authoredTraitOption(offer, itemData)
    for index, option in ipairs(offer.options or {}) do
        if authoredTraitKey(offer, index) == itemData.ItemName then return option end
    end
    return nil
end

local function isOrdinaryTraitCarrier(value)
    return type(value) == "table" and (value.GodLoot == true or value.Name == "HermesUpgrade"
        or value.Name == "WeaponUpgrade")
end

local function incomingHandle(room, _, state, native)
    local current = room.current(state)
    if current == nil then return nil end
    local reward = current.occurrence.overview.incomingReward
    if reward == nil then return nil end
    local producer = room.resolve(state, current, {
        kind = "producer", producerLifecycleKey = reward.producerLifecycleKey, rewardType = reward.rewardType,
    })
    local gameName = type(native) == "table" and (native.Name or native.ItemName or native.LootName) or nil
    return room.bind(state, current, room.resolve(state, current, {
        kind = "materialized", source = producer, gameName = gameName,
    }), native)
end

function hooks.attach(module, session, getState, report, room)
    local roomCoordinator = room
    -- Legacy trait screens outside the focused acquisition adapters retain
    -- their existing screen-local handoff. Arachne/Narcissus are owned by the
    -- focused acquisition adapter.
    local pendingLegacyTrait
    local pendingSeaStar

    -- Sea Star remains outside C4. Its existing duplicate-carrier path still
    -- binds the native duplicate while the source interaction is in flight.
    local function seaStarChildFor(state, source)
        local current = roomCoordinator.current(state)
        local sourceHandle = roomCoordinator.bound(state, current, source)
            or incomingHandle(roomCoordinator, session, state, source)
        local sourceRole = roomCoordinator.sourceRole(state, current, sourceHandle, source and source.Name)
        local child = roomCoordinator.resolve(state, current,
            { kind = "produced", source = sourceHandle, role = sourceRole })
        local payload = child and roomCoordinator.begin(state, child) or nil
        if payload and payload.detail and payload.detail.producer
            and payload.detail.producer.kind == "seaStarDuplicate" then
            return sourceHandle, child, payload
        end
        return sourceHandle, nil
    end

    local function attachNpcTraitChoice(functionName, giver)
        module.hooks.wrap(functionName, "run-planner-npc-trait-offer", function(_, runtime, base, source,
            args, screen)
            local state = getState(runtime)
            local handle = type(roomCoordinator.encounterHandle) == "function"
                and roomCoordinator.encounterHandle(state, source) or nil
            local payload = handle and roomCoordinator.begin(state, handle) or nil
            local resolution = payload and payload.transaction.resolution
            if resolution and resolution.kind == "traitOffer" and resolution.offer.giver == giver then
                if payload ~= nil and adapter.applyNpcTraitOffer(payload, args) then
                    pendingLegacyTrait = { handle = handle, payload = payload, source = source }
                elseif payload ~= nil then
                    session.mismatch(state, "npc-trait-offer", "published " .. giver .. " trait offer", nil)
                end
            end
            local result = base(source, args, screen)
            report(runtime)
            return result
        end)
    end

    module.hooks.wrap("UseLoot", "run-planner-use-loot", function(_, runtime, base, usee, args, user)
        -- C1 owns ordinary Olympian/Hermes/Hammer acquisition. It begins only
        -- after native UseLoot commits at HandleLootPickup.
        -- C2 owns the visible Pom carrier. Its adapter marks the exact loot
        -- while this call is in flight so this legacy family hook cannot begin
        -- an acquisition before native pickup acceptance.
        if isOrdinaryTraitCarrier(usee) or usee and usee.__runPlannerLevelCarrier
            or chaos.isNativeCarrier(usee) then
            return base(usee, args, user)
        end
        local state = getState(runtime)
        local current = roomCoordinator.current(state)
        local handle = roomCoordinator.bound(state, current, usee)
            or incomingHandle(roomCoordinator, session, state, usee)
        local payload = handle and roomCoordinator.begin(state, handle) or nil
        if payload == nil then return base(usee, args, user) end
        if payload == nil then report(runtime); return base(usee, args, user) end
        usee.__runPlannerTimelineHandle = handle
        local _, seaStarChild = seaStarChildFor(state, usee)
        if seaStarChild then pendingSeaStar = { source = usee, child = seaStarChild } end
        local expected = adapter.expectedTrait(payload)
        if expected ~= nil then
            adapter.applyTraitOffer(payload, usee)
            pendingLegacyTrait = { handle = handle, payload = payload, source = usee }
        end
        local result = base(usee, args, user)
        pendingSeaStar = nil
        report(runtime)
        return result
    end)

    module.hooks.wrap("GetTotalHeroTraitValue", "run-planner-sea-star-gate", function(_, _runtime, base,
        propertyName, args)
        if propertyName == "DoubleRewardChance" and pendingSeaStar ~= nil then return 1 end
        return base(propertyName, args)
    end)

    module.hooks.wrap("RandomChance", "run-planner-sea-star-duplicate", function(_, _, base, chance, args)
        if pendingSeaStar ~= nil then return true end
        return base(chance, args)
    end)

    local function bindSeaStar(state, result)
        if pendingSeaStar == nil or result == nil then return end
        local current = roomCoordinator.current(state)
        roomCoordinator.bind(state, current, pendingSeaStar.child, result)
    end

    module.hooks.wrap("CreateLoot", "run-planner-created-loot", function(_, runtime, base, args)
        local result = base(args)
        bindSeaStar(getState(runtime), result)
        return result
    end)

    module.hooks.wrap("CreateConsumableItem", "run-planner-created-consumable", function(_, runtime, base, ...)
        local result = base(...)
        bindSeaStar(getState(runtime), result)
        return result
    end)

    module.hooks.wrap("CreateBoonLootButtons", "run-planner-trait-screen", function(_, runtime, base, screen,
        lootData, reroll, args)
        if isOrdinaryTraitCarrier(lootData) or lootData and lootData.__runPlannerLevelCarrier
            or chaos.isNativeCarrier(lootData) then
            return base(screen, lootData, reroll, args)
        end
        local state = getState(runtime)
        local current = roomCoordinator.current(state)
        local handle = roomCoordinator.bound(state, current, lootData)
            or (pendingLegacyTrait and pendingLegacyTrait.handle)
            or incomingHandle(roomCoordinator, session, state, lootData)
        local payload = handle and roomCoordinator.begin(state, handle) or nil
        if payload ~= nil then
            lootData.__runPlannerTimelineHandle = handle
            local _, offer = adapter.expectedTrait(payload)
            if offer then adapter.applyTraitOffer(payload, lootData) end
        end
        return base(screen, lootData, reroll, args)
    end)

    attachNpcTraitChoice("MedeaCurseChoice", "Medea")
    attachNpcTraitChoice("CirceBlessingChoice", "Circe")
    attachNpcTraitChoice("IcarusBenefitChoice", "Icarus")
    attachNpcTraitChoice("EchoChoice", "Echo")

    module.hooks.wrap("CreateUpgradeChoiceButton", "run-planner-trait-option", function(_, runtime, base, screen,
        lootData, itemIndex, itemData, args)
        if isOrdinaryTraitCarrier(lootData) then
            return base(screen, lootData, itemIndex, itemData, args)
        end
        local handle = lootData and lootData.__runPlannerTimelineHandle
            or pendingLegacyTrait and pendingLegacyTrait.handle
        local payload = handle and roomCoordinator.begin(getState(runtime), handle)
            or pendingLegacyTrait and pendingLegacyTrait.payload
        local _, offer = adapter.expectedTrait(payload)
        if chaos.isNativeCarrier(lootData) then
            return base(screen, lootData, itemIndex, itemData, args)
        elseif offer and type(offer.options) == "table" then
            if itemIndex == 1 then alignBlockedTraitOption(screen, lootData, offer) end
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

    module.hooks.wrap("HandleUpgradeChoiceSelection", "run-planner-trait-selection", function(_, runtime, base,
        screen, button, args)
        local lootData = button and button.LootData
        if isOrdinaryTraitCarrier(lootData) or lootData and lootData.__runPlannerLevelCarrier
            or chaos.isNativeCarrier(lootData) then
            return base(screen, button, args)
        end
        local state = getState(runtime)
        local selected = button and button.Data and button.Data.Name
        if pendingLegacyTrait ~= nil then
            pendingLegacyTrait.selected = selected
        end
        local result = base(screen, button, args)
        if pendingLegacyTrait ~= nil then
            local pending = pendingLegacyTrait
            pendingLegacyTrait = nil
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
