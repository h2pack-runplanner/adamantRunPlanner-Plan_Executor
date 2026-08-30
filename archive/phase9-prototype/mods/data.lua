-- Plan contents and protocol results remain in the replaceable inbox runtime.
-- Slice 4 has no persisted settings or file-selection UI.

local data = {}

function data.buildStorage()
    return {}
end

function data.buildStatus()
    return {
        ExecutionSessionStatus = {
            type = "string",
            default = "not-started",
            maxLen = 1024,
            persist = false,
        },
    }
end

return data
