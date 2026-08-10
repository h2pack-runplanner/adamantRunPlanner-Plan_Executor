-- Minimal explicit inbox UI. All controls invoke the fixed runtime adapter;
-- no project, route, reward, or eligibility semantics are presented here.

local ui = {}
local runtime

local function inspectionText(status)
    if status.inspection == "not-inspected" then
        return "File inspection: not inspected since this module reload."
    end
    if status.inspection == "reading" then
        return "File inspection: reading the fixed published file."
    end
    if status.error then
        return "File inspection: failed (" .. tostring(status.error.code) .. ") - "
            .. tostring(status.error.message)
    end
    return string.format(
        "File inspection: inspected in this module instance | Protocol: %s | Catalog: %s | Routes: %s",
        tostring(status.protocol),
        tostring(status.catalog), tostring(status.routeAvailability)
    )
end

function ui.bind(deps)
    runtime = deps.runtime
    return ui
end

local function drawPlanUi(_, ctx)
    local draw = ctx.draw
    local activeSlot = type(runtime.activeSlot) == "function" and runtime.activeSlot() or "active.runplanner.json"
    draw.widgets.text("Published file: " .. tostring(activeSlot))
    if draw.widgets.button("Inspect Published Plan (Future Run)", {
        id = "plan_executor_read_published",
        tooltip = "Read " .. tostring(activeSlot) .. " for a future run or manual inspection. "
            .. "It never reloads a frozen current-run session.",
    }) then
        runtime.load()
    end
    draw.widgets.separator()
    local status = runtime.status()
    if ctx.status and type(ctx.status.read) == "function" then
        draw.widgets.text("Frozen current-run session: " .. tostring(ctx.status.read("ExecutionSessionStatus")))
    end
    draw.widgets.text(inspectionText(status))
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
