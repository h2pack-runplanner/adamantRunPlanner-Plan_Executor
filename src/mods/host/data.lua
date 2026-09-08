local data = {}

function data.buildStorage()
    return {
        {
            type = "int",
            alias = "ActivePlanSlot",
            label = "Active plan slot",
            tooltip = "Plan Executor uses this slot for the next run.",
            default = 1,
            min = 1,
            max = 6,
        },
    }
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
