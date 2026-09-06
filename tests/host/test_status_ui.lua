-- luacheck: globals TestStatusUi
local lu = require("luaunit")
local statusUi = require("mods.host.status_ui")

TestStatusUi = {}

function TestStatusUi.testInspectionUsesTheBoundInboxCapabilityDirectly()
    local loads, statusReads, drawn = 0, 0, {}
    local inbox = {
        load = function() loads = loads + 1 end,
        status = function()
            statusReads = statusReads + 1
            return { inspection = "inspected", protocol = 10 }
        end,
    }
    local ui = statusUi.bind(inbox)
    local widgets = {
        button = function() return true end,
        text = function(value) drawn[#drawn + 1] = value end,
    }

    ui.drawTab(nil, { draw = { widgets = widgets } })

    lu.assertEquals(loads, 1)
    lu.assertEquals(statusReads, 2)
    lu.assertEquals(drawn[2], "File: inspected | Protocol: 10")
end

return TestStatusUi
