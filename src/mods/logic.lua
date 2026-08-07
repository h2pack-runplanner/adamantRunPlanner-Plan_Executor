-- =============================================================================
-- LOGIC / GAME MODIFICATION
-- =============================================================================
-- This file is imported from main.lua inside init(), after once_loaded.game has fired.
-- Use it for:
-- - patch-plan helpers
-- - module.hooks registration
-- - runtime functions that read from callback-provided runtime data and modify game behavior
--
-- If logic grows, keep this file as the public logic loader/router and split
-- behavior files under src/mods/logic/ or src/mods/behaviors/. Those files should
-- expose bind/create functions and return their own narrow surfaces.

local logic = {}

function logic.bind(data) -- luacheck: ignore data
    return logic
end

function logic.buildActions()
    return {
        LogMode = function(host, runtime)
            host.logIf("Current mode: " .. tostring(runtime.data.read("Mode")))
        end,
    }
end

-- Enable this shape only when the module actually mutates static game data.
-- function logic.buildPatchPlan(host, runtime, plan)
--     if runtime.data.read("FeatureEnabled") then
--         plan:set(SomeGameTable, "SomeKey", true)
--         host.logIf("Enabled SomeGameTable.SomeKey")
--     end
-- end

function logic.buildPatchPlan(host, runtime, plan) -- luacheck: ignore host runtime plan
end

function logic.registerHooks(moduleRef) -- luacheck: ignore moduleRef
    -- Register hooks here if needed. host activation owns refresh/deactivation.
    -- Example:
    -- moduleRef.hooks.wrap("FunctionName", function(host, runtime, baseFunc, ...)
    --     if not host.isEnabled() or not runtime.data.read("FeatureEnabled") then
    --         return baseFunc(...)
    --     end
    --     host.logIf("Feature hook ran")
    --     return baseFunc(...)
    -- end)
end

function logic.attach(moduleRef)
    moduleRef.actions.define(logic.buildActions())
    -- Remove this declaration if the module does not mutate static game data.
    moduleRef.mutation.patch(logic.buildPatchPlan)
    logic.registerHooks(moduleRef)
end

return logic
