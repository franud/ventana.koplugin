--[[ Ventana: tiny HTTP client on top of LuaSocket/LuaSec (as used by KOReader).
Follows redirects, honours KOReader's socket timeouts, never blocks longer than `maxtime`. ]]
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socket_url = require("socket.url")
local socketutil = require("socketutil")
local logger = require("logger")

local ffi = require("ffi")

-- gzip/deflate decoding (KOReader's ffi/zlib only wraps compress/uncompress)
local libz
pcall(ffi.cdef, [[
typedef struct ventana_z_stream {
    const unsigned char *next_in; unsigned int avail_in; unsigned long total_in;
    unsigned char *next_out; unsigned int avail_out; unsigned long total_out;
    const char *msg; void *state;
    void *zalloc; void *zfree; void *opaque;
    int data_type; unsigned long adler; unsigned long reserved;
} ventana_z_stream;
int inflateInit2_(ventana_z_stream *strm, int windowBits, const char *version, int stream_size);
int inflate(ventana_z_stream *strm, int flush);
int inflateEnd(ventana_z_stream *strm);
const char *zlibVersion(void);
]])

local function inflate(data)
    if not libz then
        local ok, lib = pcall(ffi.loadlib, "z", 1)
        if not ok then return nil, "zlib not available" end
        libz = lib
    end
    local strm = ffi.new("ventana_z_stream")
    local inbuf = ffi.new("unsigned char[?]", #data)
    ffi.copy(inbuf, data, #data)
    strm.next_in = inbuf
    strm.avail_in = #data
    -- 15 + 32: auto-detect gzip or zlib header
    if libz.inflateInit2_(strm, 15 + 32, libz.zlibVersion(), ffi.sizeof(strm)) ~= 0 then
        return nil, "inflateInit failed"
    end
    local CHUNK = 256 * 1024
    local out = ffi.new("unsigned char[?]", CHUNK)
    local parts = {}
    local ret
    repeat
        strm.next_out = out
        strm.avail_out = CHUNK
        ret = libz.inflate(strm, 0)
        if ret ~= 0 and ret ~= 1 then break end
        parts[#parts + 1] = ffi.string(out, CHUNK - strm.avail_out)
    until ret == 1 or (strm.avail_in == 0 and strm.avail_out ~= 0)
    libz.inflateEnd(strm)
    if ret ~= 0 and ret ~= 1 then return nil, "inflate error " .. tostring(ret) end
    return table.concat(parts)
end

local Net = {
    -- Identify honestly; most news sites and Wikipedia serve full server-rendered pages to it.
    user_agent = "Mozilla/5.0 (compatible; Ventana/0.1; +KOReader e-reader browser)",
    max_bytes = 6 * 1024 * 1024,
}

local function encode_path(url)
    -- encode spaces and non-ASCII bytes that people type, keep everything else as is
    return (url:gsub("[%s\128-\255]", function(c) return string.format("%%%02X", c:byte()) end))
end

function Net.absolute(base, href)
    if not href or href == "" then return base end
    if href:match("^[%a][%w+.-]*:") then return href end
    return socket_url.absolute(base, href)
end

--- GET url. Returns { ok, code, url (final), content_type, body, err }.
function Net.get(url, opts)
    opts = opts or {}
    local redirects = 0
    url = encode_path(url)
    while true do
        local sink = {}
        local total = 0
        socketutil:set_timeout(opts.timeout or 15, opts.maxtime or 40)
        local base_sink = socketutil.table_sink(sink)
        local limited = function(chunk, err)
            if chunk then
                total = total + #chunk
                if total > Net.max_bytes then return nil, "page too large" end
            end
            return base_sink(chunk, err)
        end
        local code, headers, status = socket.skip(1, http.request{
            url = url,
            method = "GET",
            redirect = false,
            sink = limited,
            headers = {
                ["user-agent"] = Net.user_agent,
                ["accept"] = opts.accept or "text/html,application/xhtml+xml,image/*;q=0.8,*/*;q=0.5",
                ["accept-language"] = opts.lang or "en,es;q=0.8",
                ["accept-encoding"] = "gzip, deflate",
            },
        })
        socketutil:reset_timeout()
        if headers == nil then
            logger.warn("Ventana: request failed", url, code, status)
            return { ok = false, url = url, err = tostring(status or code or "network unreachable") }
        end
        if type(code) == "number" and code >= 300 and code < 400 and headers.location then
            redirects = redirects + 1
            if redirects > 8 then return { ok = false, url = url, err = "too many redirects" } end
            url = encode_path(Net.absolute(url, headers.location))
        else
            local body = table.concat(sink)
            local enc = (headers["content-encoding"] or ""):lower()
            if enc == "gzip" or enc == "deflate" or enc == "x-gzip" then
                local plain, ierr = inflate(body)
                if plain then body = plain else logger.warn("Ventana: could not inflate", url, ierr) end
            end
            local ok = type(code) == "number" and code < 400
            return {
                ok = ok,
                code = code,
                url = url,
                content_type = (headers["content-type"] or ""):lower(),
                body = body,
                err = not ok and tostring(status or code) or nil,
            }
        end
    end
end

return Net
