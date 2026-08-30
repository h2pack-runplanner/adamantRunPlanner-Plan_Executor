-- Plan ingestion and Slice 5 session assembly. The fixed inbox stays
-- replaceable; only the declared current-run cache owns a frozen program.

local logic = {}
local boundData

function logic.bind(data, inboxRoot)
    if type(inboxRoot) ~= "string" or inboxRoot == "" then
        error("Plan Executor requires _PLUGIN.config_mod_folder_path", 2)
    end
    local decoder = import("mods/json.lua")
    local protocol = import("mods/protocol.lua")
    local inbox = import("mods/inbox.lua")
    local session = import("mods/session.lua")
    data.runtime = inbox.create(inboxRoot, function(raw)
        local value, jsonError = decoder.decode(raw)
        if not value then
            return nil, "malformed-json: " .. tostring(jsonError)
        end
        return protocol.decode(value)
    end, rom.path)
    data.session = session
    boundData = data
    return logic
end

function logic.attach(moduleRef)
    boundData.session.defineCache(moduleRef)
    boundData.session.registerLifecycle(moduleRef)
    boundData.session.registerHooks(moduleRef, { inbox = boundData.runtime, game = game })
end

return logic
