-- Execution-protocol root composition. Long-lived runtime identities are
-- constructed once here and retained in lexical scope.
local composition = {}

function composition.bind(root)
    if type(root) ~= "string" or root == "" then error("executor config path is required", 2) end
    local json = import("mods/protocol/json.lua")
    local protocol = import("mods/protocol/decoder.lua")
    local inbox = import("mods/host/inbox.lua").create(root, function(raw)
        local value, errorMessage = json.decode(raw)
        if value == nil then return nil, "malformed-json: " .. tostring(errorMessage) end
        return protocol.decode(value)
    end, rom.path)
    local route = import("mods/route/session.lua")
    local room = import("mods/room/coordinator.lua")
    local session = import("mods/runtime/session.lua")
    local loadout = import("mods/loadout/session.lua")

    -- Imported chunks are stateless definitions. This explicit instance spans
    -- both owners that participate in Hex-tree realization.
    local hexTree = import("mods/spells/hex_tree.lua").create()
    local loadoutHooks = import("mods/loadout/hooks.lua")
    local acquisitionHooks = import("mods/room/timeline/acquisitions/hooks.lua")
    local loadoutRuntime = { inbox = inbox, session = session, loadout = loadout }

    local bound = {
        inboxInspection = { load = inbox.load, status = inbox.status },
    }

    function bound.attach(module)
        session.defineCache(module)
        local roomHooks = import("mods/room/hooks.lua")
        local encounterHooks = import("mods/room/timeline/encounters/hooks.lua")
        local roomFeatureHooks = import("mods/room/features/hooks.lua")
        local navigationHooks = import("mods/navigation/hooks.lua")
        local featureInventory = import("mods/room/features/inventory/attach.lua")
        local commerceHooks = import("mods/room/timeline/commerce/hooks.lua")
        local interactionHooks = import("mods/room/timeline/interactions/hooks.lua")
        local transformationHooks = import("mods/room/timeline/transformations/hooks.lua")

        local function getState(runtime) return session.get(runtime) end
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
                local status = session.status(state)
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
        local loadoutScope = loadoutHooks.attach(module, loadoutRuntime, getState, report, room, hexTree)

        acquisitionHooks.attach(module, session, getState, report, room, hexTree)
        local transformationScope = transformationHooks.attach(module, session, getState, report, room)
        local featureScope = roomFeatureHooks.attach(module, session, getState, report, room)
        local navigation = navigationHooks.attach(module, session, getState, report, route, room,
            transformationScope)
        roomHooks.attach(module, session, getState, report, route, room, featureScope, navigation,
            loadoutScope)
        encounterHooks.attach(module, session, getState, report, room)
        local inventoryBindings = featureInventory.attach(module, session, getState, report, room, route)
        commerceHooks.attach(module, session, getState, report, room, inventoryBindings)
        interactionHooks.attach(module, session, getState, report, room)
    end

    return bound
end

return composition
