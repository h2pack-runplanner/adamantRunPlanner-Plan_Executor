-- ShipCombat phase and wheel realization. Native code owns wheel creation,
-- input, combat, pickup spawning, and between-phase readiness; this instance
-- only supplies the planner's resolved RNG outcomes and observes the click.
local thessaly = {}

local function wheelForPhase(active, phaseKey)
    for _, wheel in ipairs(active.occurrence.overview.rewardWheels or {}) do
        if wheel.phaseKey == phaseKey then return wheel end
    end
    return nil
end

function thessaly.create()
    local instance = {}
    local wheelScope
    local selectedRewardByState = setmetatable({}, { __mode = "k" })

    -- Navigation owns ChooseRoomReward/SetupRoomReward. This narrow context
    -- tells that existing reward boundary when the nested Ship wheel, rather
    -- than the room's incoming reward, is the active source.
    function instance.rewardContext() return wheelScope end

    -- The selected wheel remains the exact producer context until native
    -- SpawnRoomReward materializes its pickup after combat.
    function instance.takeRewardProducer(state, active)
        local selected = selectedRewardByState[state]
        if selected == nil or selected.active ~= active then return nil end
        selectedRewardByState[state] = nil
        return selected
    end

    -- SetupRoomMultipleEncountersData runs while CreateRoom is constructing
    -- the stamped destination, before any wheel or active-room session exists.
    -- The generic encounter hook asks for this one temporary declaration edit.
    function instance.preparePhases(state, room, nativeRoom)
        local data = type(nativeRoom) == "table" and nativeRoom.MultipleEncountersData or nil
        local first = state ~= nil and room.encounterAt(state, 1, nativeRoom) or nil
        local second = state ~= nil and room.encounterAt(state, 2, nativeRoom) or nil
        if state == nil or state.state ~= "synchronized" or first == nil or second == nil
            or type(data) ~= "table" or data[3] == nil then
            return function() end
        end
        local phaseCount = room.encounterAt(state, 3, nativeRoom) == nil and 2 or 3
        local third = data[3]
        local priorRequirements = third.GameStateRequirements
        if phaseCount == 2 then data[3] = nil else third.GameStateRequirements = nil end
        return function()
            data[3] = third
            third.GameStateRequirements = priorRequirements
        end
    end

    function instance.attach(module, session, getState, report, room)
        module.hooks.wrap("ShipsEncounterSetup", "run-planner-ship-wheel-realization", function(_, runtime,
            base, encounter, args)
            local state = getState(runtime)
            local active = room.current(state)
            local phase = active and room.encounterPhase(state, encounter)
            local wheel = phase and wheelForPhase(active, phase.slotKey) or nil
            if state == nil or state.state ~= "synchronized" or wheel == nil then
                return base(encounter, args)
            end
            room.window(state, "shipPreCombat:" .. wheel.wheelKey)
            local prior = wheelScope
            wheelScope = {
                state = state, active = active, wheel = wheel, offerIndex = 0,
                offerCountPending = true, currentOffer = nil,
            }
            local ok, result = pcall(base, encounter, args)
            wheelScope = prior
            if not ok then error(result, 0) end
            report(runtime)
            return result
        end)

        module.hooks.wrap("RandomChance", "run-planner-ship-wheel-count", function(_, _, base, chance, args)
            local scope = wheelScope
            if scope == nil or not scope.offerCountPending then return base(chance, args) end
            scope.offerCountPending = false
            return scope.wheel.offerCount == 2
        end)

        module.hooks.wrap("ChooseNextRewardStore", "run-planner-ship-wheel-store", function(_, _, base, ...)
            if wheelScope ~= nil then return wheelScope.wheel.storeKey end
            return base(...)
        end)

        module.hooks.wrap("CreateDoorRewardPreview", "run-planner-bind-ship-wheel", function(_, _, base,
            wheelObstacle, ...)
            local scope = wheelScope
            if scope ~= nil and type(wheelObstacle) == "table" and scope.currentOffer ~= nil then
                wheelObstacle.__runPlannerWheelKey = scope.wheel.wheelKey
                wheelObstacle.__runPlannerOfferKey = scope.currentOffer.offerKey
            end
            return base(wheelObstacle, ...)
        end)

        module.hooks.wrap("UseShipWheel", "run-planner-observe-ship-wheel", function(_, runtime, base, wheel)
            local result = base(wheel)
            local scope = wheelScope
            local state = getState(runtime)
            if scope ~= nil and state ~= nil and state.state == "synchronized" then
                local handle = room.resolve(state, scope.active, {
                    kind = "rewardWheel", wheelKey = scope.wheel.wheelKey,
                })
                handle = room.bind(state, scope.active, handle, wheel)
                local payload = handle and room.begin(state, handle) or nil
                local expected = payload and payload.transaction.pickedOfferKey
                local observed = type(wheel) == "table" and wheel.__runPlannerOfferKey or nil
                if expected ~= observed then
                    session.mismatch(state, "ship-wheel-selection", expected, observed)
                elseif handle ~= nil then
                    session.complete(state, handle)
                    -- Native now owns the selected reward and starts combat.
                    -- The later SpawnRoomReward contact cannot occur before
                    -- this point, so expose its published acquisition window.
                    if room.window(state, "shipPostCombat:" .. scope.wheel.wheelKey) then
                        selectedRewardByState[state] = {
                            active = scope.active, wheelKey = scope.wheel.wheelKey,
                        }
                    end
                end
                report(runtime)
            end
            return result
        end)
    end

    return instance
end

return thessaly
