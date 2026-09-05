-- Stateless realization and proof for the reward delivered by a route entry or
-- selected Door. Generated acquisition overrides are supplied by their owner.
local nativeBindings = type(import) == "function" and import("mods/native_bindings.lua")
    or require("mods.native_bindings")
local bindings = nativeBindings.navigation
local rewards = {}

local function rewardName(value)
    if type(value) == "table" then return value.RewardType or value.Name or value.Reward end
    return value
end

function rewards.isLogicalRoomAcquisition(reward)
    return type(reward) == "table" and bindings.logicalRoomAcquisitions[reward.rewardType] == true
end

function rewards.realize(occurrence, nativeRoom)
    local expected = occurrence.overview
    if expected.incomingReward and not rewards.isLogicalRoomAcquisition(expected.incomingReward) then
        nativeRoom.RewardType = expected.incomingReward.rewardType
        nativeRoom.ChosenRewardType = nil
        nativeRoom.ForceLootName = expected.incomingReward.source
    elseif expected.incomingReward == nil and expected.effectNeutralRequiredReward ~= true then
        nativeRoom.RewardType = nil
        nativeRoom.ChosenRewardType = nil
        nativeRoom.Reward = nil
        nativeRoom.ForceLootName = nil
    end
    return nativeRoom
end

function rewards.prove(occurrence, nativeRoom)
    local expected = occurrence.overview
    local actual = rewardName(nativeRoom.ChosenRewardType)
    local expectedReward = expected.incomingReward and expected.incomingReward.rewardType or nil
    if expected.effectNeutralRequiredReward == true and actual == nil then
        return nil, { kind = "incomingReward", expected = "native required reward", observed = actual }
    elseif not rewards.isLogicalRoomAcquisition(expected.incomingReward)
        and expected.effectNeutralRequiredReward ~= true and actual ~= expectedReward then
        return nil, { kind = "incomingReward", expected = expectedReward, observed = actual }
    end
    return true
end

return rewards
