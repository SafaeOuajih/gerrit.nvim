--- Draft inline comments.
---
--- Comments are collected locally and published in one go with the review, the
--- same way the web UI batches drafts behind its reply button. They outlive a
--- Neovim session: a review interrupted halfway through is exactly the moment
--- you do not want to lose your notes, so drafts are mirrored to a small JSON
--- file under `stdpath('state')`.

local config = require 'gerrit.config'
local util = require 'gerrit.util'

local M = {}

---@class gerrit.Range
---@field start_line integer
---@field start_character integer
---@field end_line integer
---@field end_character integer

---@class gerrit.Draft
---@field file string path the comment is attached to
---@field side 'REVISION'|'PARENT' new side or the parent it replaced
---@field line integer|nil line number, nil for a comment on the file itself
---@field range gerrit.Range|nil set when the comment covers several lines
---@field message string

---@type table<string, gerrit.Draft[]>
local drafts = {}

local loaded = false

--- Read the saved drafts back, once per session.
local function load()
  if loaded then
    return
  end
  loaded = true

  local path = config.options.draft_file
  if not path or vim.fn.filereadable(path) == 0 then
    return
  end

  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
  end)
  if ok and type(data) == 'table' then
    drafts = data
  end
end

--- Mirror the drafts to disk. Failures are silent: losing the cache is
--- annoying, but it must never break the review that is in progress.
local function save()
  local path = config.options.draft_file
  if not path then
    return
  end

  pcall(function()
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    if vim.tbl_isempty(drafts) then
      vim.fn.delete(path)
    else
      vim.fn.writefile({ vim.json.encode(drafts) }, path)
    end
  end)
end

--- All drafts held for a change.
---@param key string
---@return gerrit.Draft[]
M.list = function(key)
  load()
  return drafts[key] or {}
end

---@param key string
---@return integer
M.count = function(key)
  return #M.list(key)
end

--- Record a draft, replacing any earlier one on the same spot.
---@param key string
---@param draft gerrit.Draft
M.add = function(key, draft)
  load()
  M.remove(key, draft.file, draft.side, draft.line)
  drafts[key] = drafts[key] or {}
  table.insert(drafts[key], draft)
  save()
end

--- Drop the draft attached to one spot.
---@param key string
---@param file string
---@param side string
---@param line integer|nil
---@return boolean removed
M.remove = function(key, file, side, line)
  load()
  local list = drafts[key]
  if not list then
    return false
  end

  for i, draft in ipairs(list) do
    if draft.file == file and draft.side == side and draft.line == line then
      table.remove(list, i)
      if #list == 0 then
        drafts[key] = nil
      end
      save()
      return true
    end
  end
  return false
end

--- The draft covering a spot, if there is one.
---@param key string
---@param file string
---@param side string
---@param line integer|nil
---@return gerrit.Draft|nil
M.find = function(key, file, side, line)
  for _, draft in ipairs(M.list(key)) do
    if draft.file == file and draft.side == side and draft.line == line then
      return draft
    end
  end
end

--- Forget every draft on a change, once they have been published.
---@param key string
M.clear = function(key)
  load()
  drafts[key] = nil
  save()
end

--- Shape the drafts the way Gerrit's ReviewInput wants them: a map of path to
--- a list of comments.
---@param key string
---@return table<string, table[]>|nil nil when there is nothing to publish
M.to_input = function(key)
  local list = M.list(key)
  if #list == 0 then
    return nil
  end

  local out = {}
  for _, draft in ipairs(list) do
    local comment = {
      line = draft.line,
      range = draft.range,
      side = draft.side,
      message = draft.message,
      unresolved = config.options.unresolved,
    }
    out[draft.file] = out[draft.file] or {}
    table.insert(out[draft.file], comment)
  end
  return out
end

--- Every change that still has unpublished drafts, newest key order aside.
---@return { key: string, drafts: gerrit.Draft[] }[]
M.pending = function()
  load()

  local out = {}
  for key, list in pairs(drafts) do
    if #list > 0 then
      table.insert(out, { key = key, drafts = list })
    end
  end
  table.sort(out, function(a, b)
    return a.key < b.key
  end)
  return out
end

--- A one-line preview of a draft, for lists and summaries.
---@param draft gerrit.Draft
---@return string
M.summary = function(draft)
  local where = draft.line and (':' .. draft.line) or ''
  local first = vim.split(draft.message, '\n', { plain = true })[1] or ''
  return ('%s%s  %s'):format(draft.file, where, util.trim(first))
end

return M
