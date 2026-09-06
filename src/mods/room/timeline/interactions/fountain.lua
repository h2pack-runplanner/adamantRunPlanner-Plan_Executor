-- Fountain use and its Aromatic Phial extension.
local nativeBindings = type(import) == "function" and import("mods/native_bindings.lua")
    or require("mods.native_bindings")
local aromaticPhial = type(import) == "function" and import("mods/keepsakes/aromatic_phial.lua")
    or require("mods.keepsakes.aromatic_phial")
local fountain = {}

function fountain.attach(module, session, getState, report, room)
    local phial = aromaticPhial.attach(module, {
        session = session,
        getState = getState,
        report = report,
        room = room,
        phialTraitKey = nativeBindings.conformance.keepsakeTraits.phial,
    })

    module.hooks.wrap("UseHealthFountain", "run-planner-fountain", function(_, runtime, base, source, args)
        local state = getState(runtime)
        local active = room.current(state)
        local handle = active and room.resolve(state, active,
            { kind = "interaction", interactionKey = "fountain" })
        handle = room.bind(state, active, handle, source)
        local payload = handle and room.begin(state, handle) or nil
        local phialScope = phial.begin(state, active, handle, payload)
        local ok, result = pcall(base, source, args)
        if not ok then
            phial.cancel(phialScope)
            error(result, 0)
        end
        if payload ~= nil and phialScope == nil then session.complete(state, handle) end
        report(runtime)
        return result
    end)
end

return fountain
