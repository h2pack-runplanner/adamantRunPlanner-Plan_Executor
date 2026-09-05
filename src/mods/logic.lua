-- Execution-protocol root composition. Loadout owns run-start behavior; the
-- route/room coordinator owns only occurrence-session state.
local logic = {}

function logic.bind(data, root)
    if type(root) ~= "string" or root == "" then error("executor config path is required", 2) end
    local json = import("mods/json.lua")
    local protocol = import("mods/protocol/decoder.lua")
    data.inbox = import("mods/inbox.lua").create(root, function(raw)
        local value, errorMessage = json.decode(raw)
        if value == nil then return nil, "malformed-json: " .. tostring(errorMessage) end
        return protocol.decode(value)
    end, rom.path)
    data.session = import("mods/runtime_session.lua")
    data.loadout = import("mods/loadout/session.lua")
    return logic
end

function logic.attach(module, data)
    data.session.defineCache(module)
    local loadoutHooks = import("mods/loadout/hooks.lua")
    local route = import("mods/route/session.lua")
    local room = import("mods/room/coordinator.lua")
    local roomHooks = import("mods/room/hooks.lua")
    local encounterHooks = import("mods/room/timeline/encounters/hooks.lua")
    local roomFeatureHooks = import("mods/room/features/hooks.lua")
    local navigationHooks = import("mods/navigation/hooks.lua")
    local featureInventoryHooks = import("mods/room/features/inventory_hooks.lua")
    local featureInteractionHooks = import("mods/room/timeline/feature_interactions.lua")
    local acquisitionHooks = import("mods/room/timeline/acquisitions/hooks.lua")
    local transformationHooks = import("mods/room/timeline/transformations/hooks.lua")
    local hexTree = import("mods/spells/hex_tree.lua")

    local function getState(runtime) return data.session.get(runtime) end
    local function diagnosticValue(value, depth)
        depth = depth or 0
        if depth >= 2 then return "…" end
        if type(value) ~= "table" then return tostring(value) end
        local parts, count = {}, 0
        for key, nested in pairs(value) do
            count = count + 1
            if count > 6 then parts[#parts + 1] = "…"; break end
            parts[#parts + 1] = tostring(key) .. "=" .. diagnosticValue(nested, depth + 1)
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    local function report(runtime)
        local state = getState(runtime)
        if state == nil then return end
        if runtime.status and runtime.status.write then
            local status = data.session.status(state)
            runtime.status.write("ExecutionSessionStatus", status.state .. ": " .. status.reason)
        end
        if state.firstMismatch and state.loggedMismatch ~= state.firstMismatch then
            state.loggedMismatch = state.firstMismatch
            if rom and rom.log and rom.log.info then
                local mismatch = state.firstMismatch
                rom.log.info("[RunPlanner] first-mismatch checkpoint="
                    .. tostring(mismatch.checkpoint or mismatch.kind) .. " expected="
                    .. diagnosticValue(mismatch.expected) .. " observed="
                    .. diagnosticValue(mismatch.observed))
            end
        end
    end

    hexTree.attach(module)
    loadoutHooks.attach(module, data, getState, report, room)

    acquisitionHooks.attach(module, data.session, getState, report, room)
    local transformationScope = transformationHooks.attach(module, data.session, getState, report, room)
    local featureScope = roomFeatureHooks.attach(module, data.session, getState, report, room)
    local navigation = navigationHooks.attach(module, data.session, getState, report, route, room, transformationScope)
    roomHooks.attach(module, data.session, getState, report, route, room, featureScope, navigation)
    encounterHooks.attach(module, data.session, getState, report, room)
    local inventoryBindings = featureInventoryHooks.attach(module, data.session, getState, report, room, route)
    featureInteractionHooks.attach(module, data.session, getState, report, room, inventoryBindings)
end

return logic
