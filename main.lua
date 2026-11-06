--[[ Ventana — a small web browser with tabs for KOReader. ]]
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local Browser = require("ventana/browser")

local Ventana = WidgetContainer:extend{
    name = "ventana",
    is_doc_only = false,
}

--- Open the browser on top of whatever is showing (file manager, Estante, reader).
function Ventana.open(ui)
    for _, w in ipairs(UIManager._window_stack or {}) do
        if w.widget and w.widget.name == "ventana" then return end -- already open
    end
    UIManager:show(Browser:new{ ui = ui })
end

function Ventana:init()
    -- file manager / home screen only: the reading view stays exactly as it is
    if self.ui.document then return end
    Dispatcher:registerAction("ventana_open", {
        category = "none", event = "OpenVentana", title = _("Web browser (Ventana)"), general = true,
    })
    self.ui.menu:registerToMainMenu(self)
end

function Ventana:onOpenVentana()
    Ventana.open(self.ui)
    return true
end

function Ventana:addToMainMenu(menu_items)
    menu_items.ventana = {
        text = _("Web browser"),
        sorting_hint = "search",
        callback = function() Ventana.open(self.ui) end,
    }
end

return Ventana
