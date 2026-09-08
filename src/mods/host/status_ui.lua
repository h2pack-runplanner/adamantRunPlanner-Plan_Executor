local ui = {}

local SLOT_VALUES = { 1, 2, 3, 4, 5, 6 }
local SLOT_LABELS = {
    [1] = "Slot 1",
    [2] = "Slot 2",
    [3] = "Slot 3",
    [4] = "Slot 4",
    [5] = "Slot 5",
    [6] = "Slot 6",
}

function ui.bind(inbox)
    assert(type(inbox) == "table" and type(inbox.activeSlot) == "function"
        and type(inbox.select) == "function" and type(inbox.load) == "function"
        and type(inbox.status) == "function", "status UI inbox dependency is required")
    local function logInspectionFailure(status)
        if not status.error or not rom or not rom.log or not rom.log.info then return end
        rom.log.info(
            "[RunPlanner] published-plan inspection failed code="
                .. tostring(status.error.code)
                .. " reason=" .. tostring(status.error.message)
        )
    end

    local function draw(_, ctx)
        local drawApi = ctx.draw
        assert(ctx.data and type(ctx.data.get) == "function", "status UI data dependency is required")
        local field = ctx.data.get("ActivePlanSlot")
        assert(field ~= nil, "status UI ActivePlanSlot data field is required")
        drawApi.widgets.dropdown(field, {
            id = "active_plan_slot",
            label = "Active plan",
            values = SLOT_VALUES,
            displayValues = SLOT_LABELS,
        })
        local selectedSlot = field:read()
        if inbox.activeSlot() ~= selectedSlot then inbox.select(selectedSlot) end
        drawApi.widgets.text("Published plan slot: " .. SLOT_LABELS[selectedSlot])
        if drawApi.widgets.button("Inspect Active Plan (Future Run)", { id = "plan_executor_inspect" }) then
            inbox.load(selectedSlot)
            logInspectionFailure(inbox.status())
        end
        local inboxStatus = inbox.status()
        drawApi.widgets.text(
            "File: " .. tostring(inboxStatus.file)
                .. " | Protocol: " .. tostring(inboxStatus.protocol))
        if inboxStatus.error then
            drawApi.widgets.text("Error: " .. tostring(inboxStatus.error.code))
            if inboxStatus.error.message then
                drawApi.widgets.text("Reason: " .. tostring(inboxStatus.error.message))
            end
        end
    end
    return { drawTab = draw, drawQuickContent = draw }
end

return ui
