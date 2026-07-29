--- Small helpers shared by the rest of gerrit.nvim.

local M = {}

local TITLE = 'gerrit.nvim'

--- Notify through the standard UI, tagged so the source is obvious.
---@param msg string
---@param level integer|nil one of `vim.log.levels`, defaults to INFO
M.notify = function(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = TITLE })
end

---@param msg string
M.info = function(msg)
  M.notify(msg, vim.log.levels.INFO)
end

---@param msg string
M.warn = function(msg)
  M.notify(msg, vim.log.levels.WARN)
end

---@param msg string
M.err = function(msg)
  M.notify(msg, vim.log.levels.ERROR)
end

--- Strip surrounding whitespace.
---@param s string
---@return string
M.trim = function(s)
  return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

--- Split a blob of command output into lines, dropping the trailing empty one.
---@param s string|nil
---@return string[]
M.lines = function(s)
  if not s or s == '' then
    return {}
  end
  return vim.split((s:gsub('\r\n', '\n'):gsub('\n$', '')), '\n', { plain = true })
end

--- Drop leading and trailing blank lines from a list of lines.
---@param lines string[]
---@return string[]
M.strip_blank = function(lines)
  local first, last = 1, #lines
  while first <= last and M.trim(lines[first]) == '' do
    first = first + 1
  end
  while last >= first and M.trim(lines[last]) == '' do
    last = last - 1
  end
  return vim.list_slice(lines, first, last)
end

--- Steps used to turn a duration in seconds into a short human string.
local spans = {
  { 60, 's' },
  { 60, 'm' },
  { 24, 'h' },
  { 7, 'd' },
  { 4.35, 'w' },
  { 12, 'mo' },
  { math.huge, 'y' },
}

--- Format a Gerrit timestamp (epoch seconds) as an age such as "3d ago".
---@param ts integer|nil
---@return string
M.ago = function(ts)
  if not ts or ts == 0 then
    return ''
  end

  local delta = os.time() - ts
  if delta < 0 then
    delta = 0
  end

  for _, span in ipairs(spans) do
    local size, unit = span[1], span[2]
    if delta < size then
      return ('%d%s ago'):format(math.floor(delta), unit)
    end
    delta = delta / size
  end
  return os.date('%Y-%m-%d', ts) --[[@as string]]
end

--- Soft-wrap text to a width, keeping existing line breaks.
---@param text string
---@param width integer
---@return string[]
M.wrap = function(text, width)
  local out = {}
  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    if line == '' then
      table.insert(out, '')
    end
    while #line > 0 do
      if #line <= width then
        table.insert(out, line)
        break
      end
      -- Break on the last space that fits, or hard-break a long token.
      local cut = line:sub(1, width + 1):match '^.*()%s'
      if not cut or cut < width / 2 then
        cut = width + 1
      end
      table.insert(out, (line:sub(1, cut - 1):gsub('%s+$', '')))
      line = line:sub(cut):gsub('^%s+', '')
    end
  end
  return out
end

--- Quote a string the way Gerrit's own command line tokenizer expects.
---
--- ssh does not run a shell on the far side: it concatenates its arguments
--- with spaces and Gerrit re-splits the result itself, honouring double quotes
--- and backslash escapes. Anything containing whitespace has to arrive with
--- those quotes still in it.
---@param s string
---@return string
M.quote = function(s)
  if s:match '^[%w%-%_%./:=,+@%^%$%*%[%]%{%}%(%)~!%%|&<>#;]*$' then
    return s
  end
  return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

--- Read a nested field, returning nil instead of erroring on a missing parent.
---@param tbl table|nil
---@param ... string|integer
---@return any
M.get = function(tbl, ...)
  local node = tbl
  for _, key in ipairs { ... } do
    if type(node) ~= 'table' then
      return nil
    end
    node = node[key]
  end
  return node
end

return M
