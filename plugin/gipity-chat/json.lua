-- Minimal JSON encoder/decoder.
--
-- The game's Lua has no JSON library (and no utf8 library), and the Claude API
-- speaks JSON, so this covers what we need: encoding a request (tables, strings,
-- numbers, booleans) and decoding a response.
--
-- Arrays are Lua tables with keys 1..n; set json.EMPTY_ARRAY to force "[]".

local json = {}

json.EMPTY_ARRAY = setmetatable({}, { __tostring = function() return "[]" end })
json.null = setmetatable({}, { __tostring = function() return "null" end })

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------

local ESCAPES = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

-- Length of a valid UTF-8 sequence starting at byte i, or nil if invalid.
local function utf8SeqLen(s, i)
    local c = string.byte(s, i)
    local n
    if c < 0x80 then return 1
    elseif c >= 0xC2 and c <= 0xDF then n = 2
    elseif c >= 0xE0 and c <= 0xEF then n = 3
    elseif c >= 0xF0 and c <= 0xF4 then n = 4
    else return nil end
    for k = 1, n - 1 do
        local b = string.byte(s, i + k)
        if not b or b < 0x80 or b > 0xBF then return nil end
    end
    return n
end

-- Encodes a string. Valid UTF-8 passes through; any other byte (the game may hand us
-- Latin-1/Windows-1252 text) is treated as a Latin-1 character so the JSON stays valid.
local function encodeString(s)
    local out, i = { '"' }, 1
    while i <= #s do
        local c = string.byte(s, i)
        local ch = string.sub(s, i, i)
        if ESCAPES[ch] then
            out[#out + 1] = ESCAPES[ch]
            i = i + 1
        elseif c < 0x20 or c == 0x7F then
            out[#out + 1] = string.format("\\u%04x", c)
            i = i + 1
        elseif c < 0x80 then
            out[#out + 1] = ch
            i = i + 1
        else
            local n = utf8SeqLen(s, i)
            if n then
                out[#out + 1] = string.sub(s, i, i + n - 1)
                i = i + n
            else
                out[#out + 1] = string.format("\\u%04x", c)
                i = i + 1
            end
        end
    end
    out[#out + 1] = '"'
    return table.concat(out)
end

local function isArray(t)
    if t == json.EMPTY_ARRAY then return true end
    local n = #t
    if n == 0 then return false end
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then return false end
    end
    return true
end

local encodeValue

local function encodeTable(t)
    local parts = {}
    if isArray(t) then
        for i = 1, #t do parts[i] = encodeValue(t[i]) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = tostring(k) end
    table.sort(keys) -- stable output
    for _, k in ipairs(keys) do
        parts[#parts + 1] = encodeString(k) .. ":" .. encodeValue(t[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

encodeValue = function(v)
    local t = type(v)
    if v == nil or v == json.null then return "null"
    elseif t == "boolean" then return v and "true" or "false"
    elseif t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return "null" end
        if math.type(v) == "integer" then return string.format("%d", v) end
        return string.format("%.14g", v)
    elseif t == "string" then return encodeString(v)
    elseif t == "table" then return encodeTable(v)
    end
    error("can't encode a " .. t .. " as JSON")
end

function json.encode(v)
    return encodeValue(v)
end

---------------------------------------------------------------------------
-- Decoding
---------------------------------------------------------------------------

-- UTF-8 bytes for a code point.
local function codepointToUtf8(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F))
    end
    if cp < 0x10000 then
        return string.char(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
    end
    return string.char(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F))
end

local decodeValue

local function skipSpace(s, i)
    return string.find(s, "[^ \t\r\n]", i) or (#s + 1)
end

local function decodeString(s, i)
    -- s[i] is the opening quote
    local out, j = {}, i + 1
    while true do
        local c = string.sub(s, j, j)
        if c == "" then error("unterminated string") end
        if c == '"' then return table.concat(out), j + 1 end
        if c == "\\" then
            local e = string.sub(s, j + 1, j + 1)
            local simple = ({ ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" })[e]
            if simple then
                out[#out + 1] = simple
                j = j + 2
            elseif e == "u" then
                local hex = string.sub(s, j + 2, j + 5)
                local cp = tonumber(hex, 16)
                if not cp or #hex < 4 then error("bad \\u escape") end
                j = j + 6
                -- Surrogate pair (e.g. emoji)
                if cp >= 0xD800 and cp <= 0xDBFF and string.sub(s, j, j + 1) == "\\u" then
                    local lo = tonumber(string.sub(s, j + 2, j + 5), 16)
                    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                        j = j + 6
                    end
                end
                out[#out + 1] = codepointToUtf8(cp)
            else
                error("bad escape \\" .. e)
            end
        else
            -- Copy a run of ordinary characters in one go.
            local k = string.find(s, '["\\]', j) or (#s + 1)
            out[#out + 1] = string.sub(s, j, k - 1)
            j = k
        end
    end
end

local function decodeArray(s, i)
    local arr, n = {}, 0
    i = skipSpace(s, i + 1)
    if string.sub(s, i, i) == "]" then return arr, i + 1 end
    while true do
        local v
        v, i = decodeValue(s, i)
        n = n + 1
        arr[n] = v
        i = skipSpace(s, i)
        local c = string.sub(s, i, i)
        if c == "]" then return arr, i + 1 end
        if c ~= "," then error("expected , or ] in array") end
        i = skipSpace(s, i + 1)
    end
end

local function decodeObject(s, i)
    local obj = {}
    i = skipSpace(s, i + 1)
    if string.sub(s, i, i) == "}" then return obj, i + 1 end
    while true do
        if string.sub(s, i, i) ~= '"' then error("expected a key") end
        local k
        k, i = decodeString(s, i)
        i = skipSpace(s, i)
        if string.sub(s, i, i) ~= ":" then error("expected :") end
        local v
        v, i = decodeValue(s, skipSpace(s, i + 1))
        obj[k] = v
        i = skipSpace(s, i)
        local c = string.sub(s, i, i)
        if c == "}" then return obj, i + 1 end
        if c ~= "," then error("expected , or } in object") end
        i = skipSpace(s, i + 1)
    end
end

decodeValue = function(s, i)
    i = skipSpace(s, i)
    local c = string.sub(s, i, i)
    if c == "{" then return decodeObject(s, i)
    elseif c == "[" then return decodeArray(s, i)
    elseif c == '"' then return decodeString(s, i)
    elseif string.sub(s, i, i + 3) == "true" then return true, i + 4
    elseif string.sub(s, i, i + 4) == "false" then return false, i + 5
    elseif string.sub(s, i, i + 3) == "null" then return nil, i + 4
    end
    local num = string.match(s, "^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    if num and num ~= "" then
        return tonumber(num), i + #num
    end
    error("unexpected character '" .. c .. "' at " .. i)
end

-- Decodes JSON text. Returns the value, or nil and an error message.
function json.decode(s)
    if type(s) ~= "string" then return nil, "not a string" end
    local ok, v, i = pcall(decodeValue, s, 1)
    if not ok then return nil, tostring(v) end
    if skipSpace(s, i) <= #s then return nil, "trailing characters" end
    return v
end

return json
