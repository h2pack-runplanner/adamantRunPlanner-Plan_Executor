-- =============================================================================
-- ADAMANT MODULE TEMPLATE
-- =============================================================================
-- Copy this file as src/main.lua in a new module repo.
-- Fill in the SCAFFOLD_TODO sections below.
-- luacheck: globals rom import_as_fallback modutil lib _PLUGIN game

local mods = rom.mods
mods["SGG_Modding-ENVY"].auto()

---@diagnostic disable: lowercase-global
rom = rom
_PLUGIN = _PLUGIN
game = rom.game
modutil = mods["SGG_Modding-ModUtil"]
local reload = mods["SGG_Modding-ReLoad"]
---@module "adamant-ModpackLib"
---@type AdamantModpackLib
lib = mods["adamant-ModpackLib"]

local PACK_ID = error("SCAFFOLD_TODO: set PACK_ID to your pack id")
local MODULE_ID = "SCAFFOLD_TODO_ModuleId"
local PLUGIN_GUID = _PLUGIN.guid

local function init()
    import_as_fallback(rom.game)

    local data = import("mods/data.lua")
    local logic = import("mods/logic.lua").bind(data)
    local ui = import("mods/ui.lua").bind(data)

    local module = lib.createModule({
        pluginGuid = PLUGIN_GUID,
        modpack = PACK_ID,
        id = MODULE_ID,
        name = "SCAFFOLD_TODO Module Name",
        shortName = "SCAFFOLD_TODO_SHORT",
        tooltip = "SCAFFOLD_TODO tooltip",
    })
    if not module then
        return
    end

    module.data.define(data.buildStorage())
    module.ui.tab(ui.drawTab)
    module.ui.quickContent(ui.drawQuickContent)
    module.fallbackUi.attachGuiOnce(function(fallbackUi)
        rom.gui.add_imgui(fallbackUi.renderWindow)
        rom.gui.add_to_menu_bar(fallbackUi.addMenuBar)
    end)

    logic.attach(module)

    local ok = module.activate()
    if not ok then
        return
    end
end

local loader = reload.auto_single()

modutil.once_loaded.game(function()
    loader.load(nil, init)
end)
