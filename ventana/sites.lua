--[[ Ventana: per-site knowledge, address-bar parsing and the start page. ]]
local util = require("util")

local Sites = {}

Sites.START = "ventana:start"

local function urlencode(s)
    return (s:gsub("[^%w%-_.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

local function urldecode(s)
    return (s:gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end
Sites.urldecode = urldecode

--- What the user typed in the address bar -> URL.
function Sites.resolve_input(text)
    text = util.trim(text or "")
    if text == "" then return nil end
    if text:match("^[%a][%w+.-]*://") or text == Sites.START then return text end
    local cmd, rest = text:match("^(%a+)%s+(.+)$")
    if cmd then
        cmd = cmd:lower()
        local lang = ({ w = "en", wiki = "en", wp = "en", en = "en", es = "es", wes = "es", fr = "fr", de = "de", it = "it", pt = "pt" })[cmd]
        if lang then
            return string.format("https://%s.wikipedia.org/w/index.php?search=%s&go=Go", lang, urlencode(rest))
        end
    end
    -- looks like a host name (no spaces, has a dot, sane tld)?
    if not text:find("%s") and text:match("^[%w.-]+%.%a%a+[/:?#]?") then
        return "https://" .. text
    end
    return Sites.search_url(text)
end

function Sites.search_url(q)
    return "https://lite.duckduckgo.com/lite/?q=" .. urlencode(q)
end

local function wiki_parts(url)
    local lang, mobile, rest = url:match("^https?://(%a[%w-]*)%.(m?%.?)wikipedia%.org/wiki/(.+)$")
    if lang then
        local title, frag = rest:match("^([^#]*)(#?.*)$")
        title = title:gsub("%?.*$", "")
        return lang, title, frag
    end
end

--- Canonical URL shown and stored for a page (e.g. mobile Wikipedia -> desktop).
function Sites.canonical(url)
    local lang, title, frag = wiki_parts(url)
    if lang then return string.format("https://%s.wikipedia.org/wiki/%s%s", lang, title, frag) end
    return url
end

--- The URL actually fetched for a page (lighter variants of heavy sites).
function Sites.fetch_url(url)
    local lang, title = wiki_parts(url)
    if lang and not title:match("^Special:") then
        -- action=render: just the article body, no skin/chrome (a fraction of the size)
        return string.format("https://%s.wikipedia.org/w/index.php?title=%s&action=render", lang, title), {
            title = urldecode(title):gsub("_", " "),
            wikipedia = true,
        }
    end
    return url, {}
end

--- Cleaning rules for a URL.
function Sites.rules(url)
    if url:match("wikipedia%.org/") then
        return {
            drop = { "mw%-editsection", "navbox", "vertical%-navbox", "sistersitebox", "mw%-empty%-elt", "noprint", "metadata", "mw%-authority%-control", "portalbox", "side%-box" },
            max_images = 14,
        }
    end
    if url:match("duckduckgo%.com/") then
        return { drop = { "%f[%w]header", "%f[%w]extra", "result%-sponsored" }, max_images = 0 }
    end
    if url:match("news%.ycombinator%.com") then
        return { max_images = 0 }
    end
    return {}
end

--- A nice title for pages that don't have one.
function Sites.title_for(url)
    local q = url:match("duckduckgo%.com/lite/%?q=([^&]+)")
    if q then return "Search: " .. urldecode(q) end
end

--- Link rewriting (search result redirects -> target).
function Sites.rewrite_link(href)
    local target = href:match("^https?://duckduckgo%.com/l/%?.*uddg=([^&]+)")
    if target then return urldecode(target) end
    -- in-app wikipedia links stay on the light renderer
    return href
end

---------------------------------------------------------------------------
-- start page

Sites.SPEED_DIAL = {
    { "Wikipedia", "https://en.wikipedia.org/wiki/Main_Page" },
    { "Wikipedia ES", "https://es.wikipedia.org/wiki/Wikipedia:Portada" },
    { "Random article", "https://en.wikipedia.org/wiki/Special:Random" },
    { "Hacker News", "https://news.ycombinator.com/" },
    { "BBC News", "https://www.bbc.com/news" },
    { "NPR (text)", "https://text.npr.org/" },
    { "CNN Lite", "https://lite.cnn.com/" },
    { "El País", "https://elpais.com/" },
    { "elDiario.es", "https://www.eldiario.es/" },
    { "20minutos", "https://www.20minutos.es/" },
}

local function esc(s)
    return (tostring(s):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

function Sites.start_page(bookmarks, history)
    local b = {}
    local function add(x) b[#b + 1] = x end
    add('<div class="v-hello">')
    add("<h1>" .. esc(os.date("%A, %d %B")) .. "</h1>")
    add('<p class="v-hint">Tap the address bar to type a web address or search words. ')
    add("Start with <b>w</b> for English Wikipedia or <b>es</b> for Spanish Wikipedia, e.g. <i>w Byzantium</i>.</p></div>")
    add('<h2>Speed dial</h2><table class="v-dial">')
    local dial = Sites.SPEED_DIAL
    for i = 1, #dial, 2 do
        add("<tr>")
        for j = i, math.min(i + 1, #dial) do
            local host = dial[j][2]:match("^https?://([^/]+)") or ""
            add(string.format('<td><a href="%s"><b>%s</b></a><br/><small>%s</small></td>', esc(dial[j][2]), esc(dial[j][1]), esc(host:gsub("^www%.", ""))))
        end
        add("</tr>")
    end
    add("</table>")
    if bookmarks and #bookmarks > 0 then
        add("<h2>Bookmarks</h2><ul class=\"v-list\">")
        for _, e in ipairs(bookmarks) do
            add(string.format('<li><a href="%s">%s</a></li>', esc(e.url), esc(e.title or e.url)))
        end
        add("</ul>")
    end
    if history and #history > 0 then
        add("<h2>Recently visited</h2><ul class=\"v-list\">")
        for i = 1, math.min(#history, 12) do
            local e = history[i]
            local host = (e.url:match("^https?://([^/]+)") or ""):gsub("^www%.", "")
            add(string.format('<li><a href="%s">%s</a> <small>· %s</small></li>', esc(e.url), esc(e.title or e.url), esc(host)))
        end
        add("</ul>")
    end
    return table.concat(b), "Start"
end

--- Does this response look like a bot wall / JS-only shell rather than a page?
function Sites.looks_blocked(code, body)
    if code == 403 or code == 429 or code == 503 then return true end
    if #body < 6000 then
        local l = body:lower()
        if l:find("captcha") or l:find("just a moment") or l:find("challenge") or l:find("enable javascript")
            or l:find("verify you are human") then return true end
    end
    return false
end

function Sites.blocked_page(url)
    return string.format([[<h1>This site doesn't let simple browsers in</h1>
<p><small>%s</small></p>
<p>It only works in a full browser with JavaScript, or it checks for bots. Try the same story on another site, or search for it: many news sites have a light or text-only edition.</p>]], esc(url)), "Blocked"
end

function Sites.error_page(url, err)
    return string.format([[<h1>Couldn't open this page</h1>
<p><small>%s</small></p><p>%s</p>
<p>Check that Wi-Fi is on, then tap ⟳ to try again.</p>]], esc(url), esc(err or "")), "Error"
end

return Sites
