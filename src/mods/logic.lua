local logic = {}

function logic.bind(data, inboxRoot)
    if type(inboxRoot) ~= "string" or inboxRoot == "" then error("executor config path is required", 2) end
    local json = import("mods/json.lua")
    local protocol = import("mods/protocol.lua")
    local inbox = import("mods/inbox.lua")
    local session = import("mods/session.lua")
    data.inbox = inbox.create(inboxRoot, function(raw)
        local value, jsonError = json.decode(raw)
        if value == nil then return nil, "malformed-json: " .. tostring(jsonError) end
        return protocol.decode(value)
    end, rom.path)
    data.session = session
    return logic
end

function logic.attach(moduleRef, data)
    data.session.defineCache(moduleRef)
    -- Vanilla StartNewRun enters ChooseStartingRoom before it returns.  Keep
    -- initialization scoped to that lifecycle so a standalone mid-run hook
    -- can never freeze a newly published plan.
    local startLifecycleDepth = 0
    local startLifecycleEnabled = true
    local function writeStatus(runtime, state)
        if runtime.status and type(runtime.status.write) == "function" then
            local status = data.session.status(state)
            local text = status.state .. ": " .. status.reason
            if status.state == "desynchronized" then
                text = text .. " (" .. status.disposition .. " at " .. status.checkpoint .. ")"
            end
            runtime.status.write("ExecutionSessionStatus", text)
        end
    end
    moduleRef.hooks.wrap("StartNewRun", "execution-start-new-run", function(host, runtime, base, previousRun, args)
        local priorDepth = startLifecycleDepth
        local priorEnabled = startLifecycleEnabled
        local lifecycleEnabled = host.isEnabled == nil or host.isEnabled()
        startLifecycleDepth = priorDepth + 1
        startLifecycleEnabled = lifecycleEnabled
        local ok, currentRun = pcall(base, previousRun, args)
        startLifecycleDepth = priorDepth
        startLifecycleEnabled = priorEnabled
        if not ok then error(currentRun, 0) end
        local state = data.session.get(runtime)
        -- The normal base call has already passed through the nested starting
        -- room hook.  This fallback only covers hosts that do not make that
        -- nested call, while remaining inside StartNewRun.
        if not state.initialized then
            data.session.startNewRun(state, {
                currentRun = currentRun,
                args = args,
                enabled = lifecycleEnabled,
                inbox = data.inbox,
            })
        end
        writeStatus(runtime, state)
        return currentRun
    end)
    moduleRef.hooks.wrap("ChooseStartingRoom", "execution-opening-room", function(_, runtime, base, currentRun, args)
        local state = data.session.get(runtime)
        if startLifecycleDepth > 0 and not state.initialized then
            data.session.startNewRun(state, {
                currentRun = currentRun,
                args = args,
                enabled = startLifecycleEnabled,
                inbox = data.inbox,
            })
        end
        local gameValue = _G.game or game
        local room = data.session.chooseStartingRoom(state, currentRun, args, gameValue)
        return room or base(currentRun, args)
    end)
    -- StartRoom applies RunOverrides and initializes the live depth caches
    -- before this existing nested seam. Observe here so room-entry diagnostics
    -- see the game-owned values without pre-applying or duplicating them.
    moduleRef.hooks.wrap("StartRoomPreLoadBinks", "execution-observe-room", function(_, runtime, base, args)
        local state = data.session.get(runtime)
        local currentRun = type(args) == "table" and args.Run or nil
        local currentRoom = type(args) == "table" and args.Room or nil
        data.session.observeRoom(state, currentRun, currentRoom)
        writeStatus(runtime, state)
        return base(args)
    end)
    moduleRef.hooks.wrap("ChooseNextRoomData", "execution-outgoing-room", function(_, runtime, base, currentRun, args, otherDoors)
        local result = data.session.chooseNextRoomData(
            data.session.get(runtime), currentRun, args, otherDoors, _G.game or game)
        if result.kind == "passThrough" then return base(currentRun, args, otherDoors) end
        if result.kind == "failed" then
            writeStatus(runtime, data.session.get(runtime))
            return base(currentRun, args, otherDoors)
        end
        return result.roomData
    end)
    moduleRef.hooks.wrap("DoUnlockRoomExits", "execution-batch-reward-store", function(_, runtime, base, currentRun, room)
        local state = data.session.get(runtime)
        local result = data.session.prepareBatchRewardStore(state, currentRun)
        if result.kind == "failed" then
            writeStatus(runtime, state)
            return base(currentRun, room)
        end
        return base(currentRun, room)
    end)
    moduleRef.hooks.wrap("LeaveRoom", "execution-observe-exit", function(_, runtime, base, currentRun, door)
        local state = data.session.get(runtime)
        data.session.observeExit(state, currentRun, door)
        local result = base(currentRun, door)
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap("UpdateRunHistoryCache", "execution-observe-before-exit", function(_, runtime, base, currentRun, roomAdded)
        local result = base(currentRun, roomAdded)
        local state = data.session.get(runtime)
        if data.session.observeBeforeRoomExit(state, currentRun) then
            -- Vanilla has appended the source and updated its caches, while
            -- CurrentRoom still names that source. Commit before LeaveRoom
            -- continues into target preparation and LoadMap.
            data.session.commitExit(state)
        end
        writeStatus(runtime, state)
        return result
    end)
    moduleRef.hooks.wrap(
        "ChooseRoomReward", "execution-opening-reward",
        function(_, runtime, base, currentRun, room, rewardStoreName, previouslyChosenRewards, args)
        local result = data.session.chooseRoomReward(
            data.session.get(runtime), currentRun, room, _G.game or game, base,
            rewardStoreName, previouslyChosenRewards, args)
        if result.kind == "passThrough" then
            return base(currentRun, room, rewardStoreName, previouslyChosenRewards, args)
        end
        -- A pre-contact mismatch has no realized value.  Let vanilla continue
        -- from that point while the session remains frozen/desynchronized.
        if result.kind == "failed" and result.value == nil then
            return base(currentRun, room, rewardStoreName, previouslyChosenRewards, args)
        end
        return result.value
    end)
    moduleRef.hooks.wrap("SetupRoomReward", "execution-reward-source", function(_, runtime, base, currentRun, room, previouslyChosenRewards, args)
        local state = data.session.get(runtime)
        local result = data.session.prepareRewardSource(state, currentRun, room)
        if result.kind == "failed" then
            writeStatus(runtime, state)
            return base(currentRun, room, previouslyChosenRewards, args)
        end
        return base(currentRun, room, previouslyChosenRewards, args)
    end)
end

return logic
