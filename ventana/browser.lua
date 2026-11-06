--[[ Ventana: the browser window (tabs, toolbar, page view). ]]
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local HtmlBoxWidget = require("ui/widget/htmlboxwidget")
local IconButton = require("ui/widget/iconbutton")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local logger = require("logger")
local Screen = Device.screen
local _ = require("gettext")
local T = require("ffi/util").template

local Loader = require("ventana/loader")
local Sites = require("ventana/sites")

local MAX_VISIBLE_TABS = 4
local MAX_TABS = 12

---------------------------------------------------------------------------
-- a tappable box

local Tappable = InputContainer:extend{
    callback = nil,
    hold_callback = nil,
}

function Tappable:init()
    self.dimen = Geom:new{ w = self[1]:getSize().w, h = self[1]:getSize().h }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        Hold = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }
end

function Tappable:onTap()
    if self.callback then self.callback() end
    return true
end

function Tappable:onHold()
    if self.hold_callback then self.hold_callback() return true end
    if self.callback then self.callback() end
    return true
end

---------------------------------------------------------------------------

local FONT_CSS = [[
@font-face { font-family: "VSerif"; src: url("fonts/NotoSerif-Regular.ttf"); }
@font-face { font-family: "VSerif"; font-weight: bold; src: url("fonts/NotoSerif-Bold.ttf"); }
@font-face { font-family: "VSerif"; font-style: italic; src: url("fonts/NotoSerif-Italic.ttf"); }
@font-face { font-family: "VSerif"; font-weight: bold; font-style: italic; src: url("fonts/NotoSerif-BoldItalic.ttf"); }
body { font-family: "VSerif", serif; }
]]

local CSS = [[
@page { margin: 0; }
body { margin: 0; padding: 0; line-height: 1.38; widows: 2; orphans: 2; }
h1 { font-size: 1.55em; line-height: 1.15; margin: 0.2em 0 0.5em 0; }
h2 { font-size: 1.28em; line-height: 1.2; margin: 1.1em 0 0.35em 0; }
h3 { font-size: 1.12em; margin: 1em 0 0.3em 0; }
h4, h5, h6 { font-size: 1em; margin: 0.9em 0 0.3em 0; }
p { margin: 0 0 0.6em 0; text-align: left; }
a, a[href] { color: black; text-decoration: underline; }
blockquote { margin: 0.5em 0 0.5em 1.2em; font-style: italic; }
pre, code, kbd, samp, tt { font-family: monospace; font-size: 0.82em; }
pre { white-space: pre-wrap; margin: 0.5em 0; }
ul, ol { margin: 0.3em 0 0.6em 0; padding-left: 1.4em; }
li { margin: 0.12em 0; }
table { border-collapse: collapse; margin: 0.4em 0; font-size: 0.86em; }
td, th { padding: 0.12em 0.3em; vertical-align: top; text-align: left; }
th { font-weight: bold; }
img { display: block; max-width: 100%; margin: 0.3em auto; }
.v-nav { font-size: 0.78em; line-height: 1.6; margin: 0 0 0.8em 0; padding-bottom: 0.4em; border-bottom: 1px solid #888; }
figure { margin: 0.6em 0; }
figcaption, caption { font-size: 0.82em; font-style: italic; }
sup, sub { font-size: 0.7em; }
hr { border: 0; border-top: 1px solid black; margin: 0.8em 0; }
small { font-size: 0.85em; }
.v-site { font-size: 0.8em; text-transform: uppercase; letter-spacing: 0.08em; margin: 0 0 0.3em 0; }
.v-hello h1 { font-size: 1.7em; margin-top: 0.4em; }
.v-hint { font-size: 0.9em; }
table.v-dial { width: 100%; font-size: 1em; margin: 0.2em 0 0.8em 0; }
table.v-dial td { width: 50%; padding: 0.45em 0.3em 0.45em 0; border-bottom: 1px solid #999; }
table.v-dial small { font-size: 0.75em; }
ul.v-list { list-style-type: none; padding-left: 0; }
ul.v-list li { margin: 0.35em 0; }
]]

local Browser = InputContainer:extend{
    name = "ventana",
    covers_fullscreen = true,
    ui = nil,
}

function Browser:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.store = LuaSettings:open(DataStorage:getSettingsDir() .. "/ventana.lua")
    self.tabs = self.store:readSetting("tabs") or {}
    self.active = self.store:readSetting("active") or 1
    self.bookmarks = self.store:readSetting("bookmarks") or {}
    self.history = self.store:readSetting("history") or {}
    self.font_size = self.store:readSetting("font_size") or Screen:scaleBySize(17)
    self.images = self.store:readSetting("images")
    if self.images == nil then self.images = true end
    if #self.tabs == 0 then
        self.tabs = { self:newTabState(Sites.START) }
        self.active = 1
    end
    self.active = math.max(1, math.min(self.active, #self.tabs))
    self.turns = 0

    -- geometry
    self.tab_h = Screen:scaleBySize(38)
    self.bar_h = Screen:scaleBySize(46)
    self.foot_h = Screen:scaleBySize(26)
    self.margin = Screen:scaleBySize(14)
    self.page_w = self.dimen.w - 2 * self.margin
    self.page_h = self.dimen.h - self.tab_h - self.bar_h - self.foot_h - 2 * Size.line.medium - self.margin

    local body_range = function()
        return Geom:new{ x = 0, y = self.tab_h + self.bar_h, w = self.dimen.w, h = self.page_h + self.margin }
    end
    self.ges_events = {
        PageTap = { GestureRange:new{ ges = "tap", range = body_range } },
        PageSwipe = { GestureRange:new{ ges = "swipe", range = body_range } },
        PageHold = { GestureRange:new{ ges = "hold", range = body_range } },
        PageHoldPan = { GestureRange:new{ ges = "hold_pan", range = body_range, rate = Screen.low_pan_rate and 5.0 or 30.0 } },
        PageHoldRelease = { GestureRange:new{ ges = "hold_release", range = body_range } },
    }
    self.status = nil
    self:build()
    UIManager:nextTick(function()
        self:openCurrent()
        -- bring Wi-Fi up right away, so it's ready by the time an address is typed
        if not self._net_wait and not NetworkMgr:isWifiOn() then
            Browser.wifiOn(function() end)
        end
    end)
end

function Browser:newTabState(url)
    return { hist = { { url = url, title = url == Sites.START and _("Start") or url } }, pos = 1 }
end

function Browser:tab() return self.tabs[self.active] end
function Browser:entry()
    local t = self:tab()
    return t.hist[t.pos]
end

function Browser:save()
    -- keep at most 30 history entries per tab
    for _, t in ipairs(self.tabs) do
        while #t.hist > 30 do table.remove(t.hist, 1); t.pos = math.max(1, t.pos - 1) end
    end
    self.store:saveSetting("tabs", self.tabs)
    self.store:saveSetting("active", self.active)
    self.store:saveSetting("bookmarks", self.bookmarks)
    self.store:saveSetting("history", self.history)
    self.store:saveSetting("font_size", self.font_size)
    self.store:saveSetting("images", self.images)
    self.store:flush()
end

---------------------------------------------------------------------------
-- layout

local function host_of(url)
    if url == Sites.START then return "" end
    return ((url:match("^%a+://([^/:?#]+)") or url):gsub("^www%.", ""))
end

local function label_of(e)
    if e.url == Sites.START then return _("Start") end
    if e.title and e.title ~= "" and e.title ~= e.url then return e.title end
    return host_of(e.url)
end

function Browser:buildTabStrip()
    local W = self.dimen.w
    local h = self.tab_h
    local n = #self.tabs
    -- window of visible tabs around the active one
    local first = 1
    if n > MAX_VISIBLE_TABS then
        first = math.max(1, math.min(self.active - 1, n - MAX_VISIBLE_TABS + 1))
    end
    local last = math.min(n, first + MAX_VISIBLE_TABS - 1)
    local side_w = h + Screen:scaleBySize(8)
    local more_w = (n > MAX_VISIBLE_TABS) and side_w or 0
    local avail = W - 2 * side_w - more_w
    local tw = math.floor(avail / (last - first + 1))
    tw = math.min(tw, math.floor(W * 0.42))
    local row = HorizontalGroup:new{ align = "bottom" }
    for i = first, last do
        local t = self.tabs[i]
        local e = t.hist[t.pos]
        local active = (i == self.active)
        local title = label_of(e)
        local label = TextWidget:new{
            text = title,
            face = Font:getFace(active and "smalltfont" or "smallinfofont", 15),
            bold = active,
            max_width = tw - Screen:scaleBySize(16),
            fgcolor = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        }
        local box = FrameContainer:new{
            width = tw - Screen:scaleBySize(4),
            height = active and h or (h - Screen:scaleBySize(5)),
            padding = 0, padding_left = Screen:scaleBySize(8),
            margin = 0,
            bordersize = active and Size.border.thick or Size.border.thin,
            radius = Screen:scaleBySize(5),
            background = active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_LIGHT_GRAY,
            color = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
            LeftContainer:new{
                dimen = Geom:new{ w = tw - Screen:scaleBySize(14), h = (active and h or (h - Screen:scaleBySize(5))) - 2 * Size.border.thick },
                label,
            },
        }
        table.insert(row, Tappable:new{
            callback = function() self:switchTab(i) end,
            hold_callback = function() self:tabMenu(i) end,
            box,
        })
        table.insert(row, HorizontalSpan:new{ width = Screen:scaleBySize(4) })
    end
    if more_w > 0 then
        table.insert(row, IconButton:new{
            icon = "control.expand", width = h - Screen:scaleBySize(10), height = h - Screen:scaleBySize(10),
            padding = Screen:scaleBySize(5),
            callback = function() self:showTabList() end,
        })
    end
    local plus = IconButton:new{
        icon = "plus", width = h - Screen:scaleBySize(10), height = h - Screen:scaleBySize(10),
        padding = Screen:scaleBySize(5),
        callback = function() self:newTab(Sites.START) end,
        hold_callback = function() self:showTabList() end,
    }
    local close = IconButton:new{
        icon = "close", width = h - Screen:scaleBySize(12), height = h - Screen:scaleBySize(12),
        padding = Screen:scaleBySize(6),
        callback = function() self:onClose() end,
    }
    return OverlapGroup:new{
        dimen = Geom:new{ w = W, h = h },
        LeftContainer:new{ dimen = Geom:new{ w = W, h = h }, HorizontalGroup:new{
            align = "bottom",
            HorizontalSpan:new{ width = Screen:scaleBySize(6) }, row, plus } },
        RightContainer:new{ dimen = Geom:new{ w = W, h = h }, close },
    }
end

function Browser:buildToolbar()
    local W = self.dimen.w
    local h = self.bar_h
    local isz = Screen:scaleBySize(30)
    local pad = Screen:scaleBySize(7)
    local t = self:tab()
    local function icon(name, cb, enabled, hold)
        return IconButton:new{
            icon = name, width = isz, height = isz, padding = pad,
            enabled = enabled ~= false,
            callback = cb, hold_callback = hold,
        }
    end
    local e = self:entry()
    local back = icon("chevron.left", function() self:goBack() end, t.pos > 1)
    local fwd = icon("chevron.right", function() self:goForward() end, t.pos < #t.hist)
    local reload = icon("cre.render.reload", function() self:reload() end, e.url ~= Sites.START)
    local reader = icon("book.opened", function() self:toggleReader() end, e.url ~= Sites.START)
    local menu = icon("appbar.menu", function() self:showMenu() end)
    local icons_w = 5 * (isz + 2 * pad)
    local addr_w = W - icons_w - Screen:scaleBySize(12)
    local addr_text
    if self.status then
        addr_text = self.status
    elseif e.url == Sites.START then
        addr_text = _("Search or type a web address")
    else
        addr_text = host_of(e.url) .. (e.reader and "  ·  " .. _("reader") or "")
    end
    local addr = FrameContainer:new{
        width = addr_w, height = h - Screen:scaleBySize(10),
        padding = 0, padding_left = Screen:scaleBySize(12), margin = 0,
        bordersize = Size.border.thin, radius = Screen:scaleBySize(18),
        background = Blitbuffer.COLOR_WHITE,
        LeftContainer:new{
            dimen = Geom:new{ w = addr_w - Screen:scaleBySize(24), h = h - Screen:scaleBySize(12) },
            TextWidget:new{
                text = addr_text,
                face = Font:getFace("smallinfofont", 17),
                fgcolor = (e.url == Sites.START and not self.status) and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK,
                max_width = addr_w - Screen:scaleBySize(30),
            },
        },
    }
    if e.reader then
        reader = FrameContainer:new{ padding = 0, margin = 0, bordersize = 0, radius = Screen:scaleBySize(6),
            background = Blitbuffer.COLOR_LIGHT_GRAY, reader }
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = W, h = h },
        HorizontalGroup:new{
            align = "center",
            back, fwd,
            Tappable:new{ callback = function() self:editAddress() end,
                hold_callback = function() self:addressMenu() end, addr },
            reload, reader, menu,
        },
    }
end

function Browser:buildFooter()
    local W = self.dimen.w
    local text = ""
    if self.html and self.html.page_count > 0 then
        text = T("%1 / %2", self.html.page_number, self.html.page_count)
    end
    local e = self:entry()
    local left = TextWidget:new{
        text = (e.url ~= Sites.START) and (e.title or "") or "",
        face = Font:getFace("ffont", 13),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = W * 0.7,
    }
    local right = TextWidget:new{ text = text, face = Font:getFace("ffont", 14) }
    -- thin progress line
    local frac = (self.html and self.html.page_count > 1) and ((self.html.page_number - 1) / (self.html.page_count - 1)) or 0
    local pw = W - 2 * self.margin
    local prog = HorizontalGroup:new{
        LineWidget:new{ dimen = Geom:new{ w = math.max(1, math.floor(pw * frac)), h = Size.line.thick }, background = Blitbuffer.COLOR_BLACK },
        LineWidget:new{ dimen = Geom:new{ w = math.max(1, pw - math.floor(pw * frac)), h = Size.line.thin }, background = Blitbuffer.COLOR_GRAY },
    }
    return VerticalGroup:new{
        CenterContainer:new{ dimen = Geom:new{ w = W, h = Size.line.thick }, prog },
        OverlapGroup:new{
            dimen = Geom:new{ w = W, h = self.foot_h - Size.line.thick },
            LeftContainer:new{ dimen = Geom:new{ w = W, h = self.foot_h - Size.line.thick }, HorizontalGroup:new{ HorizontalSpan:new{ width = self.margin }, left } },
            RightContainer:new{ dimen = Geom:new{ w = W, h = self.foot_h - Size.line.thick }, HorizontalGroup:new{ right, HorizontalSpan:new{ width = self.margin } } },
        },
    }
end

function Browser:build()
    local W = self.dimen.w
    -- the page sits a margin below the toolbar
    local page_area = VerticalGroup:new{
        CenterContainer:new{ dimen = Geom:new{ w = W, h = self.margin }, HorizontalSpan:new{ width = 1 } },
        CenterContainer:new{ dimen = Geom:new{ w = W, h = self.page_h }, self.html or HorizontalSpan:new{ width = 1 } },
    }
    self.page_area = page_area
    self[1] = FrameContainer:new{
        padding = 0, margin = 0, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        width = W, height = self.dimen.h,
        VerticalGroup:new{
            self:buildTabStrip(),
            LineWidget:new{ dimen = Geom:new{ w = W, h = Size.line.medium }, background = Blitbuffer.COLOR_BLACK },
            self:buildToolbar(),
            LineWidget:new{ dimen = Geom:new{ w = W, h = Size.line.medium }, background = Blitbuffer.COLOR_DARK_GRAY },
            page_area,
            self:buildFooter(),
        },
    }
end

function Browser:refresh(mode)
    self:build()
    UIManager:setDirty(self, function() return mode or "ui", self.dimen end)
end

function Browser:setStatus(text)
    self.status = text
    self:build()
    UIManager:setDirty(self, function() return "fast", self.dimen end)
    UIManager:forceRePaint()
end

---------------------------------------------------------------------------
-- pages

function Browser:freeHtml()
    if self.html then
        self.html:free()
        self.html = nil
    end
end

function Browser:render(page, page_no)
    self:freeHtml()
    self.html = HtmlBoxWidget:new{
        dimen = Geom:new{ w = self.page_w, h = self.page_h },
        highlight_text_selection = true,
        dialog = self,
        html_link_tapped_callback = function(link) self:onLink(link) end,
    }
    local css = (Loader.ensureFonts() and FONT_CSS or "") .. CSS
    local ok, err = pcall(self.html.setContent, self.html, page.body, css, self.font_size, false, false, Loader.root)
    if not ok then
        logger.warn("Ventana: render failed", err)
        local body = Sites.error_page(page.url, "This page could not be laid out: " .. tostring(err))
        self.html:setContent(body, css, self.font_size, false, false, Loader.root)
    end
    local n = self.html.page_count
    self.html:setPageNumber(math.max(1, math.min(page_no or 1, n)))
    self.status = nil
    self:refresh("full")
end

function Browser:envForLoader()
    return { bookmarks = self.bookmarks, history = self.history, max_img_w = self.page_w }
end

--- (re)open the current history entry of the active tab, from cache when possible
function Browser:openCurrent(refresh)
    local e = self:entry()
    local opts = { reader = e.reader, images = self.images, refresh = refresh }
    local function go()
        local page = Loader.load(e.url, opts, function(s) self:setStatus(s) end, self:envForLoader())
        if page.url ~= e.url and e.url ~= Sites.START then e.url = page.url end
        e.title = page.title
        if not page.err and not page.internal then self:addHistory(e.url, page.title) end
        self:save()
        self:render(page, e.page)
        if page.download then self:offerDownload(page.download) end
    end
    if e.url == Sites.START or (not refresh and Loader.isCached(e.url, opts)) then
        go()
    else
        self:withNetwork(go)
    end
end

--- Run fn once we're online. Wi-Fi is switched on silently (no "Turn on Wi-Fi?" prompt):
--- opening the browser is reason enough.
function Browser:withNetwork(fn)
    if NetworkMgr:isOnline() then
        self:setStatus(_("Loading…"))
        UIManager:nextTick(fn)
        return
    end
    self:setStatus(_("Connecting to Wi-Fi…"))
    local token = {}
    self._net_wait = token
    local ok = Browser.wifiOn(function()
        if self._net_wait ~= token or self.closed then return end
        self._net_wait = nil
        self:setStatus(_("Loading…"))
        UIManager:nextTick(fn)
    end)
    local function give_up()
        if self._net_wait ~= token or self.closed then return end
        self._net_wait = nil
        self.status = nil
        local body = Sites.error_page(self:entry().url, _("Couldn't connect to Wi-Fi."))
        self:render({ url = self:entry().url, body = body })
    end
    if ok == false then give_up() else UIManager:scheduleIn(50, give_up) end
end

--- Switch Wi-Fi on without asking; cb runs once connected.
--- Returns false if the attempt failed outright.
function Browser.wifiOn(cb)
    if NetworkMgr.pending_connection then
        -- an attempt is already underway (e.g. the warm-up): poll for it
        local tries = 0
        local function poll()
            tries = tries + 1
            if NetworkMgr:isConnected() then cb()
            elseif tries < 180 then UIManager:scheduleIn(0.25, poll) end
        end
        UIManager:scheduleIn(0.25, poll)
        return
    end
    return NetworkMgr:turnOnWifiAndWaitForConnection(cb)
end

function Browser:navigate(url, opts)
    opts = opts or {}
    if not url then return end
    local t = self:tab()
    -- remember where we were on the page we're leaving
    if self.html then t.hist[t.pos].page = self.html.page_number end
    for i = #t.hist, t.pos + 1, -1 do t.hist[i] = nil end
    local cur = t.hist[t.pos]
    local reader = opts.reader
    if reader == nil then
        -- stay in reader mode while following links on the same site
        reader = cur and cur.reader and host_of(cur.url) == host_of(url) or false
    end
    table.insert(t.hist, { url = url, title = url, reader = reader })
    t.pos = #t.hist
    self:openCurrent()
end

function Browser:goBack()
    local t = self:tab()
    if t.pos <= 1 then return end
    if self.html then t.hist[t.pos].page = self.html.page_number end
    t.pos = t.pos - 1
    self:openCurrent()
end

function Browser:goForward()
    local t = self:tab()
    if t.pos >= #t.hist then return end
    if self.html then t.hist[t.pos].page = self.html.page_number end
    t.pos = t.pos + 1
    self:openCurrent()
end

function Browser:reload()
    local e = self:entry()
    e.page = self.html and self.html.page_number or 1
    self:openCurrent(true)
end

function Browser:toggleReader()
    local e = self:entry()
    if e.url == Sites.START then return end
    e.reader = not e.reader
    e.page = 1
    self:openCurrent()
end

function Browser:addHistory(url, title)
    for i = #self.history, 1, -1 do
        if self.history[i].url == url then table.remove(self.history, i) end
    end
    table.insert(self.history, 1, { url = url, title = title, time = os.time() })
    while #self.history > 100 do table.remove(self.history) end
end

function Browser:onLink(link)
    if link.page then
        self.html:setPageNumber(link.page + 1)
        self.html:freeBb()
        self:refresh("partial")
        return
    end
    local uri = link.uri
    if not uri then return end
    if uri:match("^https?://") or uri == Sites.START then
        self:navigate(uri)
    elseif uri:match("^mailto:") then
        UIManager:show(InfoMessage:new{ text = uri:gsub("^mailto:", ""), timeout = 3 })
    end
end

function Browser:offerDownload(dl)
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = T(_("Downloaded %1.\nOpen it in the reader?"), dl.name),
        ok_text = _("Open"),
        ok_callback = function()
            self:onClose()
            local ReaderUI = require("apps/reader/readerui")
            ReaderUI:showReader(dl.path)
        end,
    })
end

---------------------------------------------------------------------------
-- tabs

function Browser:switchTab(i)
    if i == self.active then return end
    if self.html then self:entry().page = self.html.page_number end
    self.active = i
    self:openCurrent()
end

function Browser:newTab(url)
    if #self.tabs >= MAX_TABS then
        UIManager:show(InfoMessage:new{ text = T(_("You have %1 tabs open. Close one first."), #self.tabs), timeout = 3 })
        return
    end
    if self.html then self:entry().page = self.html.page_number end
    table.insert(self.tabs, self.active + 1, self:newTabState(url))
    self.active = self.active + 1
    if url == Sites.START then
        self:openCurrent()
        self:editAddress()
    else
        self:openCurrent()
    end
end

function Browser:closeTab(i)
    table.remove(self.tabs, i)
    if #self.tabs == 0 then
        self.tabs = { self:newTabState(Sites.START) }
        self.active = 1
    elseif self.active > i or self.active > #self.tabs then
        self.active = math.max(1, self.active - 1)
    end
    self:openCurrent()
end

function Browser:tabMenu(i)
    local dialog
    dialog = ButtonDialog:new{
        title = label_of(self.tabs[i].hist[self.tabs[i].pos]),
        buttons = {
            {{ text = _("Close tab"), callback = function() UIManager:close(dialog); self:closeTab(i) end }},
            {{ text = _("Close other tabs"), callback = function()
                UIManager:close(dialog)
                self.tabs = { self.tabs[i] }; self.active = 1
                self:openCurrent()
            end }},
            {{ text = _("All tabs…"), callback = function() UIManager:close(dialog); self:showTabList() end }},
        },
    }
    UIManager:show(dialog)
end

function Browser:showTabList()
    local buttons = {}
    local dialog
    for i, t in ipairs(self.tabs) do
        local e = t.hist[t.pos]
        table.insert(buttons, {
            { text = (i == self.active and "▸ " or "") .. label_of(e), align = "left",
              callback = function() UIManager:close(dialog); self:switchTab(i) end,
              hold_callback = function() UIManager:close(dialog); self:closeTab(i) end },
        })
    end
    table.insert(buttons, {{ text = _("+ New tab"), callback = function() UIManager:close(dialog); self:newTab(Sites.START) end }})
    dialog = ButtonDialog:new{ title = T(_("%1 tabs · hold one to close it"), #self.tabs), buttons = buttons }
    UIManager:show(dialog)
end

---------------------------------------------------------------------------
-- address bar & menus

function Browser:editAddress(prefill)
    local e = self:entry()
    local dialog
    dialog = InputDialog:new{
        title = _("Go to"),
        input = (prefill and e.url ~= Sites.START) and e.url or "",
        input_hint = _("web address, or search words  (w … = Wikipedia, es … = Wikipedia ES)"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("New tab"), callback = function()
                local url = Sites.resolve_input(dialog:getInputText())
                UIManager:close(dialog)
                if url then self:newTab(url) end
            end },
            { text = _("Go"), is_enter_default = true, callback = function()
                local url = Sites.resolve_input(dialog:getInputText())
                UIManager:close(dialog)
                if url then self:navigate(url) end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Browser:addressMenu()
    -- hold the address bar: edit the current address
    self:editAddress(true)
end

function Browser:isBookmarked(url)
    for i, b in ipairs(self.bookmarks) do if b.url == url then return i end end
end

function Browser:showMenu()
    local e = self:entry()
    local dialog
    local bm = self:isBookmarked(e.url)
    local function close() UIManager:close(dialog) end
    local buttons = {
        {
            { text = _("Start page"), callback = function() close(); self:navigate(Sites.START) end },
            { text = bm and _("★ Bookmarked") or _("☆ Bookmark"), enabled = e.url ~= Sites.START, callback = function()
                close()
                if bm then table.remove(self.bookmarks, bm)
                else table.insert(self.bookmarks, 1, { url = e.url, title = e.title }) end
                self:save()
                UIManager:show(InfoMessage:new{ text = bm and _("Bookmark removed") or _("Bookmarked — it's on the start page"), timeout = 2 })
            end },
        },
        {
            { text = _("Text  −"), callback = function()
                self.font_size = math.max(Screen:scaleBySize(11), self.font_size - Screen:scaleBySize(1.5))
                close(); self:relayout()
            end },
            { text = _("Text  +"), callback = function()
                self.font_size = math.min(Screen:scaleBySize(30), self.font_size + Screen:scaleBySize(1.5))
                close(); self:relayout()
            end },
        },
        {
            { text = self.images and _("Images: on") or _("Images: off"), callback = function()
                self.images = not self.images
                close(); self:save(); self:openCurrent()
            end },
            { text = _("Go to page…"), callback = function() close(); self:gotoPage() end },
        },
        {
            { text = _("Clear history & cache"), callback = function()
                close()
                self.history = {}
                Loader.clear()
                self:save()
                UIManager:show(InfoMessage:new{ text = _("Cleared."), timeout = 2 })
            end },
            { text = _("Close browser"), callback = function() close(); self:onClose() end },
        },
    }
    dialog = ButtonDialog:new{ title = (e.title or "") .. "\n" .. (e.url ~= Sites.START and e.url or ""), title_align = "center", buttons = buttons }
    UIManager:show(dialog)
end

function Browser:gotoPage()
    if not self.html then return end
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        value = self.html.page_number, value_min = 1, value_max = self.html.page_count,
        title_text = _("Go to page"),
        callback = function(spin)
            self.html:setPageNumber(spin.value)
            self.html:freeBb()
            self:refresh("full")
        end,
    })
end

function Browser:relayout()
    self:save()
    if not self.html then return end
    -- keep the reading position roughly the same
    local frac = (self.html.page_number - 1) / math.max(1, self.html.page_count)
    local e = self:entry()
    local page = Loader.load(e.url, { reader = e.reader, images = self.images }, nil, self:envForLoader())
    self:render(page, 1)
    local p = math.floor(frac * self.html.page_count) + 1
    self.html:setPageNumber(p)
    self.html:freeBb()
    self:refresh("full")
end

---------------------------------------------------------------------------
-- gestures

function Browser:turn(delta)
    if not self.html then return end
    local p = self.html.page_number + delta
    if p < 1 or p > self.html.page_count then return end
    self.html:setPageNumber(p)
    self.html:freeBb()
    self:entry().page = p
    self.turns = self.turns + 1
    self:build()
    -- e-ink: quick partial turns, a full flash every few pages to clear ghosting
    local mode = (self.turns % 6 == 0) and "full" or "partial"
    UIManager:setDirty(self, function() return mode, self.dimen end)
end

function Browser:onPageTap(_, ges)
    -- links are handled by the HtmlBoxWidget before we get here
    if ges.pos.x < self.dimen.w * 0.3 then self:turn(-1) else self:turn(1) end
    return true
end

function Browser:onPageSwipe(_, ges)
    local d = ges.direction
    if d == "west" or d == "north" then self:turn(1)
    elseif d == "east" or d == "south" then self:turn(-1) end
    return true
end

function Browser:onPageHold(_, ges)
    if not self.html then return true end
    local pos = self.html:getPosFromAbsPos(ges.pos)
    local link = pos and self.html:getLinkByPosition(pos)
    if link and link.uri then
        self.link_hold = true
        self:linkMenu(link.uri)
        return true
    end
    self.link_hold = false
    self.html:onHoldStartText(nil, ges)
    return true
end

function Browser:onPageHoldPan(_, ges)
    if self.html and not self.link_hold then self.html:onHoldPanText(nil, ges) end
    return true
end

function Browser:onPageHoldRelease(_, ges)
    if self.link_hold then self.link_hold = false; return true end
    if not self.html then return true end
    self.html:onHoldReleaseText(function(text) self:onTextSelected(text) end, ges)
    return true
end

function Browser:linkMenu(uri)
    local dialog
    dialog = ButtonDialog:new{
        title = uri,
        buttons = {
            {
                { text = _("Open in new tab"), callback = function() UIManager:close(dialog); self:newTab(uri) end },
                { text = _("Open"), callback = function() UIManager:close(dialog); self:navigate(uri) end },
            },
            {
                { text = _("Open in reader mode"), callback = function() UIManager:close(dialog); self:navigate(uri, { reader = true }) end },
                { text = _("Bookmark link"), callback = function()
                    UIManager:close(dialog)
                    table.insert(self.bookmarks, 1, { url = uri, title = uri })
                    self:save()
                end },
            },
        },
    }
    UIManager:show(dialog)
end

function Browser:onTextSelected(text)
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return end
    local is_word = not text:find("%s") and #text < 48
    local dict = self.ui and self.ui.dictionary
    if is_word and dict then
        dict:onLookupWord(text, false, nil, nil, nil, function() self:clearSelection() end)
        return
    end
    local dialog
    local short = #text > 120 and text:sub(1, 117) .. "…" or text
    dialog = ButtonDialog:new{
        title = short,
        buttons = {
            {
                { text = _("Dictionary"), enabled = dict ~= nil, callback = function() UIManager:close(dialog); dict:onLookupWord(text) end },
                { text = _("Copy"), callback = function() UIManager:close(dialog); Device.input.setClipboardText(text) end },
            },
            {
                { text = _("Wikipedia (new tab)"), callback = function() UIManager:close(dialog); self:newTab(Sites.resolve_input("w " .. text)) end },
                { text = _("Search (new tab)"), callback = function() UIManager:close(dialog); self:newTab(Sites.search_url(text)) end },
            },
        },
        tap_close_callback = function() self:clearSelection() end,
    }
    UIManager:show(dialog)
    self:clearSelection()
end

function Browser:clearSelection()
    if self.html and self.html:clearHighlight() then
        self.html:freeBb()
        UIManager:setDirty(self, function() return "ui", self.dimen end)
    end
end

---------------------------------------------------------------------------

function Browser:onClose()
    if self.html then self:entry().page = self.html.page_number end
    self:save()
    UIManager:close(self, "full")
    return true
end

function Browser:onCloseWidget()
    self.closed = true
    self:freeHtml()
end

function Browser:onResume()
    UIManager:setDirty(self, "full")
    -- Wi-Fi goes off during sleep; bring it back while the browser is open
    UIManager:scheduleIn(2, function()
        if not self.closed and not self._net_wait and not NetworkMgr:isWifiOn() then
            Browser.wifiOn(function() end)
        end
    end)
end

return Browser
