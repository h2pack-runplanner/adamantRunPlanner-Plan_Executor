-- Mourning Fields realization. Native code remains responsible for creating
-- cages, optional rewards, and encounters; this adapter only steers the
-- published point and reward choices for the active Fields room.
local fields = {}

local function contains(values, wanted)
    for _, value in ipairs(values or {}) do
        if value == wanted then return true end
    end
    return false
end

local function removeExpected(values, wanted)
    for index, value in ipairs(values or {}) do
        if value == wanted then
            table.remove(values, index)
            return wanted
        end
    end
    return nil
end

local function copyArgs(args)
    local result = {}
    for key, value in pairs(type(args) == "table" and args or {}) do result[key] = value end
    return result
end

function fields.realize(nativeRoom, layout)
    if type(nativeRoom) ~= "table" or type(layout) ~= "table" then return nativeRoom end
    nativeRoom.HeroStartPoint = layout.entryPair.startPointId
    nativeRoom.HeroEndPoint = layout.entryPair.endPointId
    -- DoUnlockRoomExits normally uses this declaration field to generate a
    -- fresh random CageRewards array for every Fields target. The planned
    -- payload is already installed on the door by navigation, so remove only
    -- this target-local trigger while retaining the native door setup and
    -- reward-store flow.
    nativeRoom.MaxCageRewards = nil
    return nativeRoom
end

function fields.attach(module, session, getState, report, room)
    local active
    local activeNemesis

    local function currentLayout(state, nativeRoom)
        if state == nil or state.state ~= "synchronized" then return nil end
        local occurrence = room.current(state)
        if occurrence == nil or type(occurrence.overview) ~= "table" then return nil end
        local id = type(nativeRoom) == "table" and nativeRoom.__runPlannerExecutionRoomId or nil
        if id ~= nil and id ~= occurrence.id then return nil end
        return occurrence.overview.fields
    end

    module.hooks.wrap("RemoveRandomValue", "run-planner-fields-point-selection", function(_, runtime, base,
        values, ...)
        local scope = active
        if scope == nil then return base(values, ...) end

        local expected
        local cage = scope.cagePoints[scope.cageIndex + 1]
        if cage ~= nil and contains(values, cage.pointId) then
            expected = cage.pointId
            scope.cageIndex = scope.cageIndex + 1
        elseif scope.cageIndex == #scope.cagePoints then
            local optional = scope.optionalRewards[scope.optionalPointIndex + 1]
            if optional ~= nil and contains(values, optional.pointId) then
                expected = optional.pointId
                scope.optionalPointIndex = scope.optionalPointIndex + 1
            end
        end
        if expected == nil then return base(values, ...) end
        local result = removeExpected(values, expected)
        if result == nil then
            session.mismatch(getState(runtime), "fields-point", expected, nil)
            return base(values, ...)
        end
        return result
    end)

    module.hooks.wrap("RandomChance", "run-planner-fields-optional-count", function(_, _runtime, base,
        chance, args, ...)
        local scope = active
        local chanceIndex = scope and scope.chanceIndex + 1 or nil
        local expectedChance = chanceIndex and scope.chances[chanceIndex] or nil
        if expectedChance == nil or chance ~= expectedChance then return base(chance, args, ...) end
        scope.chanceIndex = chanceIndex
        scope.optionalChanceResults = scope.optionalChanceResults + 1
        return scope.optionalChanceResults <= #scope.optionalRewards
    end)

    module.hooks.wrap("IsRoomRewardEligible", "run-planner-fields-optional-reward", function(_, _runtime,
        base, run, nativeRoom, reward, previouslyChosen, args)
        local scope = active
        local expected = scope and scope.expectedReward
        if expected ~= nil and type(reward) == "table" then
            return (reward.Name or reward.RewardType) == expected.reward.rewardType
        end
        return base(run, nativeRoom, reward, previouslyChosen, args)
    end)

    module.hooks.wrap("ChooseRoomReward", "run-planner-fields-optional-choice", function(_, runtime, base,
        run, nativeRoom, rewardStore, chosen, args)
        local scope = active
        if scope == nil or rewardStore ~= scope.bonusRewardStore then
            return base(run, nativeRoom, rewardStore, chosen, args)
        end
        local expected = scope.optionalRewards[scope.rewardIndex + 1]
        if expected == nil then return base(run, nativeRoom, rewardStore, chosen, args) end
        scope.rewardIndex = scope.rewardIndex + 1
        scope.pendingReward = expected
        local prior = scope.expectedReward
        scope.expectedReward = expected
        local ok, result = pcall(base, run, nativeRoom, rewardStore, chosen, args)
        scope.expectedReward = prior
        if not ok then
            scope.pendingReward = nil
            error(result, 0)
        end
        local observed = type(result) == "table" and (result.Name or result.RewardType) or result
        if observed ~= expected.reward.rewardType then
            session.mismatch(runtime and getState(runtime), "fields-optional-reward",
                expected.reward.rewardType, observed)
        end
        return result
    end)

    module.hooks.wrap("SpawnRoomReward", "run-planner-fields-optional-spawn", function(_, _, base,
        eventSource, args)
        local scope = active
        local expected = scope and scope.pendingReward
        local forcedArgs = args
        if expected ~= nil and expected.reward.source ~= nil then
            forcedArgs = copyArgs(args)
            forcedArgs.LootName = expected.reward.source
        end
        local ok, result = pcall(base, eventSource, forcedArgs)
        if scope ~= nil and expected ~= nil then scope.pendingReward = nil end
        if not ok then error(result, 0) end
        return result
    end)

    module.hooks.wrap("SpawnRewardCages", "run-planner-fields-spawn", function(_, runtime, base, nativeRoom,
        args)
        local state = getState(runtime)
        local layout = currentLayout(state, nativeRoom)
        if layout == nil then return base(nativeRoom, args) end
        local scope = {
            cagePoints = layout.cagePoints or {},
            optionalRewards = layout.optionalRewards or {},
            chances = type(nativeRoom) == "table" and nativeRoom.OptionalRewardChances or {},
            cageIndex = 0,
            optionalPointIndex = 0,
            chanceIndex = 0,
            optionalChanceResults = 0,
            rewardIndex = 0,
            pendingReward = nil,
            bonusRewardStore = type(nativeRoom) == "table" and nativeRoom.BonusRewardStoreName or nil,
        }
        local prior = active
        active = scope
        local ok, result = pcall(base, nativeRoom, args)
        active = prior
        if not ok then error(result, 0) end
        if scope.cageIndex ~= #scope.cagePoints
            or scope.optionalPointIndex ~= #scope.optionalRewards
            or scope.rewardIndex ~= #scope.optionalRewards then
            session.mismatch(state, "fields-spawn", {
                cages = #scope.cagePoints, optional = #scope.optionalRewards,
            }, {
                cages = scope.cageIndex, optionalPoints = scope.optionalPointIndex,
                optionalRewards = scope.rewardIndex,
            })
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("SpawnNemesisForRandomEvents", "run-planner-fields-nemesis-scope", function(_, runtime,
        base, source, args)
        local state = getState(runtime)
        local layout = currentLayout(state, _G.CurrentRun and _G.CurrentRun.CurrentRoom)
        if layout == nil or layout.nemesisPointId == nil then return base(source, args) end
        local prior = activeNemesis
        activeNemesis = { pointId = layout.nemesisPointId, used = false }
        local ok, result = pcall(base, source, args)
        local used = activeNemesis.used
        activeNemesis = prior
        if not ok then error(result, 0) end
        if not used then
            session.mismatch(state, "fields-nemesis-point", layout.nemesisPointId, nil)
        end
        report(runtime)
        return result
    end)

    module.hooks.wrap("SelectSpawnPoint", "run-planner-fields-nemesis-point", function(_, _runtime, base,
        currentRoom, unit, source, args, depth)
        local scope = activeNemesis
        if scope == nil or scope.pointId == nil then
            return base(currentRoom, unit, source, args, depth)
        end
        if scope.used then return base(currentRoom, unit, source, args, depth) end
        scope.used = true
        return scope.pointId
    end)
end

return fields
