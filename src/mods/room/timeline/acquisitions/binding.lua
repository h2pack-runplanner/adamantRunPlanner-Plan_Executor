-- Shared exact-object correlation for acquisition carriers.  Producers own
-- materialization; acquisition adapters own the later native lifecycle.
local ordinary = type(import) == "function" and import("mods/room/timeline/acquisitions/traits/ordinary.lua")
    or require("mods.room.timeline.acquisitions.traits.ordinary")
local levels = type(import) == "function" and import("mods/room/timeline/acquisitions/levels/hooks.lua")
    or require("mods.room.timeline.acquisitions.levels.hooks")

local binding = {}

local function producerFor(state, room)
    local current = room.current(state)
    local reward = current and current.occurrence.overview.incomingReward
    if current == nil or reward == nil or reward.producerLifecycleKey == nil or reward.rewardType == nil then
        return nil, current
    end
    return room.resolve(state, current, {
        kind = "producer", producerLifecycleKey = reward.producerLifecycleKey,
        rewardType = reward.rewardType,
    }), current
end

function binding.attach(module, _session, getState, _report, room)
    local producerScope

    module.hooks.wrap("SpawnRoomReward", "run-planner-scope-acquisition-producer", function(_, runtime, base,
        source, args)
        local state = getState(runtime)
        local prior = producerScope
        -- Artificer invokes SpawnRoomReward for a replacement physical object.
        -- Its child is already published and must be claimed by its own
        -- acquisition adapter; never let this spawn inherit the incoming
        -- room-reward producer scope.
        producerScope = nil
        if not (type(args) == "table" and args.IgnoreRoomSpawnOnLootPoint == true) then
            local handle, current = producerFor(state, room)
            if handle ~= nil then producerScope = { state = state, current = current, handle = handle } end
        end
        local ok, result = pcall(base, source, args)
        producerScope = prior
        if not ok then error(result, 0) end
        return result
    end)

    module.hooks.wrap("CreateLoot", "run-planner-bind-loot-carrier", function(_, _runtime, base, args)
        local result = base(args)
        if producerScope ~= nil and (ordinary.isNativeCarrier(result) or levels.isVisibleCarrier(result)) then
            local scope = producerScope
            local handle = room.resolve(scope.state, scope.current, {
                kind = "materialized", source = scope.handle,
                gameName = result and (result.Name or result.ItemName or result.LootName),
            })
            if handle ~= nil then
                room.bind(scope.state, scope.current, handle, result)
                scope.bound = true
            end
            -- A producer owns one concrete carrier. Retire the scope even if
            -- the published materialized role was absent; a later reward
            -- object must never inherit a stale producer address.
            if producerScope == scope then producerScope = nil end
        end
        return result
    end)

    module.hooks.wrap("CreateConsumableItem", "run-planner-bind-direct-carrier", function(_, _runtime, base, ...)
        local result = base(...)
        if producerScope ~= nil and type(result) == "table" then
            local scope = producerScope
            local handle = room.resolve(scope.state, scope.current, {
                kind = "materialized", source = scope.handle,
                gameName = result and (result.Name or result.ItemName or result.LootName),
            })
            if handle ~= nil then
                room.bind(scope.state, scope.current, handle, result)
                scope.bound = true
                if producerScope == scope then producerScope = nil end
            end
        end
        return result
    end)
end

return binding
