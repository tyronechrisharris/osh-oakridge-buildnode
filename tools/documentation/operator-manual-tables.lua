-- Pandoc's pipe-table default is a sequence of natural-width LaTeX columns.
-- That layout does not wrap prose and can extend past the PDF page boundary.
-- Give every documentation table explicit relative widths so Pandoc emits
-- wrapping paragraph columns.  The ratios leave the explanatory column the
-- largest share while keeping labels and defaults readable in all locales.

local widths_by_count = {
  [2] = { 0.34, 0.66 },
  [3] = { 0.31, 0.15, 0.54 },
  [4] = { 0.22, 0.18, 0.18, 0.42 },
}

local function first_header(table_block)
  if not table_block.head or not table_block.head.rows[1] then
    return ""
  end
  local cell = table_block.head.rows[1].cells[1]
  return cell and pandoc.utils.stringify(cell.contents):lower() or ""
end

local function add_slash_breaks(inline)
  if not inline.text:find("/", 1, true) then
    return nil
  end

  local result = {}
  local start = 1
  while true do
    local position = inline.text:find("/", start, true)
    if not position then
      if start <= #inline.text then
        table.insert(result, pandoc.Str(inline.text:sub(start)))
      end
      break
    end
    table.insert(result, pandoc.Str(inline.text:sub(start, position)))
    table.insert(result, pandoc.RawInline("latex", "\\allowbreak{}"))
    start = position + 1
  end
  return result
end

-- Long slash-separated phrases also occur in prose and localized labels.
-- Let TeX break them everywhere; URLs and paths keep their exact characters.
function Str(inline)
  return add_slash_breaks(inline)
end

function Table(table_block)
  local count = #table_block.colspecs
  local widths = widths_by_count[count]

  if count == 2 then
    local header = first_header(table_block)
    if header == "symptom" or header == "síntoma" or
       header == "symptôme" or header == "σύμπτωμα" then
      widths = { 0.43, 0.57 }
    elseif header == "group" or header == "grupo" or
           header == "groupe" or header == "ομάδα" then
      widths = { 0.24, 0.76 }
    elseif header:find("type", 1, true) or
           header:find("tipo", 1, true) or
           header:find("τύπος", 1, true) then
      widths = { 0.22, 0.78 }
    end
  end

  if not widths then
    widths = {}
    for index = 1, count do
      widths[index] = 1 / count
    end
  end

  for index, colspec in ipairs(table_block.colspecs) do
    table_block.colspecs[index] = { colspec[1], widths[index] }
  end

  return table_block
end

local latex_escapes = {
  ["\\"] = "\\textbackslash{}",
  ["{"] = "\\{",
  ["}"] = "\\}",
  ["$"] = "\\$",
  ["&"] = "\\&",
  ["#"] = "\\#",
  ["^"] = "\\textasciicircum{}",
  ["_"] = "\\_",
  ["%"] = "\\%",
  ["~"] = "\\textasciitilde{}",
}

local function escape_latex(text)
  return (text:gsub("[\\{}$&#^_%%~]", latex_escapes))
end

-- CSV schemas are long by design and contain no spaces where TeX can wrap.
-- Insert a zero-width break opportunity after each comma. The rendered text
-- remains an exact CSV record when copied or extracted from the PDF.
function CodeBlock(block)
  local is_csv = false
  for _, class_name in ipairs(block.classes) do
    if class_name == "csv" then
      is_csv = true
      break
    end
  end
  if not is_csv then
    return nil
  end

  local lines = {}
  for line in (block.text .. "\n"):gmatch("(.-)\n") do
    local escaped = escape_latex(line):gsub(",", ",\\allowbreak{}")
    table.insert(lines, escaped .. "\\par")
  end

  return pandoc.RawBlock(
    "latex",
    "\\begin{quote}\\small\\ttfamily\\raggedright\n" ..
      table.concat(lines, "\n") ..
      "\n\\end{quote}"
  )
end
