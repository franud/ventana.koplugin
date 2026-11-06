--[[ Ventana: url -> cleaned page on disk (body.html + images), with a small page cache.

Loader.load(url, opts, progress) -> page
  opts: { reader = bool, images = bool, refresh = bool }
  page: { url, title, body, dir, from_cache, err, download = {path, name} }
]]
local DataStorage = require("datastorage")
local Html = require("ventana/html")
local Net = require("ventana/net")
local Sites = require("ventana/sites")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5 = require("ffi/sha2").md5
local util = require("util")

local Loader = {
    root = DataStorage:getDataDir() .. "/cache/ventana",
    keep_pages = 80,
    image_budget_s = 25,
}

local function read_file(path)
    local f = io.open(path, "rb"); if not f then return nil end
    local s = f:read("*a"); f:close(); return s
end

local function write_file(path, data)
    local f = io.open(path, "wb"); if not f then return false end
    f:write(data); f:close(); return true
end

local function rmtree(path)
    if lfs.attributes(path, "mode") ~= "directory" then os.remove(path); return end
    for e in lfs.dir(path) do
        if e ~= "." and e ~= ".." then rmtree(path .. "/" .. e) end
    end
    lfs.rmdir(path)
end

function Loader.key(url, opts)
    return md5(url .. (opts.reader and "|r" or "") .. (opts.images and "|i" or ""))
end

function Loader.isCached(url, opts)
    url = Sites.canonical(url)
    return lfs.attributes(Loader.root .. "/" .. Loader.key(url, opts) .. "/body.html", "mode") == "file"
end

local function serialize_meta(t)
    return string.format("return { url = %q, title = %q, time = %d }", t.url or "", t.title or "", t.time or os.time())
end

--- keep the cache small: drop the oldest page dirs
function Loader.prune()
    local dirs = {}
    if lfs.attributes(Loader.root, "mode") ~= "directory" then return end
    for e in lfs.dir(Loader.root) do
        if #e == 32 then
            local p = Loader.root .. "/" .. e
            dirs[#dirs + 1] = { p = p, t = lfs.attributes(p, "modification") or 0 }
        end
    end
    if #dirs <= Loader.keep_pages then return end
    table.sort(dirs, function(a, b) return a.t > b.t end)
    for i = Loader.keep_pages + 1, #dirs do rmtree(dirs[i].p) end
end

function Loader.clear()
    for e in lfs.dir(Loader.root) do
        if #e == 32 then rmtree(Loader.root .. "/" .. e) end
    end
end

--- Copy the page font into the resource dir once (MuPDF only loads @font-face files from there).
local FONTS = { "NotoSerif-Regular.ttf", "NotoSerif-Bold.ttf", "NotoSerif-Italic.ttf", "NotoSerif-BoldItalic.ttf" }
function Loader.ensureFonts()
    if Loader._fonts_ok ~= nil then return Loader._fonts_ok end
    local dst = Loader.root .. "/fonts"
    util.makePath(dst)
    local ok = true
    for _, f in ipairs(FONTS) do
        local target = dst .. "/" .. f
        if lfs.attributes(target, "mode") ~= "file" then
            local data = read_file("fonts/noto/" .. f)
            if not data or not write_file(target, data) then ok = false end
        end
    end
    Loader._fonts_ok = ok
    return ok
end

local function is_webp(data)
    return data:sub(1, 4) == "RIFF" and data:sub(9, 12) == "WEBP"
end
local function is_known_image(data)
    local h = data:sub(1, 8)
    return h:sub(1, 3) == "\255\216\255" or h == "\137PNG\r\n\26\n" or h:sub(1, 4) == "GIF8" or h:sub(1, 2) == "BM"
end

--- width, height of a PNG/GIF/JPEG from its header (nil if unknown)
local function image_size(d)
    local b = function(i) return d:byte(i) or 0 end
    if d:sub(1, 8) == "\137PNG\r\n\26\n" then
        return b(17) * 16777216 + b(18) * 65536 + b(19) * 256 + b(20), b(21) * 16777216 + b(22) * 65536 + b(23) * 256 + b(24)
    elseif d:sub(1, 4) == "GIF8" then
        return b(7) + b(8) * 256, b(9) + b(10) * 256
    elseif d:sub(1, 2) == "\255\216" then
        local i = 3
        while i < #d - 9 do
            if b(i) ~= 0xFF then return nil end
            local m = b(i + 1)
            local len = b(i + 2) * 256 + b(i + 3)
            if m >= 0xC0 and m <= 0xCF and m ~= 0xC4 and m ~= 0xC8 and m ~= 0xCC then
                return b(i + 7) * 256 + b(i + 8), b(i + 5) * 256 + b(i + 6)
            end
            i = i + 2 + len
        end
    end
end

--- Re-encode an image MuPDF can't read (webp) or one that is needlessly huge, as a grayscale PNG.
local function convert_image(data, path, max_w)
    local ok, RenderImage = pcall(require, "ui/renderimage")
    if not ok then return false end
    local ok2, bb = pcall(RenderImage.renderImageData, RenderImage, data, #data, false)
    if not ok2 or not bb then return false end
    local w, h = bb:getWidth(), bb:getHeight()
    if w > max_w then
        local nh = math.floor(h * max_w / w)
        bb = RenderImage:scaleBlitBuffer(bb, max_w, nh, true)
    end
    local Blitbuffer = require("ffi/blitbuffer")
    local gray = Blitbuffer.new(bb:getWidth(), bb:getHeight(), Blitbuffer.TYPE_BB8)
    gray:blitFrom(bb)
    local okw = pcall(gray.writePNG, gray, path)
    local gw, gh = gray:getWidth(), gray:getHeight()
    gray:free(); bb:free()
    return okw, gw, gh
end

--- Download page images; returns the set of files that are real, visible pictures.
local function download_images(images, dir, progress, max_w)
    local t0 = os.time()
    local good = {}
    for i, im in ipairs(images) do
        if os.time() - t0 > Loader.image_budget_s then
            logger.info("Ventana: image budget exhausted at", i)
            break
        end
        if progress then progress(string.format("Images %d / %d", i, #images)) end
        local r = Net.get(im.url, { accept = "image/jpeg,image/png,image/gif,image/webp,image/*;q=0.8", timeout = 8, maxtime = 15 })
        if r.ok and r.body and #r.body > 0 then
            local path = dir .. "/" .. im.file
            local w, h
            if is_webp(r.body) or (#r.body > 400 * 1024) or not is_known_image(r.body) then
                local ok
                ok, w, h = convert_image(r.body, path, max_w)
                if not ok and is_known_image(r.body) then
                    write_file(path, r.body)
                    w, h = image_size(r.body)
                end
            else
                write_file(path, r.body)
                w, h = image_size(r.body)
            end
            -- placeholders, spacers and icons are not worth a line on e-ink
            -- (a flat grey placeholder compresses to almost nothing)
            local flat = w and h and (#r.body < 2000) and (w * h > 8000)
            if w and h and w >= 48 and h >= 32 and not flat then good[im.file] = true
            elseif not w and lfs.attributes(path, "mode") == "file" then good[im.file] = true end
        end
    end
    return good
end

local DOC_EXT = { epub = true, pdf = true, djvu = true, cbz = true, fb2 = true, mobi = true, azw3 = true }

--[[ Load a page. `progress(text)` is called with status updates (may be nil).
     `env` gives the start page its data: { bookmarks = {...}, history = {...}, max_img_w = px } ]]
function Loader.load(url, opts, progress, env)
    opts = opts or {}
    env = env or {}
    if url == Sites.START then
        local body, title = Sites.start_page(env.bookmarks, env.history)
        return { url = url, title = title, body = body, dir = nil, internal = true }
    end
    url = Sites.canonical(url)
    local key = Loader.key(url, opts)
    local dir = Loader.root .. "/" .. key
    if not opts.refresh then
        local body = read_file(dir .. "/body.html")
        if body then
            local okm, meta = pcall(dofile, dir .. "/meta.lua")
            lfs.touch(dir)
            return { url = url, title = okm and meta and meta.title or url, body = body, dir = dir, from_cache = true }
        end
    end

    if progress then progress("Connecting…") end
    local fetch_url, hints = Sites.fetch_url(url)
    local r = Net.get(fetch_url)
    if (r.code and r.body and Sites.looks_blocked(r.code, r.body)) then
        local body, title = Sites.blocked_page(url)
        return { url = url, title = title, body = body, err = "blocked" }
    end
    if not r.ok then
        local body, title = Sites.error_page(url, r.err)
        return { url = url, title = title, body = body, err = r.err }
    end
    -- follow redirects for the canonical url (e.g. Special:Random, search "go")
    if fetch_url == url and r.url ~= url then
        url = Sites.canonical(r.url)
        local light, light_hints = Sites.fetch_url(url)
        if light ~= url then
            -- landed on a site we have a lighter rendering for (e.g. a Wikipedia article)
            local r2 = Net.get(light)
            if r2.ok then r, hints = r2, light_hints end
        end
        key = Loader.key(url, opts)
        dir = Loader.root .. "/" .. key
    end
    local ct = r.content_type or ""
    local ext = (url:lower():gsub("[?#].*", "")):match("%.(%w+)$")

    if ct:find("application/pdf") or ct:find("epub") or (ext and DOC_EXT[ext] and not ct:find("html")) then
        -- a document: hand it over to the reader
        local name = util.getSafeFilename(url:match("([^/?#]+)[?#]?[^/]*$") or "download")
        if not name:find("%.") then name = name .. (ct:find("pdf") and ".pdf" or ".epub") end
        local ddir = (G_reader_settings:readSetting("home_dir") or DataStorage:getDataDir()) .. "/Downloads"
        util.makePath(ddir)
        local path = ddir .. "/" .. name
        write_file(path, r.body)
        return { url = url, title = name, download = { path = path, name = name },
            body = string.format("<h1>Downloaded</h1><p>%s</p><p>Saved to %s</p>", name, ddir) }
    end

    util.makePath(dir)
    local body, title
    if ct:find("^image/") then
        write_file(dir .. "/i01.img", r.body)
        body = '<img src="' .. key .. '/i01.img"/>'
        title = url:match("([^/]+)$")
    elseif ct:find("^text/plain") then
        body = "<pre>" .. r.body:gsub("&", "&amp;"):gsub("<", "&lt;") .. "</pre>"
        title = url:match("([^/]+)$")
    else
        if progress then progress("Tidying up the page…") end
        local html = Html.to_utf8(r.body, ct)
        local tree = Html.parse(html)
        local rules = Sites.rules(url)
        local info
        body, info = Html.clean(tree, {
            base_url = r.url,
            reader = opts.reader,
            site = rules,
            images = opts.images and (rules.max_images ~= 0),
            max_images = rules.max_images or 24,
            rewrite_link = Sites.rewrite_link,
            img_prefix = key .. "/",
        })
        title = hints.title or Sites.title_for(url) or info.og_title or info.title or url
        if opts.reader then
            -- reader mode: headline on top, unless the article already starts with it
            local first_h1 = body:match("^%s*<div[^>]*>%s*<h1") or body:sub(1, 600):find("<h1")
            if not first_h1 then
                body = "<h1>" .. title:gsub("&", "&amp;"):gsub("<", "&lt;") .. "</h1>" .. body
            end
            if info.site_name then
                body = '<p class="v-site">' .. info.site_name:gsub("<", "&lt;") .. "</p>" .. body
            end
        elseif hints.wikipedia then
            body = "<h1>" .. title:gsub("&", "&amp;"):gsub("<", "&lt;") .. "</h1>" .. body
        end
        if #info.images > 0 then
            local good = download_images(info.images, dir, progress, env.max_img_w or 900)
            body = body:gsub('<img src="' .. key .. '/([%w.]+)"[^>]*/>', function(f)
                if not good[f] then return "" end
            end)
        end
    end
    write_file(dir .. "/body.html", body)
    write_file(dir .. "/meta.lua", serialize_meta{ url = url, title = title })
    Loader.prune()
    return { url = url, title = title, body = body, dir = dir }
end

return Loader
