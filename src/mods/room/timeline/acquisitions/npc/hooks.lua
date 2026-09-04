-- Focused execution boundary for the Arachne and Narcissus encounter
-- screens. Native menu construction, selection, and trait acquisition stay
-- native; this adapter installs the published offer and proves the native
-- selection. Native drop production remains pass-through.
local adapter = type(import) == "function" and import("mods/native_timeline_adapters.lua")
    or require("mods.native_timeline_adapters")

local npc = {}

local function copy(value)
    local result = {}
    for key, item in pairs(value or {}) do result[key] = item end
    return result
end

local function heroTraits()
    local hero = _G.CurrentRun and _G.CurrentRun.Hero
    return type(hero) == "table" and hero.Traits or nil
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

local function resolveNpcFallback(session, state, handle, payload, source, options)
    local offer = traitOffer(payload)
    if offer == nil then return handle, payload end
    local byName = optionsByName(options)
    for _, fallback in ipairs(offer.runtimeFallbacks or {}) do
        if fallback.availabilityContact == "traitEligibility" then
            local _, rebound, resolved = session.resolveFallback(state, handle, payload,
                "traitEligibility", fallback, function(key)
                    local option = byName[key]
                    return option ~= nil and nativeRequirementAvailable(source, option)
                end, source)
            if rebound == nil then return nil end
            handle, payload = rebound, resolved
        end
    end
    return handle, payload
end

local function realizedOptionKey(payload, offer, index)
    local option = offer and offer.options and offer.options[index]
    if option == nil then return nil end
    local selected = type(offer.selected) == "string"
        and tonumber(offer.selected:match("(%d+)$")) or nil
    if payload and payload.realizedKey ~= nil and index == selected then
        return payload.realizedKey
    end
    return option.key
end

local function nativeRowsAvailable(scope, offer)
    local byName = optionsByName(scope.nativeOptions)
    for index in ipairs(offer.options or {}) do
        local key = realizedOptionKey(scope.payload, offer, index)
        local option = byName[key]
        if option == nil or not nativeRequirementAvailable(scope.source, option) then return false end
    end
    return true
end

function npc.attach(module, session, getState, report, room)
    local choices = setmetatable({}, { __mode = "k" })

    local function install(scope)
        if scope.nativeOptions == nil or scope.payload == nil then return false end
        local offer = traitOffer(scope.payload)
        if offer == nil or not nativeRowsAvailable(scope, offer) then return false end
        -- Only replace the native menu after every published row has passed
        -- its own native requirements. A declared fallback therefore uses the
        -- fallback row's requirements, while an unavailable non-fallback row
        -- leaves the native menu untouched.
        local prepared = { UpgradeOptions = {} }
        for index, option in ipairs(scope.nativeOptions) do
            prepared.UpgradeOptions[index] = copy(option)
        end
        if not adapter.applyNpcTraitOffer(scope.payload, prepared) then return false end
        scope.source.UpgradeOptions = prepared.UpgradeOptions
        return true
    end

    local function attachChoice(functionName, giver)
        module.hooks.wrap(functionName, "execution-c3-npc-entry", function(_, runtime, base, source,
            args, screen)
            local state = getState(runtime)
            local current = room.current(state)
            local handle = encounterHandle(room, state, source)
            local payload = handle and room.begin(state, handle) or nil
            local resolution = payload and payload.transaction.resolution
            if current ~= nil and resolution and resolution.kind == "traitOffer"
                and resolution.offer.giver == giver then
                local nativeOptions = {}
                for _, option in ipairs(type(args) == "table" and args.UpgradeOptions or {}) do
                    nativeOptions[#nativeOptions + 1] = copy(option)
                end
                handle, payload = resolveNpcFallback(session, state, handle, payload, source, nativeOptions)
                local scope = {
                    state = state, current = current, handle = handle, payload = payload,
                    source = source, nativeOptions = nativeOptions,
                }
                choices[source] = scope
                if payload == nil then scope.invalid = true end
            end
            local result = base(source, args, screen)
            report(runtime)
            return result
        end)
    end

    attachChoice("ArachneCostumeChoice", "Arachne")
    attachChoice("NarcissusBenefitChoice", "Narcissus")

    module.hooks.wrap("OpenUpgradeChoiceMenu", "execution-c3-npc-menu", function(_, runtime, base, source, args)
        local scope = choices[source]
        if scope ~= nil and not scope.invalid then
            if not install(scope) then
                scope.invalid = true
                session.mismatch(scope.state, "npc-trait-offer", "published " ..
                    tostring(scope.payload and scope.payload.transaction.resolution.offer.giver) ..
                    " trait offer", nil)
            end
        end
        local result = base(source, args)
        report(runtime)
        return result
    end)

    module.hooks.wrap("HandleUpgradeChoiceSelection", "execution-c3-npc-selection", function(_, runtime,
        base, screen, button, args)
        local source = screen and screen.Source
        local scope = choices[source]
        if scope == nil or scope.invalid then return base(screen, button, args) end

        local selected = button and button.Data and button.Data.Name
        local result = base(screen, button, args)
        local verified = adapter.verifyTrait(scope.payload, selected, heroTraits())
        session.complete(scope.state, scope.handle, verified,
            scope.payload and scope.payload.transaction, selected)
        choices[source] = nil
        report(runtime)
        return result
    end)
end

return npc
