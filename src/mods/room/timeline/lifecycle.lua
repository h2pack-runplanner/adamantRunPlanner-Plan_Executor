-- Closed execution lifecycle windows become explicit local capabilities. The
-- mapping is protocol-shaped, not transaction-kind-shaped.
local lifecycle = {}

local checkpoints = {
    roomEntered = true,
    outgoingGeneration = true,
    exitUsable = true,
    roomExit = true,
}

local function capabilityFor(window)
    if type(window) ~= "table" then return nil end
    if window.kind == "standard" then
        return window.phase == "beforeCombat" and "roomEntered" or "afterCombat"
    end
    if window.kind == "postOutgoing" then return "postOutgoing" end
    if (window.kind == "encounterEnd" or window.kind == "bossDefeated") and type(window.phaseKey) == "string" then
        return window.kind .. ":" .. window.phaseKey
    end
    return nil
end

function lifecycle.new()
    return { roomEntered = true }
end

function lifecycle.open(capabilities, window)
    if type(window) ~= "string" then
        return nil, { checkpoint = "lifecycle-window", expected = "published lifecycle window", observed = window }
    end
    if window == "roomEntered" or window == "afterCombat" or window == "postOutgoing" then
        if window == "afterCombat" then
            capabilities.roomEntered = nil
            for key in pairs(capabilities) do
                if key:match("^encounterEnd:") or key:match("^bossDefeated:") then capabilities[key] = nil end
            end
        end
        capabilities[window] = true
        return true
    end
    if window:match("^encounterEnd:.+") or window:match("^bossDefeated:.+") then
        -- A phase contact is exact and transient. Starting a new one replaces
        -- any prior phase seam; no scalar cursor or accumulated phase history.
        for key in pairs(capabilities) do
            if key:match("^encounterEnd:") or key:match("^bossDefeated:") then capabilities[key] = nil end
        end
        capabilities[window] = true
        return true
    end
    return nil, { checkpoint = "lifecycle-window", expected = "published lifecycle window", observed = window }
end

function lifecycle.startEncounter(capabilities)
    for key in pairs(capabilities) do
        if key:match("^encounterEnd:") or key:match("^bossDefeated:") then capabilities[key] = nil end
    end
    return true
end

function lifecycle.accepts(capabilities, window)
    local capability = capabilityFor(window)
    return capability ~= nil and capabilities[capability] == true, capability
end

function lifecycle.activePhase(capabilities, kind)
    local prefix = kind .. ":"
    for key in pairs(capabilities or {}) do
        if key:sub(1, #prefix) == prefix then return key:sub(#prefix + 1) end
    end
    return nil
end

function lifecycle.isCheckpoint(name) return checkpoints[name] == true end

return lifecycle
