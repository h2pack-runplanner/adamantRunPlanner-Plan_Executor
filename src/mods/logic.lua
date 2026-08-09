-- Plan ingestion assembly. No gameplay hooks or semantic planner behavior are
-- registered in Slice 4; this module only wires the fixed inbox to decoding.

local logic = {}

function logic.bind(data, inboxRoot)
    if type(inboxRoot) ~= "string" or inboxRoot == "" then
        error("Plan Executor requires _PLUGIN.config_mod_folder_path", 2)
    end
    local decoder = import("mods/json.lua")
    local protocol = import("mods/protocol.lua")
    local inbox = import("mods/inbox.lua")
    data.runtime = inbox.create(inboxRoot, function(raw)
        local value, jsonError = decoder.decode(raw)
        if not value then
            return nil, "malformed-json: " .. tostring(jsonError)
        end
        return protocol.decode(value)
    end, rom.path)
    return logic
end

function logic.attach(moduleRef) -- luacheck: ignore moduleRef
    -- Deliberately no action, patch-plan, or hook registrations in this gate.
end

return logic
