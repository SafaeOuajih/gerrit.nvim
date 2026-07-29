--- Choosing a change from a query result.
---
--- Telescope gets a proper picker with the change overview in the preview
--- pane; anything else falls back to `vim.ui.select`, which most picker
--- plugins already override with something pleasant.

local change_view = require 'gerrit.change'
local query = require 'gerrit.query'
local util = require 'gerrit.util'

local M = {}

--- Strongest vote on a change, as a short marker for the list.
---@param change gerrit.Change
---@return string
local function vote_marker(change)
  local lowest, highest = 0, 0
  for _, approval in ipairs(util.get(change, 'currentPatchSet', 'approvals') or {}) do
    local value = tonumber(approval.value) or 0
    lowest = math.min(lowest, value)
    highest = math.max(highest, value)
  end

  -- A single block outweighs any amount of praise, so show it in preference.
  local shown = lowest < 0 and lowest or highest
  if shown == 0 then
    return '  '
  end
  return ('%+d'):format(shown)
end

--- The fields shown for a change in the list.
---@param change gerrit.Change
---@return string number, string subject, string owner, string age, string vote
local function columns(change)
  return tostring(change.number),
    change.subject or '',
    util.get(change, 'owner', 'name') or '',
    util.ago(change.lastUpdated),
    vote_marker(change)
end

---@param changes gerrit.Change[]
---@param opts { title: string, on_select: fun(change: gerrit.Change) }
local function telescope_picker(changes, opts)
  local pickers = require 'telescope.pickers'
  local finders = require 'telescope.finders'
  local previewers = require 'telescope.previewers'
  local actions = require 'telescope.actions'
  local action_state = require 'telescope.actions.state'
  local entry_display = require 'telescope.pickers.entry_display'
  local conf = require('telescope.config').values

  local displayer = entry_display.create {
    separator = '  ',
    items = {
      { width = 7 },
      { width = 2 },
      { width = 62 },
      { width = 18 },
      { remaining = true },
    },
  }

  pickers
    .new({}, {
      prompt_title = opts.title,
      finder = finders.new_table {
        results = changes,
        entry_maker = function(change)
          local number, subject, owner, age, vote = columns(change)
          return {
            value = change,
            ordinal = table.concat({ number, subject, owner, change.branch or '' }, ' '),
            display = function()
              return displayer {
                { number, 'GerritField' },
                { vote, vote:match '^%-' and 'GerritRejected' or 'GerritApproved' },
                subject,
                { owner, 'Comment' },
                { age, 'Comment' },
              }
            end,
          }
        end,
      },
      sorter = conf.generic_sorter {},
      previewer = previewers.new_buffer_previewer {
        title = 'Change',
        define_preview = function(self, entry)
          vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, change_view.lines(entry.value))
        end,
      },
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            opts.on_select(entry.value)
          end
        end)
        return true
      end,
    })
    :find()
end

---@param changes gerrit.Change[]
---@param opts { title: string, on_select: fun(change: gerrit.Change) }
local function select_picker(changes, opts)
  vim.ui.select(changes, {
    prompt = opts.title,
    format_item = function(change)
      local number, subject, owner, age = columns(change)
      return ('%-7s %-64s %-16s %s'):format(number, subject, owner, age)
    end,
  }, function(change)
    if change then
      opts.on_select(change)
    end
  end)
end

--- Present a list of changes and open whichever one is picked.
---@param changes gerrit.Change[]
---@param opts { title: string|nil, on_select: fun(change: gerrit.Change)|nil }|nil
M.select = function(changes, opts)
  opts = opts or {}

  local settings = {
    title = opts.title or 'Gerrit changes',
    on_select = opts.on_select or function(change)
      change_view.show(change)
    end,
  }

  if #changes == 0 then
    util.info 'no changes matched'
    return
  end
  if #changes == 1 then
    settings.on_select(changes[1])
    return
  end

  if pcall(require, 'telescope') then
    telescope_picker(changes, settings)
  else
    select_picker(changes, settings)
  end
end

--- Run a query and offer the result.
---@param query_string string|nil defaults to the configured query
---@param opts { title: string|nil, on_select: fun(change: gerrit.Change)|nil }|nil
M.open = function(query_string, opts)
  query_string = query_string and util.trim(query_string) or ''
  if query_string == '' then
    query_string = query.default_query()
  end

  util.info(('querying %s...'):format(query_string))

  query.run(query_string, nil, function(changes, err)
    if not changes then
      util.err(('query failed: %s'):format(err or 'unknown error'))
      return
    end
    M.select(changes, vim.tbl_extend('keep', opts or {}, { title = query_string }))
  end)
end

return M
