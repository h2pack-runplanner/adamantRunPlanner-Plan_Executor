-- Focused execution boundary for directly collected TrialUpgrade loot.
-- Native code owns transforming-row generation, sorting, rerolls, Denial, and
-- trait equipment. This adapter only steers the authored initial rows and
-- binds the exact selected curse at the native terminal.
local nativeChaos = type(import) == "function" and import("mods/traits/chaos.lua")
    or require("mods.traits.chaos")

local chaos = {}

local function optionIndex(value)
    return type(value) == "string" and tonumber(value:match("(%d+)$")) or nil
end

local function offerOf(payload)
    local detail = type(payload) == "table" and payload.detail or nil
    local offer = detail and detail.traitOffer
    if type(offer) == "table" and offer.kind == "chaos" then return offer end
    local resolution = type(payload) == "table" and payload.transaction
        and payload.transaction.resolution or nil
    offer = resolution and resolution.kind == "traitOffer" and resolution.offer or nil
    return type(offer) == "table" and offer.kind == "chaos" and offer or nil
end

local function chaosRole(transaction, contact)
    if type(transaction) ~= "table" or transaction.kind ~= "acquisition" then return nil end
    for _, role in ipairs(transaction.roles or {}) do
        if role.gameName == contact.gameName and role.disposition == "normal"
            and type(role.traitOffer) == "table" and role.traitOffer.kind == "chaos" then
            return role
        end
    end
    return nil
end

function chaos.isNativeCarrier(value)
    return nativeChaos.isNativeCarrier(value)
end

local function carrier(room, state, current, native)
    local handle = current and room.bound(state, current, native) or nil
    local payload = handle and room.peek(state, handle) or nil
    if handle ~= nil then
        return handle, payload, offerOf(payload) ~= nil
    end
    if current == nil or type(room.claimReady) ~= "function" then return nil, nil, false end
    handle, payload = room.claimReady(state, current,
        { kind = "chaosTrait", gameName = "TrialUpgrade" }, native, chaosRole)
    return handle, payload, offerOf(payload) ~= nil
end

local function mismatch(session, scope, expected, observed)
    if scope.invalid then return end
    scope.invalid = true
    session.mismatch(scope.state, "chaos-trait-offer", expected, observed)
end

local function nativeRows(scope)
    local rows = scope.loot.UpgradeOptions
    local offer = scope.offer
    if type(rows) ~= "table" or #rows ~= 3 or type(offer.curseOptions) ~= "table"
        or #offer.curseOptions ~= 3 then
        mismatch(scope.session, scope, "three Chaos transforming rows",
            type(rows) == "table" and #rows or type(rows))
        return false
    end
    local selected = optionIndex(offer.selected)
    if selected == nil or selected < 1 or selected > 3 then
        mismatch(scope.session, scope, "selected Chaos option 1..3", offer.selected)
        return false
    end

    for index = 1, 3 do
        local row, option = rows[index], offer.curseOptions[index]
        if type(row) ~= "table" or type(option) ~= "table" or type(option.curseKey) ~= "string"
            or type(option.requirementCount) ~= "number" then
            mismatch(scope.session, scope, "complete Chaos curse row", index)
            return false
        end
    end

    local existingBlessing
    for index, row in ipairs(rows) do
        if row.ItemName == offer.blessingKey then
            if existingBlessing ~= nil then
                mismatch(scope.session, scope, "one selected Chaos blessing row", offer.blessingKey)
                return false
            end
            existingBlessing = index
        end
    end

    local selectedRow = rows[selected]
    if type(selectedRow) ~= "table" then
        mismatch(scope.session, scope, "selected Chaos row", selected)
        return false
    end
    if existingBlessing ~= nil and existingBlessing ~= selected then
        local blessingRow = rows[existingBlessing]
        selectedRow.ItemName, blessingRow.ItemName = blessingRow.ItemName, selectedRow.ItemName
        selectedRow.Rarity, blessingRow.Rarity = offer.rarity, selectedRow.Rarity
    elseif existingBlessing == nil then
        selectedRow.ItemName = offer.blessingKey
        selectedRow.Rarity = offer.rarity
    else
        selectedRow.Rarity = offer.rarity
    end

    for index, row in ipairs(rows) do
        local option = offer.curseOptions[index]
        row.Type = row.Type or "TransformingTrait"
        row.SecondaryItemName = option.curseKey
    end
    return true
end

function chaos.attach(module, session, getState, report, room)
    local screens = setmetatable({}, { __mode = "k" })
    local processedContext

    module.hooks.wrap("HandleLootPickup", "run-planner-chaos-acquisition", function(_, runtime, base,
        currentRun, loot, args)
        if not chaos.isNativeCarrier(loot) then return base(currentRun, loot, args) end
        local state = getState(runtime)
        local current = room.current(state)
        local handle, _, matched = carrier(room, state, current, loot)
        if not matched then return base(currentRun, loot, args) end
        local payload = room.begin(state, handle)
        if payload == nil then return base(currentRun, loot, args) end
        local scope = {
            state = state, current = current, handle = handle, payload = payload,
            offer = offerOf(payload), loot = loot, session = session,
        }
        screens[loot] = scope
        local ok, result = pcall(base, currentRun, loot, args)
        if not ok then screens[loot] = nil; error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("CreateBoonLootButtons", "run-planner-chaos-initial-screen", function(_, _runtime, base,
        screen, loot, reroll, args)
        local scope = screens[loot]
        if scope == nil or reroll == true then return base(screen, loot, reroll, args) end
        scope.inCreation = true
        local ok, result = pcall(base, screen, loot, reroll, args)
        scope.inCreation = false
        if not ok then screens[loot] = nil; error(result, 0) end
        return result
    end)

    module.hooks.wrap("CreateUpgradeChoiceButton", "run-planner-chaos-row", function(_, _runtime, base,
        screen, loot, itemIndex, itemData, args)
        local scope = screens[loot]
        if scope == nil or not scope.inCreation then
            return base(screen, loot, itemIndex, itemData, args)
        end
        if not scope.prepared then
            scope.prepared = true
            scope.valid = nativeRows(scope)
        end
        if not scope.valid then return base(screen, loot, itemIndex, itemData, args) end

        local option = scope.offer.curseOptions[itemIndex]
        if option == nil then return base(screen, loot, itemIndex, itemData, args) end
        local selected = optionIndex(scope.offer.selected)
        processedContext = {
            curseKey = option.curseKey,
            requirementCount = option.requirementCount,
            curseValues = itemIndex == selected and scope.offer.selectedCurseValues or nil,
            blessingKey = itemIndex == selected and scope.offer.blessingKey or nil,
            rarity = itemIndex == selected and scope.offer.rarity or nil,
            blessingValues = itemIndex == selected and scope.offer.blessingValues or nil,
        }
        local ok, result = pcall(base, screen, loot, itemIndex, itemData, args)
        processedContext = nil
        if not ok then error(result, 0) end
        return result
    end)

    module.hooks.wrap("GetProcessedTraitData", "run-planner-chaos-processed-values", function(_, _, base, args)
        local result = base(args)
        local context = processedContext
        if context == nil or type(args) ~= "table" or type(result) ~= "table" then return result end
        if args.TraitName == context.curseKey then
            result.RemainingUses = context.requirementCount
            if context.curseValues ~= nil then
                return nativeChaos.applyCurse(result, context.curseKey, context.requirementCount,
                    context.curseValues)
            end
        elseif context.blessingKey ~= nil and args.TraitName == context.blessingKey then
            result.Rarity = context.rarity
            return nativeChaos.applyBlessing(result, context.blessingKey, context.blessingValues)
        end
        return result
    end)

    module.hooks.wrap("HandleUpgradeChoiceSelection", "run-planner-chaos-terminal", function(_, runtime, base,
        screen, button, args)
        local loot = button and button.LootData
        local scope = screens[loot]
        if scope == nil then return base(screen, button, args) end
        local selected = button and button.Data and button.Data.Name
        local ok, result = pcall(base, screen, button, args)
        if not ok then
            screens[loot] = nil
            error(result, 0)
        end
        local selectedIndex = optionIndex(scope.offer.selected)
        local expected = selectedIndex and scope.offer.curseOptions[selectedIndex]
        if expected == nil or selected ~= expected.curseKey then
            session.mismatch(scope.state, "chaos-trait-selection", expected and expected.curseKey, selected)
        else
            session.complete(scope.state, scope.handle)
        end
        screens[loot] = nil
        report(runtime)
        return result
    end)
end

return chaos
