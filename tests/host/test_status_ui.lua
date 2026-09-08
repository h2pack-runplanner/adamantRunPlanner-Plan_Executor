-- luacheck: globals TestStatusUi
local lu = require("luaunit")
local statusUi = require("mods.host.status_ui")
local hostData = require("mods.host.data")

TestStatusUi = {}

function TestStatusUi.testActivePlanSlotIsOnePersistedBoundedSetting()
    local storage = hostData.buildStorage()
    lu.assertEquals(#storage, 1)
    lu.assertEquals(storage[1].alias, "ActivePlanSlot")
    lu.assertEquals(storage[1].default, 1)
    lu.assertEquals(storage[1].min, 1)
    lu.assertEquals(storage[1].max, 6)
    lu.assertNil(storage[1].persist)
end

function TestStatusUi.testInspectionUsesTheBoundInboxCapabilityDirectly()
    local loads, statusReads, selections, drawn = 0, 0, {}, {}
    local inbox = {
        activeSlot = function() return 1 end,
        select = function(slot) selections[#selections + 1] = slot end,
        load = function(slot) loads = loads + 1; lu.assertEquals(slot, 1) end,
        status = function()
            statusReads = statusReads + 1
            return { file = "present", inspection = "inspected", protocol = 10 }
        end,
    }
    local ui = statusUi.bind(inbox)
    local field = { read = function() return 1 end }
    local widgets = {
        dropdown = function(target) lu.assertEquals(target, field) end,
        button = function() return true end,
        text = function(value) drawn[#drawn + 1] = value end,
    }

    ui.drawTab(nil, {
        data = { get = function(alias)
            lu.assertEquals(alias, "ActivePlanSlot")
            return field
        end },
        draw = { widgets = widgets },
    })

    lu.assertEquals(loads, 1)
    lu.assertEquals(statusReads, 2)
    lu.assertEquals(selections, {})
    lu.assertEquals(drawn[2], "File: present | Protocol: 10")
end

function TestStatusUi.testActivePlanSlotIsSelectedFromThePersistentUiField()
    local selected, loaded, dropdown = nil, nil, nil
    local inbox = {
        activeSlot = function() return 1 end,
        select = function(slot) selected = slot end,
        load = function(slot) loaded = slot end,
        status = function() return { file = "not-inspected", protocol = "unknown" } end,
    }
    local field = {
        read = function() return 4 end,
    }
    local ui = statusUi.bind(inbox)
    local widgets = {
        dropdown = function(target, opts)
            dropdown = { target = target, opts = opts }
        end,
        button = function() return false end,
        text = function() end,
    }

    ui.drawTab(nil, { data = { get = function(alias)
        lu.assertEquals(alias, "ActivePlanSlot")
        return field
    end }, draw = { widgets = widgets } })

    lu.assertEquals(dropdown.target, field)
    lu.assertEquals(dropdown.opts.values, { 1, 2, 3, 4, 5, 6 })
    lu.assertEquals(selected, 4)
    lu.assertNil(loaded)
end

return TestStatusUi
