local p = type(import) == "function" and import("mods/protocol/primitives.lua")
    or require("mods.protocol.primitives")

local rewards = {}

local optionKeys = { option1 = true, option2 = true, option3 = true }
function rewards.reward(value, label)
    local record, errorMessage = p.exact(
        value,
        { "rewardType", "producerLifecycleKey" },
        { "resolvedStoreKey", "source", "spurnedSource", "acquisitionEnabled" },
        label
    )
    if not record then return nil, errorMessage end
    for _, key in ipairs({
        "rewardType", "producerLifecycleKey", "resolvedStoreKey", "source", "spurnedSource",
    }) do
        if record[key] ~= nil and not p.str(record[key], label .. "." .. key) then
            return p.fail(label .. " has invalid " .. key)
        end
    end
    if record.acquisitionEnabled ~= nil
        and not p.bool(record.acquisitionEnabled, label .. ".acquisitionEnabled") then
        return p.fail(label .. " has invalid acquisitionEnabled")
    end
    return record
end

local function replacement(value, label)
    local record, errorMessage = p.exact(
        value,
        { "slot", "replacedTraitKey", "oldRarity", "newTraitKey", "requiredRarity" },
        { "levelBonus" },
        label
    )
    if not record then return nil, errorMessage end
    for _, key in ipairs({ "slot", "replacedTraitKey", "oldRarity", "newTraitKey", "requiredRarity" }) do
        if not p.str(record[key], label .. "." .. key) then
            return p.fail(label .. " has invalid " .. key)
        end
    end
    if record.levelBonus ~= nil and not p.int(record.levelBonus, label .. ".levelBonus", 0) then
        return p.fail(label .. " has invalid levelBonus")
    end
    return record
end

local function allTogetherResult(value, label)
    local record, errorMessage = p.exact(value, { "earth", "fire", "air", "water" }, {}, label)
    if not record then return nil, errorMessage end
    for _, key in ipairs({ "earth", "fire", "air", "water" }) do
        if not p.json.isNull(record[key]) and not p.str(record[key], label .. "." .. key) then
            return p.fail(label .. " has an invalid " .. key .. " outcome")
        end
    end
    return record
end

local function concaveStoneResult(value, label)
    local record, errorMessage = p.obj(value, label)
    if not record then return nil, errorMessage end
    if record.kind == "noProc" then
        return p.exact(record, { "kind" }, {}, label)
    end
    if record.kind == "proc" then
        local row, rowError = p.exact(record, { "kind", "optionKey" }, {}, label)
        if not row then return nil, rowError end
        if not p.one(row.optionKey, optionKeys, label .. ".optionKey") then
            return p.fail(label .. " has invalid residual option")
        end
        return row
    end
    return p.fail(label .. ".kind is unsupported")
end

local function circeResolution(value, label)
    local record, errorMessage = p.obj(value, label)
    if not record then return nil, errorMessage end
    if record.kind == "activateArcana" or record.kind == "promoteArcana" then
        local row, rowError = p.exact(record, { "kind", "arcanaKeys" }, {}, label)
        if not row then return nil, rowError end
        local maximum = row.kind == "activateArcana" and 1 or 2
        local keys, keysError = p.strings(row.arcanaKeys, label .. ".arcanaKeys", maximum)
        if not keys then return nil, keysError end
        local seen = {}
        for _, key in ipairs(keys) do
            if seen[key] then return p.fail(label .. ".arcanaKeys must be distinct") end
            seen[key] = true
        end
        return row
    end
    if record.kind == "disableFear" then
        local row, rowError = p.exact(record, { "kind", "vowKey" }, {}, label)
        if not row then return nil, rowError end
        if not p.str(row.vowKey, label .. ".vowKey") then
            return p.fail(label .. " has invalid vowKey")
        end
        return row
    end
    return p.fail(label .. ".kind is unsupported")
end

local function hexTree(value, label)
    local tree, treeError = p.exact(value, { "layoutKey", "rareTalentKeys", "epicTalentKeys" }, { "godSent" }, label)
    if not tree then return nil, treeError end
    if not p.str(tree.layoutKey, label .. ".layoutKey") then return p.fail(label .. " has invalid layout") end
    local seen = {}
    for _, key in ipairs({ "rareTalentKeys", "epicTalentKeys" }) do
        local rows, rowsError = p.strings(tree[key], label .. "." .. key)
        if not rows then return nil, rowsError end
        for _, talent in ipairs(rows) do
            if seen[talent] then return p.fail(label .. " has duplicate talent") end
            seen[talent] = true
        end
    end
    if tree.godSent ~= nil then
        local duo, duoError = p.exact(tree.godSent,
            { "olympianTalentKey", "lineageTalentKey" }, {}, label .. ".godSent")
        if not duo then return nil, duoError end
        if not p.str(duo.olympianTalentKey, label .. ".godSent.olympianTalentKey")
            or not p.str(duo.lineageTalentKey, label .. ".godSent.lineageTalentKey")
            or duo.olympianTalentKey == duo.lineageTalentKey
            or seen[duo.olympianTalentKey] or seen[duo.lineageTalentKey] then
            return p.fail(label .. " has invalid God Sent identities")
        end
    end
    return tree
end

local function echoLastRunBoon(value, label)
    local record, errorMessage = p.exact(value, { "options", "selected" }, {}, label)
    if not record then return nil, errorMessage end
    local options, optionsError = p.arr(record.options, label .. ".options", 3)
    if not options then return nil, optionsError end
    if #options == 0 then return p.fail(label .. ".options must contain one to three options") end
    local selectedIndex = { option1 = 1, option2 = 2, option3 = 3 }
    if selectedIndex[record.selected] == nil or selectedIndex[record.selected] > #options then
        return p.fail(label .. " selects a missing option")
    end
    for index, optionValue in ipairs(options) do
        local rowLabel = label .. ".options[" .. index .. "]"
        local row, rowError = p.exact(optionValue, { "giver", "key", "rarity" },
            { "lootHistorySource", "targetTraitKey", "naturalSelectionTargets" }, rowLabel)
        if not row then return nil, rowError end
        if not p.str(row.giver, rowLabel .. ".giver") or not p.str(row.key, rowLabel .. ".key")
            or not p.str(row.rarity, rowLabel .. ".rarity") then
            return p.fail(rowLabel .. " has malformed trait identity")
        end
        if row.lootHistorySource ~= nil and not p.str(row.lootHistorySource,
            rowLabel .. ".lootHistorySource") then
            return p.fail(rowLabel .. " has invalid loot-history source")
        end
        if row.targetTraitKey ~= nil and not p.str(row.targetTraitKey,
            rowLabel .. ".targetTraitKey") then
            return p.fail(rowLabel .. " has invalid acquisition target")
        end
        if row.naturalSelectionTargets ~= nil then
            local targets, targetsError = p.strings(row.naturalSelectionTargets,
                rowLabel .. ".naturalSelectionTargets", 8)
            if not targets then return nil, targetsError end
            if #targets == 0 then return p.fail(rowLabel .. ".naturalSelectionTargets must not be empty") end
        end
    end
    return record
end

function rewards.traitOffer(value, label)
    local record, errorMessage = p.obj(value, label)
    if not record then return nil, errorMessage end
    if record.kind == "fallbackGold" then
        local row, rowError = p.exact(record, { "kind", "giver" }, {}, label)
        if not row then return nil, rowError end
        if not p.str(row.giver, label .. ".giver") then return p.fail(label .. " has invalid giver") end
        return row
    end
    if record.kind == "chaos" then
        local row, rowError = p.exact(
            record,
            {
                "kind", "giver", "curseOptions", "selected", "selectedCurseValues",
                "blessingKey", "rarity", "blessingValues",
            },
            {},
            label
        )
        if not row then return nil, rowError end
        if row.giver ~= "Chaos" or not p.one(row.selected, optionKeys, label .. ".selected") then
            return p.fail(label .. " is a malformed Chaos offer")
        end
        local options, optionsError = p.arr(row.curseOptions, label .. ".curseOptions", 3)
        if not options then return nil, optionsError end
        if #options ~= 3 then return p.fail(label .. ".curseOptions must contain three options") end
        for index, optionValue in ipairs(options) do
            local option, optionError = p.exact(
                optionValue,
                { "curseKey", "requirementCount" },
                {},
                label .. ".curseOptions[" .. index .. "]"
            )
            if not option then return nil, optionError end
            if not p.str(option.curseKey, label .. ".curseKey")
                or not p.int(option.requirementCount, label .. ".requirementCount", 1) then
                return p.fail(label .. " has a malformed curse option")
            end
        end
        if not p.recordNumbers(row.selectedCurseValues, label .. ".selectedCurseValues")
            or not p.str(row.blessingKey, label .. ".blessingKey")
            or not p.str(row.rarity, label .. ".rarity")
            or not p.recordNumbers(row.blessingValues, label .. ".blessingValues") then
            return p.fail(label .. " has malformed Chaos values")
        end
        return row
    end
    local row, rowError = p.exact(
        record,
        { "kind", "giver", "options", "selected" },
        { "rejected", "hexTree" },
        label
    )
    if not row then return nil, rowError end
    if row.kind ~= "traits" or not p.str(row.giver, label .. ".giver")
        or not p.one(row.selected, optionKeys, label .. ".selected") then
        return p.fail(label .. " is a malformed trait offer")
    end
    if row.rejected ~= nil and not p.one(row.rejected, optionKeys, label .. ".rejected") then
        return p.fail(label .. " has malformed rejected option")
    end
    if row.hexTree ~= nil then
        local _, treeError = hexTree(row.hexTree, label .. ".hexTree")
        if treeError then return nil, treeError end
        if row.giver ~= "SpellDrop" then return p.fail(label .. ".hexTree requires SpellDrop") end
    end
    local options, optionsError = p.arr(row.options, label .. ".options", 3)
    if not options then return nil, optionsError end
    if #options == 0 then return p.fail(label .. ".options must contain one to three options") end
    if row.giver == "SpellDrop" and #options ~= 3 then
        return p.fail(label .. ".options must contain three options for SpellDrop")
    end
    if row.giver == "SpellDrop" and row.hexTree == nil then
        return p.fail(label .. ".hexTree is required for SpellDrop")
    end
    local optionIndex = { option1 = 1, option2 = 2, option3 = 3 }
    if optionIndex[row.selected] > #options
        or (row.rejected ~= nil and optionIndex[row.rejected] > #options) then
        return p.fail(label .. " selects a missing option")
    end
    for index, optionValue in ipairs(options) do
        local option, optionError = p.exact(
            optionValue,
            { "key" },
            {
                "baseRarity", "rarity", "effectiveLevel", "allTogetherResult",
                "naturalSelectionTargets", "concaveStoneResult", "circeResolution",
                "icarusHammerTarget", "echoPomTarget", "echoLastRunBoon", "replacement",
            },
            label .. ".options[" .. index .. "]"
        )
        if not option then return nil, optionError end
        if not p.str(option.key, label .. ".key")
            or (option.rarity ~= nil and not p.str(option.rarity, label .. ".rarity"))
            or (option.baseRarity ~= nil and not p.str(option.baseRarity, label .. ".baseRarity"))
            or (option.effectiveLevel ~= nil
                and not p.int(option.effectiveLevel, label .. ".effectiveLevel", 0)) then
            return p.fail(label .. " has malformed trait option")
        end
        if option.replacement ~= nil then
            local _, replacementError = replacement(option.replacement, label .. ".replacement")
            if replacementError then return nil, replacementError end
        end
        if option.allTogetherResult ~= nil then
            local _, resultError = allTogetherResult(option.allTogetherResult,
                label .. ".allTogetherResult")
            if resultError then return nil, resultError end
        end
        if option.naturalSelectionTargets ~= nil then
            local targets, targetsError = p.strings(option.naturalSelectionTargets,
                label .. ".options[" .. index .. "].naturalSelectionTargets", 8)
            if not targets then return nil, targetsError end
            if #targets == 0 then
                return p.fail(label .. ".options[" .. index .. "].naturalSelectionTargets must not be empty")
            end
        end
        if option.concaveStoneResult ~= nil then
            local _, resultError = concaveStoneResult(option.concaveStoneResult,
                label .. ".options[" .. index .. "].concaveStoneResult")
            if resultError then return nil, resultError end
            if index ~= optionIndex[row.selected] then
                return p.fail(label .. ".options[" .. index .. "].concaveStoneResult must belong to selected option")
            end
            if option.concaveStoneResult.kind == "proc" then
                local residualIndex = optionIndex[option.concaveStoneResult.optionKey]
                if residualIndex == nil or residualIndex > #options or residualIndex == index then
                    return p.fail(label .. ".options[" .. index .. "].concaveStoneResult is not a residual option")
                end
            end
        end
        if option.circeResolution ~= nil then
            local _, resultError = circeResolution(option.circeResolution,
                label .. ".options[" .. index .. "].circeResolution")
            if resultError then return nil, resultError end
            if row.giver ~= "Circe" then
                return p.fail(label .. ".options[" .. index .. "].circeResolution requires Circe")
            end
            if index ~= optionIndex[row.selected] then
                return p.fail(label .. ".options[" .. index .. "].circeResolution must belong to selected option")
            end
        end
        if option.icarusHammerTarget ~= nil then
            if not p.str(option.icarusHammerTarget,
                label .. ".options[" .. index .. "].icarusHammerTarget") then
                return p.fail(label .. ".options[" .. index .. "] has invalid Icarus Hammer target")
            end
            if row.giver ~= "Icarus" or option.key ~= "UpgradeHammerBoon" then
                return p.fail(label .. ".options[" .. index .. "].icarusHammerTarget requires Icarus Latest Model")
            end
            if index ~= optionIndex[row.selected] then
                return p.fail(label .. ".options[" .. index .. "].icarusHammerTarget must belong to selected option")
            end
        end
        if option.echoPomTarget ~= nil then
            if not p.json.isNull(option.echoPomTarget) and not p.str(option.echoPomTarget,
                label .. ".options[" .. index .. "].echoPomTarget") then
                return p.fail(label .. ".options[" .. index .. "] has invalid Echo Pom target")
            end
            if row.giver ~= "Echo" or option.key ~= "EchoDoubleLevelBoon" then
                return p.fail(label .. ".options[" .. index .. "].echoPomTarget requires Echo Pom Pom Pom")
            end
            if index ~= optionIndex[row.selected] then
                return p.fail(label .. ".options[" .. index .. "].echoPomTarget must belong to selected option")
            end
        end
        if option.echoLastRunBoon ~= nil then
            local _, nestedError = echoLastRunBoon(option.echoLastRunBoon,
                label .. ".options[" .. index .. "].echoLastRunBoon")
            if nestedError then return nil, nestedError end
            if row.giver ~= "Echo" or option.key ~= "EchoLastRunBoon" then
                return p.fail(label .. ".options[" .. index .. "].echoLastRunBoon requires Echo Boon Boon Boon")
            end
            if index ~= optionIndex[row.selected] then
                return p.fail(label .. ".options[" .. index .. "].echoLastRunBoon must belong to selected option")
            end
        end
    end
    return row
end

function rewards.acquisitionRole(value, label)
    local record, errorMessage = p.exact(
        value,
        { "role", "disposition", "lifecyclePoint", "kind", "gameName" },
        { "producer", "replacement", "settlement", "traitOffer", "levelResolution", "seaStarResult" },
        label
    )
    if not record then return nil, errorMessage end
    if not p.one(record.disposition, { normal = true, artificer = true }, label) then
        return p.fail(label .. " has invalid disposition")
    end
    for _, key in ipairs({ "role", "lifecyclePoint", "kind", "gameName" }) do
        if not p.str(record[key], label .. "." .. key) then
            return p.fail(label .. " has invalid " .. key)
        end
    end
    if record.producer ~= nil then
        local producer, producerError = p.exact(
            record.producer,
            { "kind", "sourceOwner", "sourceRole" },
            {},
            label .. ".producer"
        )
        if not producer then return nil, producerError end
        if not p.one(producer.kind, {
            seaStarDuplicate = true,
            artificerReplacement = true,
            echoLastReward = true,
        }, label .. ".producer.kind")
            or not p.str(producer.sourceOwner, label .. ".producer.sourceOwner", p.MAX_OWNER_STRING)
            or not p.str(producer.sourceRole, label .. ".producer.sourceRole") then
            return p.fail(label .. " has invalid producer")
        end
    end
    if record.replacement ~= nil then
        if record.disposition ~= "artificer" then
            return p.fail(label .. ".replacement is only valid for artificer roles")
        end
        local replacementRow, replacementError = p.exact(
            record.replacement,
            { "reward", "gameName" },
            {},
            label .. ".replacement"
        )
        if not replacementRow then return nil, replacementError end
        local _, rewardError = rewards.reward(replacementRow.reward, label .. ".replacement.reward")
        if rewardError then return nil, rewardError end
        if not p.str(replacementRow.gameName, label .. ".replacement.gameName") then
            return p.fail(label .. ".replacement has invalid gameName")
        end
    end
    if record.seaStarResult ~= nil then
        if record.disposition ~= "normal" then
            return p.fail(label .. ".seaStarResult is only valid for normal roles")
        end
        if record.producer ~= nil and record.producer.kind == "seaStarDuplicate" then
            return p.fail(label .. ".seaStarResult is invalid on a Sea Star duplicate")
        end
        local result, resultError = p.exact(record.seaStarResult, { "kind" }, {}, label .. ".seaStarResult")
        if not result then return nil, resultError end
        if not p.one(result.kind, { proc = true, noProc = true }, label .. ".seaStarResult.kind") then
            return p.fail(label .. " has invalid Sea Star result")
        end
    end
    if record.settlement ~= nil then
        local settlement, settlementError = p.exact(
            record.settlement,
            { "site", "entry" },
            {},
            label .. ".settlement"
        )
        if not settlement then return nil, settlementError end
        if not p.str(settlement.site, label .. ".settlement.site", p.MAX_OWNER_STRING)
            or not p.str(settlement.entry, label .. ".settlement.entry", p.MAX_OWNER_STRING) then
            return p.fail(label .. " has invalid settlement")
        end
    end
    if record.traitOffer ~= nil then
        local _, offerError = rewards.traitOffer(record.traitOffer, label .. ".traitOffer")
        if offerError then return nil, offerError end
    end
    if record.levelResolution ~= nil then
        local level, levelError = p.exact(
            record.levelResolution,
            { "offeredTargets", "selectedTarget", "levelCount" },
            {},
            label .. ".levelResolution"
        )
        if not level then return nil, levelError end
        local _, targetsError = p.strings(
            level.offeredTargets,
            label .. ".levelResolution.offeredTargets",
            3
        )
        if targetsError then return nil, targetsError end
        if not p.json.isNull(level.selectedTarget)
            and not p.str(level.selectedTarget, label .. ".levelResolution.selectedTarget") then
            return p.fail(label .. " has invalid selected target")
        end
        if not p.int(level.levelCount, label .. ".levelResolution.levelCount", 0) then
            return p.fail(label .. " has invalid level count")
        end
    end
    return record
end

function rewards.roles(value, label)
    local rows, errorMessage = p.arr(value, label)
    if not rows then return nil, errorMessage end
    for index, valueRow in ipairs(rows) do
        local _, roleError = rewards.acquisitionRole(valueRow, label .. "[" .. index .. "]")
        if roleError then return nil, roleError end
    end
    return rows
end

function rewards.equip(value, label)
    local record, errorMessage = p.exact(
        value,
        {},
        { "jeweledPom", "experimentalHammer", "transcendentEmbryo" },
        label
    )
    if not record then return nil, errorMessage end
    if record.jeweledPom ~= nil then
        local pom, pomError = p.exact(
            record.jeweledPom,
            { "traitKey" },
            { "rarity" },
            label .. ".jeweledPom"
        )
        if not pom then return nil, pomError end
        if not p.str(pom.traitKey, label .. ".jeweledPom.traitKey")
            or (pom.rarity ~= nil and not p.str(pom.rarity, label .. ".jeweledPom.rarity")) then
            return p.fail(label .. " has invalid jeweled Pom result")
        end
    end
    if record.experimentalHammer ~= nil then
        local hammer, hammerError = p.obj(record.experimentalHammer, label .. ".experimentalHammer")
        if not hammer then return nil, hammerError end
        if hammer.kind == "selected" then
            local selected, selectedError = p.exact(
                hammer,
                { "kind", "traitKey" },
                {},
                label .. ".experimentalHammer"
            )
            if not selected then return nil, selectedError end
            if not p.str(selected.traitKey, label .. ".experimentalHammer.traitKey") then
                return p.fail(label .. " has invalid experimental Hammer result")
            end
        elseif hammer.kind == "exhausted" then
            local _, exhaustedError = p.exact(
                hammer,
                { "kind" },
                {},
                label .. ".experimentalHammer"
            )
            if exhaustedError then return nil, exhaustedError end
        else
            return p.fail(label .. " has unsupported experimental Hammer result")
        end
    end
    if record.transcendentEmbryo ~= nil then
        local embryo, embryoError = p.exact(
            record.transcendentEmbryo,
            { "blessingKey", "blessingValues" },
            {},
            label .. ".transcendentEmbryo"
        )
        if not embryo then return nil, embryoError end
        if not p.str(embryo.blessingKey, label .. ".transcendentEmbryo.blessingKey") then
            return p.fail(label .. " has invalid Embryo result")
        end
        local _, valuesError = p.recordNumbers(
            embryo.blessingValues,
            label .. ".transcendentEmbryo.blessingValues"
        )
        if valuesError then return nil, valuesError end
    end
    return record
end

return rewards
