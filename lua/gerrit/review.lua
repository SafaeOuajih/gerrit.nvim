--- Composing and publishing a review.
---
--- A review is one request: a message, the label votes, and every draft
--- comment collected while reading the diff. Gerrit takes all of it as a
--- ReviewInput object on stdin, which is why nothing here has to worry about
--- quoting a multi-line message onto an ssh command line.

local comments = require 'gerrit.comments'
local config = require 'gerrit.config'
local query = require 'gerrit.query'
local ssh = require 'gerrit.ssh'
local ui = require 'gerrit.ui'
local util = require 'gerrit.util'

local M = {}

--- Identify a patch set the way `gerrit review` expects: `change,patchset`.
---@param change gerrit.Change
---@return string|nil
local function patch_set_id(change)
  local number = util.get(change, 'currentPatchSet', 'number')
  if not number then
    return nil
  end
  return ('%s,%s'):format(change.number, number)
end

--- Send a ReviewInput to the server.
---@param change gerrit.Change
---@param input table a Gerrit ReviewInput
---@param cb fun(ok: boolean, err: string|nil)
M.publish = function(change, input, cb)
  local id = patch_set_id(change)
  if not id then
    cb(false, 'this change has no current patch set')
    return
  end

  local body = vim.json.encode(input)
  ssh.exec({ 'review', '--json', id }, { stdin = body .. '\n' }, function(ok, _, stderr)
    if not ok then
      cb(false, util.trim(stderr))
      return
    end
    cb(true, nil)
  end)
end

--- Publish, then clean up: drafts are gone from the server's point of view, so
--- drop the local copies and refresh whatever is on screen.
---@param change gerrit.Change
---@param input table
local function publish_and_settle(change, input)
  local key = query.key(change)
  local count = input.comments and comments.count(key) or 0

  M.publish(change, input, function(ok, err)
    if not ok then
      util.err(('publishing the review failed: %s'):format(err or 'unknown error'))
      return
    end

    comments.clear(key)

    local what = { ('review posted on change %s'):format(change.number) }
    if count > 0 then
      table.insert(what, ('%d inline comment%s'):format(count, count == 1 and '' or 's'))
    end
    for name, value in pairs(input.labels or {}) do
      table.insert(what, ('%s %+d'):format(name, value))
    end
    util.info(table.concat(what, ', '))

    require('gerrit.diff').redraw(key)
    require('gerrit.change').redraw(change.number)
  end)
end

--- Build the template shown in the compose buffer.
---@param change gerrit.Change
---@return string[] lines, integer message_row 1-based row the cursor starts on
local function template(change)
  local keys = config.options.keys.review
  local key = query.key(change)
  local drafts = comments.list(key)

  local lines = {
    ('# Change %s  %s'):format(change.number, change.subject or ''),
    ('# %s  %s  patch set %s'):format(
      change.project or '?',
      change.branch or '?',
      util.get(change, 'currentPatchSet', 'number') or '?'
    ),
    '#',
  }

  if #drafts > 0 then
    table.insert(lines, ('# %d draft comment%s will be published with this review:'):format(#drafts, #drafts == 1 and '' or 's'))
    for _, draft in ipairs(drafts) do
      table.insert(lines, '#   ' .. comments.summary(draft))
    end
  else
    table.insert(lines, '# No draft comments; this review is the message below.')
  end

  vim.list_extend(lines, {
    '#',
    '# Vote by writing a value after a label; an empty value leaves it alone.',
    '# Everything under the labels is the message. Lines starting with # are dropped.',
    ('# %s publishes, %s aborts.'):format(keys.publish, keys.quit),
    '',
  })

  for _, label in ipairs(query.labels(change)) do
    table.insert(lines, label .. ':')
  end

  table.insert(lines, '')
  table.insert(lines, '')

  return lines, #lines
end

--- Read the compose buffer back into a message and a set of votes.
---@param lines string[]
---@param labels string[] the label names that may appear
---@return string message, table<string, integer> votes, string|nil err
local function parse(lines, labels)
  local known = {}
  for _, label in ipairs(labels) do
    known[label] = true
  end

  local votes = {}
  local body = {}

  for _, line in ipairs(lines) do
    if not line:match '^%s*#' then
      local name, value = line:match '^([%w][%w%-_]*):%s*(.*)%s*$'
      -- A label only counts while we are still above the message; once real
      -- text has started, "Note: ..." is prose, not a vote.
      if name and known[name] and #body == 0 then
        value = util.trim(value)
        if value ~= '' then
          local number = tonumber(value)
          if not number or number ~= math.floor(number) then
            return '', {}, ('%q is not a vote; %s takes a whole number such as +1'):format(value, name)
          end
          votes[name] = number
        end
      else
        table.insert(body, line)
      end
    end
  end

  return table.concat(util.strip_blank(body), '\n'), votes, nil
end

--- Open the compose buffer for a change.
---@param change gerrit.Change
M.open = function(change)
  local keys = config.options.keys.review
  local labels = query.labels(change)
  local lines, row = template(change)
  local key = query.key(change)

  local _, win = ui.editor({
    title = ('Review change %s'):format(change.number),
    footer = ('%s publish   %s abort'):format(keys.publish, keys.quit),
    lines = lines,
    filetype = 'gitcommit',
    accept = keys.publish,
    cancel = keys.quit,
    height = 0.5,
  }, function(written)
    local message, votes, err = parse(written, labels)
    if err then
      util.err(err)
      return
    end

    local input = {}
    if message ~= '' then
      input.message = message
    end
    if not vim.tbl_isempty(votes) then
      input.labels = votes
    end
    input.comments = comments.to_input(key)

    if not input.message and not input.labels and not input.comments then
      util.warn 'nothing to publish: no message, no vote, no comments'
      return
    end

    publish_and_settle(change, input)
  end)

  pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
  vim.cmd.startinsert()
end

--- Post a one-line message without opening a buffer, for `:Gerrit message`.
---@param number integer|string
---@param message string
M.quick_message = function(number, message)
  query.change(number, function(change, err)
    if not change then
      util.err(err or 'change not found')
      return
    end
    publish_and_settle(change, { message = message })
  end)
end

return M
