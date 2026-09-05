local data = {}

function data.buildStorage()
    return {}
end

function data.buildStatus()
    return {
        ExecutionSessionStatus = {
            type = "string",
            default = "inactive: not-started",
            maxLen = 1024,
            persist = false,
        },
    }
end

return data
