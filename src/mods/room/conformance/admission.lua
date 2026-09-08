-- Read-only Postboss admission projection. It derives only the bounded
-- expected entry state and delegates observation to ordinary native readers.
local native = type(import) == "function" and import("mods/loadout/native.lua")
    or require("mods.loadout.native")
local conformance = type(import) == "function" and import("mods/protocol/conformance.lua")
    or require("mods.protocol.conformance")
local readers = type(import) == "function" and import("mods/room/conformance/readers.lua")
    or require("mods.room.conformance.readers")
local proof = type(import) == "function" and import("mods/room/conformance/proof.lua")
    or require("mods.room.conformance.proof")

local admission = {}
local families = {
    "traitInventory", "elementCounts", "steadyGrowth", "chaos", "keepsakeEffects",
    "rewardPriorities", "pathOfStars", "forfeit", "stygianWell",
}

function admission.verify(occurrence, startingLoadout)
    local expected, projectionError = conformance.admissionExpected(
        occurrence and occurrence.diagnostics
    )
    if not expected then return nil, projectionError end

    local observedLoadout = native.readLoadout()
    if observedLoadout.weaponKey ~= startingLoadout.weaponKey then
        return proof.compare(
            "postboss-admission:weapon",
            startingLoadout.weaponKey,
            observedLoadout.weaponKey
        )
    end
    local aspectPresent = native.hasTrait(startingLoadout.aspectKey)
    if observedLoadout.aspectKey ~= startingLoadout.aspectKey or not aspectPresent then
        local observedAspect = aspectPresent and observedLoadout.aspectKey or nil
        return proof.compare(
            "postboss-admission:aspect",
            startingLoadout.aspectKey,
            observedAspect
        )
    end

    local currentRun, gameState = _G.CurrentRun, _G.GameState
    for _, kind in ipairs(families) do
        local observed = readers.read(kind, currentRun, gameState, expected[kind])
        local ok, mismatch = proof.compare(
            "postboss-admission:" .. kind,
            expected[kind],
            observed
        )
        if not ok then return nil, mismatch end
    end
    return true
end

return admission
