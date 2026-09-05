-- Boss lifecycle and its encounter-owned automatic Arcana outcomes.
local boss = {}

local function contains(values, expected)
    for _, value in ipairs(values or {}) do
        if value == expected then return true end
    end
    return false
end

function boss.attach(module, session, getState, report, room)
    local bossScope
    local arcanaQueue

    module.hooks.wrap("Kill", "run-planner-boss-defeated", function(_, runtime, base, victim, args)
        local state = getState(runtime)
        local current = room.current(state)
        local prior = bossScope
        if victim and victim.IsBoss and current then
            local nativeRoom = _G.CurrentRun and _G.CurrentRun.CurrentRoom
            local nativeEncounter = nativeRoom and nativeRoom.Encounter
            local phase = room.encounterPhase(state, nativeEncounter)
            bossScope = phase and { state = state, current = current, phaseKey = phase.slotKey } or nil
            if bossScope then room.window(state, "bossDefeated:" .. bossScope.phaseKey) end
        end
        local ok, result = pcall(base, victim, args)
        bossScope = prior
        if not ok then error(result, 0) end
        report(runtime)
        return result
    end)

    module.hooks.wrap("AddRandomMetaUpgrades", "run-planner-boss-arcana", function(_, runtime, base, count, args)
        if bossScope == nil then return base(count, args) end
        local effect = type(args) == "table" and args.RarityLevel ~= nil
            and "crystalFigurine" or "judgment"
        local handle = room.resolve(bossScope.state, bossScope.current,
            { kind = "automatic", effect = effect, phaseKey = bossScope.phaseKey })
        local payload = handle and room.begin(bossScope.state, handle) or nil
        if payload == nil then return base(count, args) end
        local prior = arcanaQueue
        arcanaQueue = {
            keys = payload.transaction.arcanaKeys,
            index = 1,
            admitCastCount = contains(payload.transaction.arcanaKeys, "CastCount"),
        }
        local ok, result = pcall(base, count, args)
        local consumed = arcanaQueue
        arcanaQueue = prior
        if not ok then error(result, 0) end
        if consumed.index <= #(payload.transaction.arcanaKeys or {}) then
            session.mismatch(bossScope.state, "boss-arcana-selection",
                payload.transaction.arcanaKeys, consumed.index)
        else
            session.complete(bossScope.state, handle)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("RandomChance", "run-planner-boss-arcana-admission", function(_, _, base,
        chance, ...)
        if arcanaQueue and arcanaQueue.admitCastCount and
            not arcanaQueue.castCountAdmissionConsumed and arcanaQueue.index == 1 then
            arcanaQueue.castCountAdmissionConsumed = true
            return true
        end
        return base(chance, ...)
    end)

    module.hooks.wrap("RemoveRandomValue", "run-planner-boss-arcana-selection", function(_, _, base, values)
        if arcanaQueue and arcanaQueue.keys[arcanaQueue.index] then
            local key = arcanaQueue.keys[arcanaQueue.index]
            for index, value in ipairs(values or {}) do
                if value == key then
                    table.remove(values, index)
                    arcanaQueue.index = arcanaQueue.index + 1
                    return value
                end
            end
        end
        return base(values)
    end)
end

return boss
