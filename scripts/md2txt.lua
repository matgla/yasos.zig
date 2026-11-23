-- Pandoc filter for scripts/md2txt.py: Markdown -> plain ASCII text.
--
-- Headings get an underline (= for levels 1-2, - for 3, none below) and
-- tables wider than the page get column widths that fit it, so the plain
-- writer wraps their cells instead of running past --columns.

local columns = tonumber(PANDOC_WRITER_OPTIONS and PANDOC_WRITER_OPTIONS.columns) or 78
local stringify = pandoc.utils.stringify

function Header(h)
  local text = stringify(h.content)
  if h.level == 1 then
    text = text:upper()
  end
  local rule = ({ "=", "=", "-" })[h.level]
  if rule then
    text = text .. "\n" .. string.rep(rule, #text)
  end
  -- pandoc puts no blank line between two raw blocks: add our own
  return pandoc.RawBlock("plain", text .. "\n")
end

-- Longest word and whole length of every column, over all rows.
local function measure(tbl)
  local n = #tbl.colspecs
  local full, word = {}, {}
  for i = 1, n do full[i], word[i] = 1, 1 end
  local function rows(list)
    for _, row in ipairs(list) do
      for i, cell in ipairs(row.cells) do
        if i <= n then
          local s = stringify(cell.contents)
          full[i] = math.max(full[i], #s)
          for w in s:gmatch("%S+") do word[i] = math.max(word[i], #w) end
        end
      end
    end
  end
  rows(tbl.head.rows)
  for _, body in ipairs(tbl.bodies) do
    rows(body.head)
    rows(body.body)
  end
  rows(tbl.foot.rows)
  return full, word
end

function Table(tbl)
  local n = #tbl.colspecs
  local full, word = measure(tbl)
  local border = 3 * n + 1                -- "| " ... " | " ... " |"
  local need = border
  for i = 1, n do need = need + full[i] end
  if need <= columns then return nil end  -- natural widths fit

  -- Water-filling: short columns keep their natural width, the rest share
  -- what is left equally (but never below their longest word if possible).
  local avail = columns - border
  local width, open = {}, {}
  for i = 1, n do open[i] = true end
  local left, count = avail, n
  local changed = true
  while changed and count > 0 do
    changed = false
    local share = left / count
    for i = 1, n do
      if open[i] and full[i] <= share then
        width[i], open[i] = full[i], false
        left, count, changed = left - full[i], count - 1, true
      end
    end
  end
  -- pandoc widens a column to its longest word anyway: start the open
  -- columns there and share out the rest towards their natural widths.
  for i = 1, n do
    if open[i] then
      width[i] = math.min(word[i], full[i])
      left = left - width[i]
    end
  end
  while left > 0 do
    local grew = false
    for i = 1, n do
      if open[i] and left > 0 and width[i] < full[i] then
        width[i], left, grew = width[i] + 1, left - 1, true
      end
    end
    if not grew then break end
  end

  for i = 1, n do
    -- pandoc gives a cell floor(columns * w) - 3 characters
    tbl.colspecs[i] = { tbl.colspecs[i][1], (width[i] + 3) / columns }
  end
  return tbl
end
