-- =============================================================================
-- UI
-- =============================================================================
-- This file is imported from main.lua inside init().
-- Define drawTab and optional drawQuickContent here.
--
-- If the UI grows, keep this file as the public UI loader/router and split sections
-- into files under src/mods/ui/. Those files should expose bind/create functions
-- and return their own narrow draw surfaces.

local ui = {}
local quickModeOpts
local resetQuickOpts = {
    confirmLabel = "Confirm Reset",
}
local logModeOpts = {
    id = "template_log_mode",
}
local featureEnabledOpts = {
    label = "Enable Feature",
    tooltip = "Turns the feature on for this module.",
}
local modeOpts
local filterTextOpts = {
    label = "Filter",
    controlWidth = 180,
}

function ui.bind(deps)
    quickModeOpts = {
        label = "Mode",
        values = deps.MODE_VALUES,
        controlWidth = 140,
    }
    modeOpts = {
        label = "Mode",
        values = deps.MODE_VALUES,
        controlWidth = 180,
    }
    return ui
end

function ui.drawQuickContent(_, ctx)
    local draw = ctx.draw
    local state = ctx.data

    draw.widgets.dropdown(state.get("Mode"), quickModeOpts)

    if draw.widgets.confirmButton("template_quick_reset_all", "Reset", resetQuickOpts) then
        ctx.resetAll()
    end

    logModeOpts.action = ctx.actions.get("LogMode")
    draw.widgets.button("Log Mode", logModeOpts)
end

function ui.drawTab(_, ctx)
    local draw = ctx.draw
    local state = ctx.data

    draw.widgets.checkbox(state.get("FeatureEnabled"), featureEnabledOpts)
    draw.widgets.dropdown(state.get("Mode"), modeOpts)
    draw.widgets.inputText(state.get("FilterText"), filterTextOpts)

    draw.widgets.separator()
    draw.widgets.text("Start here: replace this with your real module UI.")
end

return ui
