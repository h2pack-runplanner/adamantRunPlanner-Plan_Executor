-- Minimal explicit inbox UI. All controls invoke the fixed runtime adapter;
-- no project, route, reward, or eligibility semantics are presented here.

local ui = {}
local runtime

local function statusText(status)
    if status.error then
        return "Error: " .. tostring(status.error.code) .. " - " .. tostring(status.error.message)
    end
    return string.format(
        "Slot: %s | Load: %s | Protocol: %s | Catalog: %s | Routes: %s",
        tostring(status.slot), tostring(status.load), tostring(status.protocol),
        tostring(status.catalog), tostring(status.routeAvailability)
    )
end

function ui.bind(deps)
    runtime = deps.runtime
    return ui
end

local function drawPlanUi(_, ctx)
    local draw = ctx.draw
    if draw.widgets.button("Read Published Plan", {
        id = "plan_executor_read_published",
        tooltip = "Read active.runplanner.json from this module's config folder.",
    }) then
        runtime.load()
    end
    draw.widgets.separator()
    local status = runtime.status()
    draw.widgets.text(statusText(status))
    if status.fingerprint then
        draw.widgets.text("Fingerprint: " .. tostring(status.fingerprint))
    end
end

function ui.drawTab(host, ctx)
    return drawPlanUi(host, ctx)
end

function ui.drawQuickContent(host, ctx)
    return drawPlanUi(host, ctx)
end

return ui
