--- gerrit.nvim -- review Gerrit changes without leaving Neovim.
---
--- Everything is driven by a single `:Gerrit` command:
---
--- ```
--- :Gerrit                       pick from the open changes of this project
--- :Gerrit list status:merged    pick from an arbitrary query
--- :Gerrit mine                  your own open changes
--- :Gerrit open 12345            the overview of one change
--- :Gerrit diff 12345            its diff, ready to be commented on
--- :Gerrit review [12345]        compose and publish a review
--- :Gerrit message 12345 lgtm    post a one-line message
--- :Gerrit drafts                the comments you have not published yet
--- ```

local comments = require 'gerrit.comments'
local config = require 'gerrit.config'
local query = require 'gerrit.query'
local ui = require 'gerrit.ui'
local util = require 'gerrit.util'

local M = {}

--- The change the current buffer is about, when it is one of our buffers.
---@return gerrit.Change|nil
local function current_change()
  local buf = vim.api.nvim_get_current_buf()
  return require('gerrit.diff').change_at(buf) or require('gerrit.change').change_at(buf)
end

--- Resolve a change number from an argument, the current buffer, or neither.
---@param arg string|nil
---@param cb fun(change: gerrit.Change)
local function resolve(arg, cb)
  if arg and arg:match '^%d+$' then
    query.change(arg, function(change, err)
      if not change then
        util.err(err or 'change not found')
        return
      end
      cb(change)
    end)
    return
  end

  local change = current_change()
  if change then
    cb(change)
    return
  end

  util.err 'no change number given, and this buffer is not a Gerrit buffer'
end

--- Show every draft comment still waiting to be published.
local function show_drafts()
  local pending = comments.pending()

  if #pending == 0 then
    util.info 'no unpublished draft comments'
    return
  end

  local lines = {}
  for _, entry in ipairs(pending) do
    table.insert(lines, ('%s  (%d)'):format(entry.key, #entry.drafts))
    for _, draft in ipairs(entry.drafts) do
      table.insert(lines, '    ' .. comments.summary(draft))
    end
  end

  local buf = ui.scratch { filetype = 'gerrit', modifiable = false }
  ui.set_lines(buf, lines)
  ui.float(buf, { title = 'Unpublished drafts', footer = 'q to close', height = 0.4 })
  ui.map(buf, 'n', 'q', function()
    vim.api.nvim_buf_delete(buf, { force = true })
  end, 'Close')
end

---@type table<string, fun(args: string[], raw: string)>
local subcommands = {}

subcommands.list = function(_, raw)
  require('gerrit.picker').open(raw)
end

subcommands.mine = function()
  require('gerrit.picker').open 'status:open owner:self'
end

subcommands.open = function(args)
  resolve(args[1], function(change)
    require('gerrit.change').show(change)
  end)
end

subcommands.diff = function(args)
  resolve(args[1], function(change)
    require('gerrit.diff').open(change)
  end)
end

subcommands.review = function(args)
  resolve(args[1], function(change)
    require('gerrit.review').open(change)
  end)
end

subcommands.message = function(args, raw)
  local number, message = args[1], nil

  if number and number:match '^%d+$' then
    message = util.trim(raw:sub(#number + 1))
  else
    number = nil
    message = util.trim(raw)
  end

  if message == '' then
    util.err 'nothing to say: :Gerrit message [<change>] <text>'
    return
  end

  resolve(number, function(change)
    require('gerrit.review').quick_message(change.number, message)
  end)
end

subcommands.drafts = function()
  show_drafts()
end

--- Every draft still held locally, grouped by change.
---@return { key: string, drafts: gerrit.Draft[] }[]
M.pending_drafts = function()
  return comments.pending()
end

---@param opts table the options table `nvim_create_user_command` hands over
local function dispatch(opts)
  local args = opts.fargs
  if #args == 0 then
    require('gerrit.picker').open(nil)
    return
  end

  local name = args[1]
  local handler = subcommands[name]
  if not handler then
    -- Anything that is not a subcommand is treated as a query, so
    -- `:Gerrit status:open topic:foo` does the obvious thing.
    require('gerrit.picker').open(opts.args)
    return
  end

  handler(vim.list_slice(args, 2), util.trim(opts.args:sub(#name + 1)))
end

---@param arg_lead string
---@param line string
---@return string[]
local function complete(arg_lead, line)
  -- Only the first word is a subcommand; after that we have nothing useful to
  -- offer, since change numbers would need a round trip to the server.
  if line:match '^%s*Gerrit%s+%S+%s' then
    return {}
  end

  local names = vim.tbl_keys(subcommands)
  table.sort(names)
  return vim.tbl_filter(function(name)
    return name:sub(1, #arg_lead) == arg_lead
  end, names)
end

--- Set the plugin up. Safe to call with no arguments.
---@param opts gerrit.Config|nil
M.setup = function(opts)
  config.setup(opts)
  -- `remote` and `project` feed the remote lookup, so anything cached from an
  -- earlier setup() is now suspect.
  require('gerrit.git').forget()
  ui.setup_highlights()

  vim.api.nvim_create_user_command('Gerrit', dispatch, {
    nargs = '*',
    complete = complete,
    desc = 'Review Gerrit changes',
  })

  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('gerrit.highlights', { clear = true }),
    callback = ui.setup_highlights,
  })
end

return M
