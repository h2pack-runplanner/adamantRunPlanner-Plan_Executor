-- Focused execution boundary for NPC trait menus. Native menu construction,
-- option-specific preparation, selection, and trait acquisition stay native;
-- this adapter installs the published offer and binds the exact selection.
-- Native drop production and other selected-trait effects remain pass-through.
local adapter = type(import) == "function" and import("mods/native_timeline_adapters.lua")
    or require("mods.native_timeline_adapters")

local npc = {}

local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

local function copyInvocationArgs(args)
    if type(args) ~= "table" then return args end
    local result = copy(args)
    if type(args.UpgradeOptions) == "table" then
        result.UpgradeOptions = {}
        for index, option in ipairs(args.UpgradeOptions) do
            result.UpgradeOptions[index] = copy(option)
        end
    end
    if type(args.PortraitShift) == "table" then result.PortraitShift = copy(args.PortraitShift) end
    return result
end

local function nativeRequirementAvailable(source, option)
    local requirements = option and option.GameStateRequirements
    if requirements == nil then return true end
    if type(_G.IsGameStateEligible) ~= "function" then return false end
    local ok, result = pcall(_G.IsGameStateEligible, source, requirements)
    return ok and result == true
end

local function optionsByName(options)
    local result = {}
    for _, option in ipairs(options or {}) do
        if type(option) == "table" and option.ItemName ~= nil then result[option.ItemName] = option end
    end
    return result
end

local function encounterHandle(room, state, source)
    return type(room.encounterHandle) == "function" and room.encounterHandle(state, source) or nil
end

local function traitOffer(payload)
    local _, offer = adapter.expectedTrait(payload)
    return offer and offer.kind == "traits" and offer or nil
end

local function authoredOptionKey(offer, index)
    local option = offer and offer.options and offer.options[index]
    if option == nil then return nil end
    return option.key
end

local function nativeRowsAvailable(scope, offer)
    local byName = optionsByName(scope.nativeOptions)
    for index in ipairs(offer.options or {}) do
        local key = authoredOptionKey(offer, index)
        local option = byName[key]
        if option == nil or not nativeRequirementAvailable(scope.source, option) then return false end
    end
    return true
end

function npc.attach(module, session, getState, report, room)
    local choices = setmetatable({}, { __mode = "k" })
    local activeSelection
    local selectionObservers = {}

    local function installInput(scope, args)
        if scope.nativeOptions == nil or scope.payload == nil then return false end
        local offer = traitOffer(scope.payload)
        if offer == nil or not nativeRowsAvailable(scope, offer) then return false end
        -- Install before the named NPC callback so native option-specific work
        -- (for example Circe's familiar preparation) sees the authored rows.
        return adapter.applyNpcTraitOffer(scope.payload, args)
    end

    local function reportUnavailable(scope)
        session.mismatch(scope.state, "npc-trait-offer", "published " ..
            tostring(scope.payload and scope.payload.transaction.resolution.offer.giver) ..
            " trait offer", nil)
    end

    local function attachChoice(functionName, giver)
        module.hooks.wrap(functionName, "run-planner-npc-entry", function(_, runtime, base, source,
            args, screen)
            local state = getState(runtime)
            local current = room.current(state)
            local handle = encounterHandle(room, state, source)
            local payload = handle and room.begin(state, handle) or nil
            local resolution = payload and payload.transaction.resolution
            local invocationArgs = args
            if current ~= nil and resolution and resolution.kind == "traitOffer"
                and resolution.offer.giver == giver then
                invocationArgs = copyInvocationArgs(args)
                local nativeOptions = {}
                for _, option in ipairs(type(invocationArgs) == "table" and invocationArgs.UpgradeOptions or {}) do
                    nativeOptions[#nativeOptions + 1] = copy(option)
                end
                local scope = {
                    state = state, current = current, handle = handle, payload = payload,
                    source = source, nativeOptions = nativeOptions,
                }
                if installInput(scope, invocationArgs) then
                    choices[source] = scope
                else
                    reportUnavailable(scope)
                end
            end
            local result = base(source, invocationArgs, screen)
            report(runtime)
            return result
        end)
    end

    attachChoice("ArachneCostumeChoice", "Arachne")
    attachChoice("NarcissusBenefitChoice", "Narcissus")
    attachChoice("MedeaCurseChoice", "Medea")
    attachChoice("CirceBlessingChoice", "Circe")
    attachChoice("IcarusBenefitChoice", "Icarus")
    attachChoice("EchoChoice", "Echo")

    module.hooks.wrap("OpenUpgradeChoiceMenu", "run-planner-npc-menu", function(_, runtime, base, source, args)
        local scope = choices[source]
        if scope ~= nil then
            -- Native selection may reorder the three rows. Reapply the same
            -- authored set at the shared menu contact after native preparation.
            if not adapter.applyNpcTraitOffer(scope.payload, source) then
                reportUnavailable(scope)
                choices[source] = nil
            end
        end
        local result = base(source, args)
        report(runtime)
        return result
    end)

    module.hooks.wrap("HandleUpgradeChoiceSelection", "run-planner-npc-selection", function(_, runtime,
        base, screen, button, args)
        local source = screen and screen.Source
        local scope = choices[source]
        if scope == nil then return base(screen, button, args) end

        local selected = button and button.Data and button.Data.Name
        local expected = adapter.expectedTrait(scope.payload)
        local exact = expected ~= nil and expected.key == selected
        local prior = activeSelection
        local deferCompletion = false
        if exact then
            scope.selectedOption = expected
            activeSelection = scope
            local observer = selectionObservers[expected.key]
            if observer ~= nil then deferCompletion = observer(scope) == true end
        end
        local ok, result = pcall(base, screen, button, args)
        activeSelection = prior
        if not ok then error(result, 0) end
        if not exact then
            session.mismatch(scope.state, "npc-trait-selection", expected and expected.key, selected)
        elseif not deferCompletion then
            session.complete(scope.state, scope.handle)
        end
        choices[source] = nil
        report(runtime)
        return result
    end)

    return {
        current = function(giver)
            if activeSelection == nil then return nil end
            local resolution = activeSelection.payload and activeSelection.payload.transaction.resolution
            local offer = resolution and resolution.kind == "traitOffer" and resolution.offer
            if offer == nil or offer.giver ~= giver then return nil end
            return activeSelection
        end,
        observeSelection = function(traitKey, observer)
            selectionObservers[traitKey] = observer
        end,
    }
end

return npc
