local ui = {}

function ui.bind(data)
    local function draw(_, ctx)
        local drawApi = ctx.draw
        drawApi.widgets.text("Published file: active.runplanner.json")
        if drawApi.widgets.button("Inspect Published Plan (Future Run)", { id = "plan_executor_inspect" }) then
            data.inbox.load()
        end
        local inboxStatus = data.inbox.status()
        drawApi.widgets.text(
            "File: " .. tostring(inboxStatus.inspection)
                .. " | Protocol: " .. tostring(inboxStatus.protocol))
        if inboxStatus.error then drawApi.widgets.text("Error: " .. tostring(inboxStatus.error.code)) end
    end
    return { drawTab = draw, drawQuickContent = draw }
end

return ui
