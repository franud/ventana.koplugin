--[[ Ventana: forgiving HTML parser + cleaner.

parse(html)            -> tree  (nodes: { tag=, attrs={}, kids={} }, text nodes are strings)
clean(tree, opts)      -> body_html, info { title, images = { {url=, file=}... }, links = n }

The cleaner keeps the readable structure of a page (headings, paragraphs, lists, tables,
images, links) and drops what can't work without a browser engine (scripts, forms, iframes,
hidden elements, cookie banners). In reader mode it also picks the article out of the page
(readability-style scoring) and drops boilerplate around it.
]]
local Html = {}

local VOID = {}
for t in ("area base br col embed hr img input link meta source track wbr param keygen command"):gmatch("%S+") do VOID[t] = true end
local RAW = { script = true, style = true, textarea = true, title = true, noscript = true, template = true, xmp = true, iframe = true }
-- tags that implicitly close an open <p>
local CLOSES_P = {}
for t in ("address article aside blockquote details div dl fieldset figcaption figure footer form h1 h2 h3 h4 h5 h6 header hr main menu nav ol p pre section table ul"):gmatch("%S+") do CLOSES_P[t] = true end

local function parse_attrs(s)
    local attrs = {}
    local i, n = 1, #s
    while i <= n do
        local a, b = s:find("^[%s/]+", i)
        if a then i = b + 1 end
        if i > n then break end
        local name_s, name_e = s:find("^[^%s=/>]+", i)
        if not name_s then i = i + 1 else
            local name = s:sub(name_s, name_e):lower()
            i = name_e + 1
            local eq = s:find("^%s*=%s*", i)
            local value = ""
            if eq then
                local _, eq_e = s:find("^%s*=%s*", i)
                i = eq_e + 1
                local q = s:sub(i, i)
                if q == '"' or q == "'" then
                    local close = s:find(q, i + 1, true) or (n + 1)
                    value = s:sub(i + 1, close - 1)
                    i = close + 1
                else
                    local v_s, v_e = s:find("^[^%s>]+", i)
                    if v_s then value = s:sub(v_s, v_e); i = v_e + 1 end
                end
            end
            if attrs[name] == nil then attrs[name] = value end
        end
    end
    return attrs
end

-- find the end of a start tag, honouring quoted attribute values
local function tag_end(s, i)
    local q
    while true do
        local c = s:find(q and q or "[>\"']", i)
        if not c then return #s end
        if q then q = nil; i = c + 1
        else
            local ch = s:sub(c, c)
            if ch == ">" then return c end
            -- quotes only matter after an '=' (avoid being fooled by stray apostrophes)
            if s:sub(math.max(1, c - 16), c - 1):match("=%s*$") then q = ch end
            i = c + 1
        end
    end
end

function Html.parse(s)
    local ls = s:lower()
    local root = { tag = "#root", attrs = {}, kids = {} }
    local stack = { root }
    local function top() return stack[#stack] end
    local function close_to(tag, boundary)
        -- pop up to and including `tag`, unless a boundary tag is hit first
        for k = #stack, 2, -1 do
            local t = stack[k].tag
            if t == tag then
                for _ = #stack, k, -1 do stack[#stack] = nil end
                return true
            end
            if boundary and boundary[t] then return false end
        end
        return false
    end
    local LI_B = { ul = true, ol = true, menu = true, table = true }
    local DD_B = { dl = true, table = true }
    local TR_B = { table = true, tbody = true, thead = true, tfoot = true }
    local TD_B = { tr = true, table = true }
    local P_B = { button = true, table = true, td = true, th = true, li = true, blockquote = true, div = true }

    local i, n = 1, #s
    while i <= n do
        local lt = s:find("<", i, true)
        if not lt then
            table.insert(top().kids, s:sub(i))
            break
        end
        if lt > i then table.insert(top().kids, s:sub(i, lt - 1)) end
        local nxt = s:sub(lt + 1, lt + 1)
        if s:sub(lt, lt + 3) == "<!--" then
            local e = s:find("-->", lt + 4, true)
            i = e and e + 3 or n + 1
        elseif nxt == "!" or nxt == "?" then
            local e = s:find(">", lt, true)
            i = e and e + 1 or n + 1
        elseif nxt == "/" then
            local e = s:find(">", lt, true) or n
            local tag = ls:match("^</%s*([%w:-]+)", lt)
            if tag then
                if tag == "p" and not close_to("p", P_B) then
                    table.insert(top().kids, { tag = "p", attrs = {}, kids = {} })
                elseif tag ~= "br" then
                    close_to(tag)
                end
            end
            i = e + 1
        elseif nxt:match("%a") then
            local e = tag_end(s, lt + 1)
            local tag, rest_s = ls:match("^<([%w:-]+)()", lt)
            local inner = s:sub(rest_s, e - 1)
            local self_closing = inner:match("/%s*$") ~= nil
            local node = { tag = tag, attrs = parse_attrs(inner), kids = {} }
            -- implied end tags
            if CLOSES_P[tag] then close_to("p", P_B) end
            if tag == "li" then close_to("li", LI_B)
            elseif tag == "dt" or tag == "dd" then
                if not close_to("dd", DD_B) then close_to("dt", DD_B) end
            elseif tag == "tr" then close_to("tr", TR_B)
            elseif tag == "td" or tag == "th" then
                if not close_to("td", TD_B) then close_to("th", TD_B) end
            elseif tag == "option" then close_to("option", { select = true })
            elseif tag == "tbody" or tag == "thead" or tag == "tfoot" then
                if not close_to("tbody", { table = true }) then
                    if not close_to("thead", { table = true }) then close_to("tfoot", { table = true }) end
                end
            end
            table.insert(top().kids, node)
            i = e + 1
            if RAW[tag] and not self_closing then
                local c = ls:find("</" .. tag, i, true)
                local raw_end = c or (n + 1)
                node.kids[1] = s:sub(i, raw_end - 1)
                if c then
                    local ce = s:find(">", c, true)
                    i = ce and ce + 1 or n + 1
                else
                    i = n + 1
                end
            elseif not VOID[tag] and not self_closing then
                table.insert(stack, node)
            end
        else
            table.insert(top().kids, "<")
            i = lt + 1
        end
    end
    return root
end

---------------------------------------------------------------------------
-- helpers

local ENT = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\194\160",
    mdash = "—", ndash = "–", hellip = "…", laquo = "«", raquo = "»", rsquo = "’", lsquo = "‘",
    rdquo = "”", ldquo = "“", middot = "·", copy = "©", reg = "®", bull = "•", deg = "°", times = "×" }

local function utf8char(cp)
    if cp < 0x80 then return string.char(cp)
    elseif cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    elseif cp < 0x110000 then
        return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
    return ""
end

function Html.decode(s)
    return (s:gsub("&(#?[%w]+);?", function(e)
        if e:sub(1, 2) == "#x" or e:sub(1, 2) == "#X" then
            local cp = tonumber(e:sub(3), 16); return cp and utf8char(cp)
        elseif e:sub(1, 1) == "#" then
            local cp = tonumber(e:sub(2)); return cp and utf8char(cp)
        end
        return ENT[e]
    end))
end

local function esc_attr(s)
    return (s:gsub("&", "&amp;"):gsub('"', "&quot;"):gsub("<", "&lt;"))
end

local function text_of(node, buf)
    buf = buf or {}
    if type(node) == "string" then buf[#buf + 1] = node; return buf end
    if (RAW[node.tag] and node.tag ~= "title") or node.tag == "svg" then return buf end
    for _, k in ipairs(node.kids) do text_of(k, buf) end
    return buf
end

function Html.text(node)
    local t = table.concat(text_of(node))
    return Html.decode(t):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
end

local function find_all(node, pred, out)
    out = out or {}
    if type(node) ~= "table" then return out end
    if pred(node) then out[#out + 1] = node end
    for _, k in ipairs(node.kids) do find_all(k, pred, out) end
    return out
end
Html.find_all = find_all

function Html.find(node, tag)
    return find_all(node, function(x) return x.tag == tag end)[1]
end

---------------------------------------------------------------------------
-- cleaning

local DROP = {}
for t in ("script style noscript template svg math canvas video audio iframe object embed applet frame frameset head link meta select textarea input button dialog map area datalist option optgroup source track"):gmatch("%S+") do DROP[t] = true end

local KEEP = {}
for t in ("p h1 h2 h3 h4 h5 h6 a b strong i em u s del ins sub sup small big blockquote q cite pre code kbd samp var tt ul ol li dl dt dd table caption thead tbody tfoot tr td th img figure figcaption br hr center"):gmatch("%S+") do KEEP[t] = true end
local BLOCKISH = {}
for t in ("div section article main header footer nav aside address details summary fieldset legend hgroup form body html"):gmatch("%S+") do BLOCKISH[t] = true end

-- always hidden: banners nobody wants on an e-reader
local JUNK_ALWAYS = { "cookie", "consent", "gdpr", "paywall", "skip%-link", "skiplink", "skip%-to", "visually%-hidden", "visuallyhidden", "sr%-only", "screen%-reader", "a11y%-hidden", "mw%-editsection", "noprint", "mw%-jump", "printfooter", "catlinks" }
-- reader mode only: everything around the article
local JUNK_READER = { "share", "social", "related", "recommend", "promo", "advert", "%f[%w]ad%f[%W]", "%f[%w]ads%f[%W]", "sponsor", "newsletter", "subscribe", "signup", "sign%-up", "comment", "sidebar", "widget", "breadcrumb", "byline%-share", "toolbar", "%f[%w]nav", "menu", "masthead", "footer", "outbrain", "taboola", "most%-read", "trending", "popular", "tags", "author%-bio", "navbox", "sistersitebox", "metadata", "mbox", "ambox", "hatnote", "reflist", "references", "reference", "mw%-references", "infobox" }
local function matches_any(s, list)
    for _, p in ipairs(list) do if s:find(p) then return true end end
    return false
end

local function is_hidden(node)
    local a = node.attrs
    if a.hidden or a["aria-hidden"] == "true" then return true end
    local style = a.style
    if style and style:lower():gsub("%s", ""):find("display:none") then return true end
    if style and style:lower():gsub("%s", ""):find("visibility:hidden") then return true end
    return false
end

local function classid(node)
    local a = node.attrs
    return ((a.class or "") .. " " .. (a.id or "") .. " " .. (a.role or "")):lower()
end

local function pick_srcset(srcset, want)
    local best, best_w
    for item in srcset:gmatch("[^,]+") do
        local url, desc = item:match("^%s*(%S+)%s*(%S*)")
        if url then
            local w = tonumber(desc:match("^(%d+)w")) or (tonumber(desc:match("^([%d.]+)x")) or 1) * 400
            -- prefer the smallest candidate that is >= want, else the largest one
            if not best or (best_w < want and w > best_w) or (w >= want and w < best_w) then
                best, best_w = url, w
            end
        end
    end
    return best
end

local function link_density(node)
    local total = #Html.text(node)
    if total == 0 then return 1, 0 end
    local linked = 0
    for _, a in ipairs(find_all(node, function(x) return x.tag == "a" end)) do
        linked = linked + #Html.text(a)
    end
    return linked / total, total
end

--- readability-lite: find the node that holds the article.
-- Every element gets P = amount of paragraph text inside it (boilerplate subtrees count 0).
-- Starting at <body>, descend into the child holding most of the text while that child
-- still holds >= 70% of it. The result is the smallest box that contains the article.
local function find_article(root, body)
    local P = {}
    local function score(node)
        if type(node) ~= "table" then return 0 end
        local tag = node.tag
        if DROP[tag] or tag == "nav" or tag == "aside" or tag == "footer" or tag == "form" then P[node] = 0; return 0 end
        local cid = classid(node)
        if cid ~= "  " and matches_any(cid, { "comment", "sidebar", "related", "footer", "recommend", "newsletter", "promo", "most%-read", "trending" }) then
            P[node] = 0; return 0
        end
        local total = 0
        if tag == "p" or tag == "pre" or tag == "blockquote" then
            local len = #Html.text(node)
            if len >= 20 then total = len end
        else
            for _, k in ipairs(node.kids) do
                if type(k) == "string" then
                    -- bare text directly in a container (sloppy markup) counts too
                    local len = #(k:gsub("%s+", ""))
                    if len >= 80 then total = total + len end
                else
                    total = total + score(k)
                end
            end
        end
        P[node] = total
        return total
    end
    local node = body or root
    score(node)
    if (P[node] or 0) < 200 then return nil end
    -- an <article> or <main> holding most of the text is the best boundary there is
    local best_art
    for _, a in ipairs(find_all(node, function(x) return x.tag == "article" or x.tag == "main" or x.attrs.role == "main" end)) do
        if (P[a] or 0) >= 0.6 * P[node] and (not best_art or P[a] < P[best_art]) then best_art = a end
    end
    if best_art then node = best_art end
    while true do
        local top, top_p = nil, 0
        for _, k in ipairs(node.kids) do
            if type(k) == "table" and (P[k] or 0) > top_p then top, top_p = k, P[k] end
        end
        if top and top_p >= 0.7 * P[node] and top.tag ~= "p" then node = top else break end
    end
    return node
end

--- Tables used for page layout (not data) must become plain blocks:
-- MuPDF cannot split a table row across pages, so a page-sized row would be cut off.
local function is_layout_table(node)
    if node.attrs.role == "presentation" or node.attrs.role == "none" then return true end
    local nested = find_all(node, function(x) return x ~= node and x.tag == "table" end)
    if #nested > 0 then return true end
    local max_cols, rows = 0, 0
    for _, tr in ipairs(find_all(node, function(x) return x.tag == "tr" end)) do
        rows = rows + 1
        local cols = 0
        for _, c in ipairs(tr.kids) do
            if type(c) == "table" and (c.tag == "td" or c.tag == "th") then cols = cols + 1 end
        end
        if cols > max_cols then max_cols = cols end
    end
    if max_cols <= 1 then return true end
    -- a row holding a lot of text (more than fits a page) can't be laid out as a row
    if #Html.text(node) / math.max(1, rows) > 2500 then return true end
    return false
end

local FLAT = { tbody = true, thead = true, tfoot = true, tr = true, td = true, th = true, caption = true }

--[[ opts:
    base_url   string   for resolving links
    reader     bool     article-only mode
    site       table    per-site rules: { drop = {classes...}, keep_images = bool }
    images     bool     collect images (to be downloaded by the caller)
    max_images number
]]
function Html.clean(root, opts)
    opts = opts or {}
    local Net = require("ventana/net")
    local base = opts.base_url or ""
    local info = { images = {}, links = 0 }

    -- base href
    local base_el = Html.find(root, "base")
    if base_el and base_el.attrs.href and base_el.attrs.href ~= "" then base = Net.absolute(base, base_el.attrs.href) end

    -- title: og:title is usually the clean headline, <title> often has " - Site name"
    local title_el = Html.find(root, "title")
    info.title = title_el and Html.text(title_el) or nil
    for _, m in ipairs(find_all(root, function(x) return x.tag == "meta" end)) do
        local p = (m.attrs.property or m.attrs.name or ""):lower()
        if p == "og:title" and m.attrs.content and m.attrs.content ~= "" then info.og_title = Html.decode(m.attrs.content) end
        if p == "og:site_name" and m.attrs.content then info.site_name = Html.decode(m.attrs.content) end
    end

    local start = root
    if opts.reader then
        local art = find_article(root, Html.find(root, "body"))
        if art then start = art end
    end
    local site_drop = opts.site and opts.site.drop or {}

    local out = {}
    local function emit(x) out[#out + 1] = x end
    local n_images = 0
    local max_images = opts.max_images or 40
    local in_pre = 0

    local seen_img = {}
    local function walk(node, depth, flat)
        if type(node) == "string" then
            emit(node)
            return
        end
        local tag = node.tag
        if DROP[tag] or tag == "title" then return end
        if tag:find(":") then return end -- namespaced junk (fb:like, o:p, ...)
        if is_hidden(node) then return end
        local cid = classid(node)
        if cid ~= "  " then
            if matches_any(cid, JUNK_ALWAYS) then return end
            if #site_drop > 0 and matches_any(cid, site_drop) then return end
            if opts.reader and depth > 0 and matches_any(cid, JUNK_READER) then return end
            if opts.reader and (node.attrs.role == "navigation" or node.attrs.role == "banner" or node.attrs.role == "contentinfo") then return end
        end
        if opts.reader and depth > 0 and (tag == "nav" or tag == "aside" or tag == "footer" or tag == "form") then return end
        if not opts.reader and (tag == "nav" or node.attrs.role == "navigation") then
            -- site menus: one compact row of links instead of pages of bullet lists
            local items, seen = {}, {}
            for _, a in ipairs(find_all(node, function(x) return x.tag == "a" and x.attrs.href end)) do
                local label = Html.text(a)
                local href = Html.decode(a.attrs.href)
                if label ~= "" and #label < 60 and not seen[label] and not href:lower():match("^javascript:") then
                    seen[label] = true
                    if href:sub(1, 1) ~= "#" then
                        href = Net.absolute(base, href)
                        if opts.rewrite_link then href = opts.rewrite_link(href) end
                    end
                    items[#items + 1] = '<a href="' .. esc_attr(href) .. '">' .. label:gsub("&", "&amp;"):gsub("<", "&lt;") .. "</a>"
                    if #items >= 40 then break end
                end
            end
            if #items > 0 then emit('<p class="v-nav">' .. table.concat(items, " · ") .. "</p>") end
            return
        end
        if opts.reader and depth > 0 and (tag == "ul" or tag == "ol" or tag == "div" or tag == "table" or tag == "section" or tag == "header") then
            -- link farms (menus, "more stories") inside the article
            local ld, total = link_density(node)
            if ld > 0.5 and total < 2000 then return end
            if total == 0 and #find_all(node, function(x) return x.tag == "img" end) == 0 then return end
        end

        local id = node.attrs.id or node.attrs.name
        local id_attr = (id and id ~= "" and id:match("^[%w_.:-]+$")) and (' id="' .. esc_attr(id) .. '"') or ""

        if tag == "img" then
            if not opts.images or n_images >= max_images then return end
            local a = node.attrs
            local w, h = tonumber(a.width), tonumber(a.height)
            if (w and w < 40) or (h and h < 40) then return end -- icons, spacers, trackers
            local src = a["data-src"] or a["data-lazy-src"] or a["data-original"]
            local srcset = a["data-srcset"] or a.srcset
            if srcset and srcset ~= "" then src = pick_srcset(srcset, 800) or src end
            src = src or a.src
            if not src or src == "" or src:match("^data:") then return end
            src = Net.absolute(base, Html.decode(src))
            local lsrc = src:lower():gsub("[?#].*", "")
            if lsrc:match("%.svg$") or lsrc:match("%.ico$") then return end
            if seen_img[src] then return end -- lazy-load placeholders repeat the same URL
            seen_img[src] = true
            n_images = n_images + 1
            local ext = lsrc:match("%.(%w+)$") or "img"
            if not ({ jpg = 1, jpeg = 1, png = 1, gif = 1, webp = 1, bmp = 1 })[ext] then ext = "img" end
            local file = string.format("i%02d.%s", n_images, ext)
            table.insert(info.images, { url = src, file = file })
            emit('<img src="' .. (opts.img_prefix or "") .. file .. '"/>')
            return
        end
        if tag == "br" or tag == "hr" then emit("<" .. tag .. "/>"); return end

        local open, close = "", ""
        if tag == "a" then
            local href = node.attrs.href
            if href and href ~= "" and not href:lower():match("^javascript:") then
                href = Html.decode(href)
                if href:sub(1, 1) ~= "#" then
                    href = Net.absolute(base, href)
                    if opts.rewrite_link then href = opts.rewrite_link(href) end
                end
                info.links = info.links + 1
                open = '<a href="' .. esc_attr(href) .. '"' .. id_attr .. ">"
                close = "</a>"
            elseif id_attr ~= "" then
                open = "<a" .. id_attr .. ">"; close = "</a>"
            end
        elseif tag == "table" and is_layout_table(node) then
            open = "<div" .. id_attr .. ">"; close = "</div>"
        elseif flat and FLAT[tag] then
            open = "<div" .. id_attr .. ">"; close = "</div>"
        elseif tag == "li" and Html.text(node):gsub("[%s%-–—·|]", "") == "" and #find_all(node, function(x) return x.tag == "img" end) == 0 then
            return -- empty list items (menu separators)
        elseif KEEP[tag] then
            local extra = ""
            if tag == "td" or tag == "th" then
                local cs, rs = tonumber(node.attrs.colspan), tonumber(node.attrs.rowspan)
                if cs and cs > 1 then extra = extra .. ' colspan="' .. cs .. '"' end
                if rs and rs > 1 then extra = extra .. ' rowspan="' .. rs .. '"' end
            end
            if tag == "center" then tag = "div" end
            open = "<" .. tag .. id_attr .. extra .. ">"
            close = "</" .. tag .. ">"
            if tag == "pre" then in_pre = in_pre + 1 end
        elseif BLOCKISH[tag] then
            open = "<div" .. id_attr .. ">"; close = "</div>"
        elseif tag == "mark" then
            open = "<b>"; close = "</b>"
        elseif id_attr ~= "" then
            open = "<span" .. id_attr .. ">"; close = "</span>"
        end
        emit(open)
        local kid_flat = flat
        if tag == "table" then kid_flat = is_layout_table(node) end
        for _, k in ipairs(node.kids) do walk(k, depth + 1, kid_flat) end
        emit(close)
        if tag == "pre" then in_pre = in_pre - 1 end
    end

    if start == root then
        local body = Html.find(root, "body") or root
        walk(body, 0)
    else
        walk(start, 0)
    end
    return table.concat(out), info
end

---------------------------------------------------------------------------
-- charset: convert legacy single-byte pages to UTF-8

local CP1252 = { [0x80] = 0x20AC, [0x82] = 0x201A, [0x83] = 0x0192, [0x84] = 0x201E, [0x85] = 0x2026, [0x86] = 0x2020,
    [0x87] = 0x2021, [0x88] = 0x02C6, [0x89] = 0x2030, [0x8A] = 0x0160, [0x8B] = 0x2039, [0x8C] = 0x0152, [0x8E] = 0x017D,
    [0x91] = 0x2018, [0x92] = 0x2019, [0x93] = 0x201C, [0x94] = 0x201D, [0x95] = 0x2022, [0x96] = 0x2013, [0x97] = 0x2014,
    [0x98] = 0x02DC, [0x99] = 0x2122, [0x9A] = 0x0161, [0x9B] = 0x203A, [0x9C] = 0x0153, [0x9E] = 0x017E, [0x9F] = 0x0178 }

function Html.to_utf8(body, content_type)
    local cs = (content_type or ""):match("charset=([%w_-]+)")
    if not cs then
        local head = body:sub(1, 4096):lower()
        cs = head:match('<meta[^>]-charset=["\']?([%w_-]+)')
    end
    cs = cs and cs:lower() or "utf-8"
    if cs == "utf-8" or cs == "utf8" or cs == "us-ascii" then return body end
    if cs == "iso-8859-1" or cs == "latin1" or cs == "windows-1252" or cs == "cp1252" or cs == "iso-8859-15" then
        return (body:gsub("[\128-\255]", function(c)
            local b = c:byte()
            return utf8char(CP1252[b] or b)
        end))
    end
    return body
end

return Html
