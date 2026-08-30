-- Plan Executor is a thin consumer of the Run Planner execution-only JSON.
-- It freezes a decoded plan at StartNewRun and never imports planner code.
-- luacheck: globals rom import_as_fallback modutil lib _PLUGIN game reload import

local mods = rom.mods
mods["SGG_Modding-ENVY"].auto()

rom = rom
_PLUGIN = _PLUGIN
game = rom.game
modutil = mods["SGG_Modding-ModUtil"]
reload = mods["SGG_Modding-ReLoad"]
lib = mods["adamant-ModpackLib"]

local function initialize()
    import_as_fallback(rom.game)
    local data = import("mods/data.lua")
    local logic = import("mods/logic.lua").bind(data, _PLUGIN.config_mod_folder_path)
    local ui = import("mods/ui.lua").bind(data)
    local module = lib.createModule({
        pluginGuid = _PLUGIN.guid,
        modpack = "run-planner",
        id = "Plan_Executor",
        name = "Plan Executor",
        shortName = "Plan Executor",
        tooltip = "Execute a published Run Planner execution plan.",
    })
    if not module then return end
    module.data.define(data.buildStorage())
    module.status.define(data.buildStatus())
    module.ui.tab(ui.drawTab)
    module.ui.quickContent(ui.drawQuickContent)
    logic.attach(module, data)
    module.activate()
end

local loader = reload.auto_single()
modutil.once_loaded.game(function() loader.load(nil, initialize) end)
