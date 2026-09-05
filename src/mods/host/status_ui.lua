local ui = {}

function ui.bind(data)
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
        drawApi.widgets.text("Published file: active.runplanner.json")
        if drawApi.widgets.button("Inspect Published Plan (Future Run)", { id = "plan_executor_inspect" }) then
            data.inbox.load()
            logInspectionFailure(data.inbox.status())
        end
        local inboxStatus = data.inbox.status()
        drawApi.widgets.text(
            "File: " .. tostring(inboxStatus.inspection)
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
