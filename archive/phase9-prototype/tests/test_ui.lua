-- luacheck: globals TestUi

local lu = require("luaunit")
local ui = require("mods/ui")

TestUi = {}

local function render(status)
    local text = {}
    ui.bind({
        runtime = {
            activeSlot = function() return "active.runplanner.json" end,
            load = function() error("button is not pressed") end,
            status = function() return status end,
        },
    })
    ui.drawTab(nil, {
        draw = { widgets = {
            button = function() return false end,
            separator = function() end,
            text = function(value) text[#text + 1] = value end,
        } },
        status = { read = function(alias)
            lu.assertEquals(alias, "ExecutionSessionStatus")
            return "state=active route=Underworld cursor=f-entry"
        end },
    })
    return text
end

function TestUi.testFreshInspectorDoesNotClaimTheFixedFileWasRead()
    local text = render({
        inspection = "not-inspected", load = "idle", protocol = "unknown", catalog = "unknown",
        routeAvailability = "unknown",
    })
    lu.assertEquals(text[1], "Published file: active.runplanner.json")
    lu.assertStrContains(text[2], "Frozen current-run session: state=active")
    lu.assertEquals(text[3], "File inspection: not inspected since this module reload.")
    lu.assertNil(text[3]:find("Slot:", 1, true))
end

function TestUi.testInspectionResultIsExplicitlyScopedToThisModuleInstance()
    local text = render({
        inspection = "inspected", load = "ready", protocol = "ready", catalog = "catalog-test",
        routeAvailability = "Underworld", fingerprint = "plan-fingerprint",
    })
    lu.assertStrContains(text[3], "File inspection: inspected in this module instance")
    lu.assertStrContains(text[3], "Protocol: ready")
    lu.assertEquals(text[4], "Fingerprint: plan-fingerprint")
end

return TestUi
