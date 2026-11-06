--[[ Turn Wi-Fi on silently, without the "Do you want to turn on Wi-Fi?" prompt,
     when Z-library, the AI Assistant or Ventana (the browser) needs the network.
     Everything else keeps the normal behaviour (Settings → Network → "Action when Wi-Fi is off"). ]]
local NetworkMgr = require("ui/network/manager")
local logger = require("logger")

local AUTO = { "zlibrary%.koplugin/", "assistant%.koplugin/", "ventana%.koplugin/" }

local function from_auto_plugin()
    for level = 3, 60 do
        local info = debug.getinfo(level, "S")
        if not info then return false end
        local src = info.source or ""
        for _, pat in ipairs(AUTO) do
            if src:find(pat) then return true end
        end
    end
    return false
end

local orig_prompt = NetworkMgr.promptWifiOn
NetworkMgr.promptWifiOn = function(self, complete_callback, ...)
    if not self.pending_connection and from_auto_plugin() then
        logger.info("wifi-auto: turning Wi-Fi on without asking")
        return self:turnOnWifiAndWaitForConnection(complete_callback)
    end
    return orig_prompt(self, complete_callback, ...)
end
