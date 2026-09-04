-- luacheck: globals TestMysteryAcquisitions
local lu = require("luaunit")
local mystery = require("mods.room.timeline.acquisitions.mystery.hooks")

TestMysteryAcquisitions = {}

local function capture()
    local callbacks = {}
    local module = { hooks = { wrap = function(name, _, callback) callbacks[name] = callback end } }
    return module, callbacks
end

function TestMysteryAcquisitions.testMysteryBoxForcesProviderOnlyAfterAcceptedUse()
    local module, callbacks = capture()
    local state, item, provider = {}, { Name = "BlindBoxLoot" }, { Name = "HeraUpgrade" }
    local boxHandle = {}
    local node = {
        owner = "mystery", kind = "acquisition",
        roles = {
            { role = "box", lifecyclePoint = "roomRewardPickup", kind = "consumable",
                gameName = item.Name, disposition = "normal" },
            { role = "hiddenSource", lifecyclePoint = "afterUnwrap", kind = "trait",
                gameName = provider.Name, disposition = "normal" },
        },
    }
    local boxPayload = { transaction = node, detail = node.roles[1] }
    local bound, payloads = {}, { [boxHandle] = boxPayload }
    local active = { occurrence = { overview = {} } }
    local room = {
        current = function() return active end,
        bound = function(_, _, native) return bound[native] end,
        peek = function(_, handle) return payloads[handle] end,
        begin = function(_, handle) return payloads[handle] end,
        claimReady = function(_, _, contact, native, compatible)
            local role = compatible(node, contact)
            if role == nil then return nil end
            bound[native] = boxHandle
            return boxHandle, boxPayload
        end,
        bind = function(_, _, handle, native) bound[native] = handle; return handle end,
    }
    local session = { complete = function() error("Mystery box must not complete at use") end }
    mystery.attach(module, session, function() return state end, function() end, room)
    callbacks.UseConsumableItem(nil, {}, function(nativeItem)
        callbacks.ConsumableUsedPresentation(nil, {}, function() return true end, {}, nativeItem, {})
        callbacks.UnwrapRandomLoot(nil, {}, function()
            callbacks.GiveLoot(nil, {}, function(args)
                lu.assertEquals(args.ForceLootName, provider.Name)
                return callbacks.CreateLoot(nil, {}, function() return provider end, args)
            end, {})
        end, nativeItem)
    end, item, {}, {})
    lu.assertEquals(bound[item], boxHandle)
    lu.assertEquals(bound[provider], boxHandle)
end
