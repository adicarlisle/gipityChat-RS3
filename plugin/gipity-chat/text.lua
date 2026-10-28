-- Text helpers: making AI replies safe and readable in the game's chat window.
--
--  * toGameText: UTF-8 -> plain ASCII the game's fonts can draw (accents folded,
--    smart punctuation replaced, emoji and anything else dropped). The game's Lua
--    has no utf8 library, so UTF-8 is decoded by hand.
--  * escapeMarkup: stop text from being read as RS markup (<col=..>, <img=..>).
--  * stripMarkdown: models like to answer in markdown; the window shows plain text.
--  * visibleLen / wrapText: word-wrapping that ignores markup tags.

local text = {}

-- Latin-1 letters (U+00C0..U+00FF) folded to ASCII.
local LATIN1 = {
    [0xC0] = "A", [0xC1] = "A", [0xC2] = "A", [0xC3] = "A", [0xC4] = "A", [0xC5] = "A", [0xC6] = "AE",
    [0xC7] = "C", [0xC8] = "E", [0xC9] = "E", [0xCA] = "E", [0xCB] = "E", [0xCC] = "I", [0xCD] = "I",
    [0xCE] = "I", [0xCF] = "I", [0xD0] = "D", [0xD1] = "N", [0xD2] = "O", [0xD3] = "O", [0xD4] = "O",
    [0xD5] = "O", [0xD6] = "O", [0xD7] = "x", [0xD8] = "O", [0xD9] = "U", [0xDA] = "U", [0xDB] = "U",
    [0xDC] = "U", [0xDD] = "Y", [0xDE] = "Th", [0xDF] = "ss",
    [0xE0] = "a", [0xE1] = "a", [0xE2] = "a", [0xE3] = "a", [0xE4] = "a", [0xE5] = "a", [0xE6] = "ae",
    [0xE7] = "c", [0xE8] = "e", [0xE9] = "e", [0xEA] = "e", [0xEB] = "e", [0xEC] = "i", [0xED] = "i",
    [0xEE] = "i", [0xEF] = "i", [0xF0] = "d", [0xF1] = "n", [0xF2] = "o", [0xF3] = "o", [0xF4] = "o",
    [0xF5] = "o", [0xF6] = "o", [0xF7] = "/", [0xF8] = "o", [0xF9] = "u", [0xFA] = "u", [0xFB] = "u",
    [0xFC] = "u", [0xFD] = "y", [0xFE] = "th", [0xFF] = "y",
}

-- Other common characters.
local SPECIAL = {
    [0x00A0] = " ", [0x00A3] = "GBP", [0x00A9] = "(c)", [0x00AB] = "\"", [0x00B0] = " deg", [0x00B7] = "-",
    [0x00BB] = "\"", [0x00BD] = "1/2", [0x00BC] = "1/4", [0x00BE] = "3/4", [0x00D7] = "x",
    [0x2010] = "-", [0x2011] = "-", [0x2012] = "-", [0x2013] = "-", [0x2014] = " - ", [0x2015] = " - ",
    [0x2018] = "'", [0x2019] = "'", [0x201A] = "'", [0x201C] = "\"", [0x201D] = "\"", [0x201E] = "\"",
    [0x2022] = "-", [0x2026] = "...", [0x2032] = "'", [0x2033] = "\"", [0x2122] = "(TM)",
    [0x2190] = "<-", [0x2192] = "->", [0x2194] = "<->", [0x21D2] = "=>", [0x2212] = "-",
    [0x2248] = "~", [0x2264] = "<=", [0x2265] = ">=", [0x2260] = "!=", [0x00B1] = "+/-",
    [0x2713] = "", [0x2714] = "", [0x2705] = "", [0x274C] = "",
}

-- Decodes one UTF-8 character at byte i. Returns code point and next index.
-- Invalid bytes are returned as-is (treated as Latin-1), so nothing is lost silently.
local function decodeAt(s, i)
    local c = string.byte(s, i)
    if c < 0x80 then return c, i + 1 end
    local n, cp
    if c >= 0xC2 and c <= 0xDF then n, cp = 1, c & 0x1F
    elseif c >= 0xE0 and c <= 0xEF then n, cp = 2, c & 0x0F
    elseif c >= 0xF0 and c <= 0xF4 then n, cp = 3, c & 0x07
    else return c, i + 1 end
    for k = 1, n do
        local b = string.byte(s, i + k)
        if not b or b < 0x80 or b > 0xBF then return c, i + 1 end
        cp = (cp << 6) | (b & 0x3F)
    end
    return cp, i + n + 1
end

-- Converts text to printable ASCII. Newlines become spaces.
function text.toGameText(s)
    local out, i = {}, 1
    while i <= #s do
        local cp
        cp, i = decodeAt(s, i)
        if cp >= 0x20 and cp < 0x7F then
            out[#out + 1] = string.char(cp)
        elseif cp == 0x0A or cp == 0x0D or cp == 0x09 then
            out[#out + 1] = " "
        elseif LATIN1[cp] then
            out[#out + 1] = LATIN1[cp]
        elseif SPECIAL[cp] then
            out[#out + 1] = SPECIAL[cp]
        end
        -- anything else (emoji, CJK, symbols) is dropped
    end
    local s2 = table.concat(out)
    s2 = string.gsub(s2, "%s+", " ")
    return (string.gsub(s2, "^%s*(.-)%s*$", "%1"))
end

local MARKUP_ESCAPES = { ["<"] = "<lt>", [">"] = "<gt>" }

-- Escapes RS markup in one pass, so "<lt>" isn't escaped again.
function text.escapeMarkup(s)
    return (string.gsub(s, "[<>]", MARKUP_ESCAPES))
end

-- Removes common markdown so replies read as plain chat text.
function text.stripMarkdown(s)
    s = string.gsub(s, "```.-```", " ")                -- code blocks
    s = string.gsub(s, "`([^`]*)`", "%1")              -- inline code
    s = string.gsub(s, "%*%*(.-)%*%*", "%1")           -- **bold**
    s = string.gsub(s, "__(.-)__", "%1")               -- __bold__
    s = string.gsub(s, "%[([^%]]+)%]%(([^%)]+)%)", "%1 (%2)") -- [link](url)
    s = string.gsub(s, "\n%s*#+%s*", "\n")             -- headings
    s = string.gsub(s, "^%s*#+%s*", "")
    s = string.gsub(s, "\n%s*[%*%-]%s+", "\n- ")       -- bullets
    s = string.gsub(s, "\n%s*>%s?", "\n")              -- quotes
    return s
end

-- Full clean-up for model output: markdown off, ASCII, markup escaped.
function text.forDisplay(s)
    return text.escapeMarkup(text.toGameText(text.stripMarkdown(s or "")))
end

function text.trim(s)
    return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- Characters shown on screen: "<lt>"/"<gt>" draw as one; other tags take no space.
function text.visibleLen(s)
    s = string.gsub(s, "<[lg]t>", "x")
    s = string.gsub(s, "<[^>]*>", "")
    return #s
end

-- Splits a word into { piece, width } so wrapping never breaks a tag or escape.
local function displayPieces(word)
    local out, i = {}, 1
    while i <= #word do
        local esc = string.match(word, "^<[lg]t>", i)
        local tag = not esc and string.match(word, "^<[^<>]*>", i)
        if esc then
            out[#out + 1] = { esc, 1 }
            i = i + #esc
        elseif tag then
            out[#out + 1] = { tag, 0 }
            i = i + #tag
        else
            out[#out + 1] = { string.sub(word, i, i), 1 }
            i = i + 1
        end
    end
    return out
end

-- Word-wraps into lines of at most `width` visible characters; the first line
-- may be shorter (`firstWidth`) to leave room for the sender's name.
function text.wrap(s, firstWidth, width)
    local lines, cur, curLen, limit = {}, {}, 0, firstWidth
    local function newLine()
        lines[#lines + 1] = table.concat(cur, " ")
        cur, curLen, limit = {}, 0, width
    end
    for word in string.gmatch(s, "%S+") do
        local wl = text.visibleLen(word)
        if wl > width then
            -- A very long word (like a URL): break it wherever it hits the edge.
            if curLen > 0 then newLine() end
            local piece, pl = {}, 0
            for _, p in ipairs(displayPieces(word)) do
                if pl >= limit and p[2] > 0 then
                    cur = { table.concat(piece) }
                    newLine()
                    piece, pl = {}, 0
                end
                piece[#piece + 1] = p[1]
                pl = pl + p[2]
            end
            cur, curLen = { table.concat(piece) }, pl
        else
            local need = (curLen == 0) and wl or (curLen + 1 + wl)
            if need > limit and curLen > 0 then
                newLine()
                need = wl
            end
            cur[#cur + 1] = word
            curLen = need
        end
    end
    if curLen > 0 or #lines == 0 then
        lines[#lines + 1] = table.concat(cur, " ")
    end
    return lines
end

return text
