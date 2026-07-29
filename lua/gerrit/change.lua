--- The change overview: everything about a patch except the diff itself.

local config = require 'gerrit.config'
local query = require 'gerrit.query'
local ui = require 'gerrit.ui'
local util = require 'gerrit.util'

local M = {}

local ns = vim.api.nvim_create_namespace 'gerrit.change'

---@type table<integer, gerrit.Change>
local state = {}

--- Single-letter status for a file, matching the letters git uses.
local file_status = {
  ADDED = 'A',
  MODIFIED = 'M',
  DELETED = 'D',
  RENAMED = 'R',
  COPIED = 'C',
  REWRITE = 'W',
}

--- Collects lines together with the highlights that go over them.
local function builder()
  local self = { lines = {}, hls = {} }

  ---@param text string|nil
  ---@param hl string|nil applied to the whole line
  function self.add(text, hl)
    table.insert(self.lines, text or '')
    if hl then
      table.insert(self.hls, { row = #self.lines - 1, hl = hl })
    end
  end

  --- A `name  value` row, with the name highlighted.
  ---@param name string
  ---@param value string|nil
  function self.field(name, value)
    if value == nil or value == '' then
      return
    end
    self.add(('%-12s %s'):format(name, value))
    table.insert(self.hls, { row = #self.lines - 1, col = 0, end_col = #name, hl = 'GerritField' })
  end

  ---@param title string
  function self.section(title)
    if #self.lines > 0 then
      self.add ''
    end
    self.add(title, 'GerritHeader')
  end

  return self
end

--- Format a person the way Gerrit reports them.
---@param who table|nil
---@return string
local function person(who)
  if not who then
    return ''
  end
  if who.name and who.email then
    return ('%s <%s>'):format(who.name, who.email)
  end
  return who.name or who.username or who.email or ''
end

--- Turn a change into the lines shown in the overview buffer.
---@param change gerrit.Change
---@param opts { compact: boolean|nil }|nil
---@return string[] lines, table[] highlights
M.render = function(change, opts)
  opts = opts or {}
  local out = builder()
  local patch_set = change.currentPatchSet or {}

  out.add(('Change %s'):format(change.number), 'GerritHeader')
  out.add(change.subject or '', 'GerritSubject')
  out.add ''

  out.field('Project', change.project)
  out.field('Branch', change.branch)
  out.field('Topic', change.topic)
  out.field('Status', change.status)
  out.field('Owner', person(change.owner))
  out.field('Updated', util.ago(change.lastUpdated))
  out.field('Patch set', patch_set.number and tostring(patch_set.number) or nil)
  out.field('Ref', patch_set.ref)
  out.field('URL', change.url)

  local approvals = patch_set.approvals or {}
  if #approvals > 0 then
    out.section 'Votes'
    for _, approval in ipairs(approvals) do
      local value = tonumber(approval.value) or 0
      local row = ('  %-14s %+d  %s'):format(approval.type or '?', value, person(approval.by))
      out.add(row, value > 0 and 'GerritApproved' or (value < 0 and 'GerritRejected' or nil))
    end
  end

  local reviewers = change.allReviewers or {}
  if #reviewers > 0 then
    local names = {}
    for _, reviewer in ipairs(reviewers) do
      table.insert(names, reviewer.name or reviewer.username or reviewer.email)
    end
    out.section 'Reviewers'
    out.add('  ' .. table.concat(names, ', '))
  end

  local files = patch_set.files or {}
  if #files > 0 then
    out.section 'Files'
    for _, file in ipairs(files) do
      if file.file ~= '/COMMIT_MSG' then
        out.add(
          ('  %s  %-50s +%d -%d'):format(
            file_status[file.type] or '?',
            file.file,
            file.insertions or 0,
            math.abs(file.deletions or 0)
          )
        )
      end
    end
  end

  if not opts.compact and change.commitMessage then
    out.section 'Commit message'
    -- The subject is already at the top of the buffer; show the body.
    local body = vim.split(change.commitMessage, '\n', { plain = true })
    for i = 2, #body do
      out.add('  ' .. body[i])
    end
  end

  local messages = change.comments or {}
  if #messages > 0 then
    out.section(('Messages (%d)'):format(#messages))
    for _, message in ipairs(messages) do
      out.add ''
      out.add(('  %s  %s'):format(person(message.reviewer), util.ago(message.timestamp)), 'GerritField')
      for _, line in ipairs(util.wrap(message.message or '', 90)) do
        out.add('    ' .. line, 'GerritComment')
      end
    end
  end

  return out.lines, out.hls
end

--- Just the lines, for previewers that do not care about highlighting.
---@param change gerrit.Change
---@return string[]
M.lines = function(change)
  local lines = M.render(change, { compact = true })
  return lines
end

--- Paint a change into an existing buffer.
---@param buf integer
---@param change gerrit.Change
local function draw(buf, change)
  local lines, hls = M.render(change)
  local keys = config.options.keys.change

  table.insert(lines, '')
  table.insert(
    lines,
    ('%s diff   %s review   %s browse   %s refresh   %s quit'):format(
      keys.diff,
      keys.review,
      keys.browse,
      keys.refresh,
      keys.quit
    )
  )
  table.insert(hls, { row = #lines - 1, hl = 'GerritHint' })

  ui.set_lines(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  for _, hl in ipairs(hls) do
    if hl.col then
      vim.api.nvim_buf_set_extmark(buf, ns, hl.row, hl.col, {
        end_col = hl.end_col,
        hl_group = hl.hl,
      })
    else
      vim.api.nvim_buf_set_extmark(buf, ns, hl.row, 0, { line_hl_group = hl.hl })
    end
  end

  state[buf] = change
end

--- The change an overview buffer is showing, if it is one of ours.
---@param buf integer
---@return gerrit.Change|nil
M.change_at = function(buf)
  return state[buf]
end

--- Re-query a change and repaint every buffer showing it.
---@param number integer|string
M.redraw = function(number)
  local targets = {}
  for buf, change in pairs(state) do
    if not vim.api.nvim_buf_is_valid(buf) then
      state[buf] = nil
    elseif tostring(change.number) == tostring(number) then
      table.insert(targets, buf)
    end
  end

  if #targets == 0 then
    return
  end

  query.change(number, function(change)
    if not change then
      return
    end
    for _, buf in ipairs(targets) do
      if vim.api.nvim_buf_is_valid(buf) then
        draw(buf, change)
      end
    end
  end)
end

---@param buf integer
---@param change gerrit.Change
local function attach_keys(buf, change)
  local keys = config.options.keys.change

  ui.map(buf, 'n', keys.diff, function()
    require('gerrit.diff').open(state[buf] or change)
  end, 'Gerrit: open the diff')
  ui.map(buf, 'n', keys.review, function()
    require('gerrit.review').open(state[buf] or change)
  end, 'Gerrit: review this change')
  ui.map(buf, 'n', keys.browse, function()
    local url = (state[buf] or change).url
    if url then
      ui.browse(url, config.options.browser)
    end
  end, 'Gerrit: open in a browser')
  ui.map(buf, 'n', keys.refresh, function()
    M.redraw((state[buf] or change).number)
  end, 'Gerrit: refresh')
  ui.map(buf, 'n', keys.quit, function()
    vim.api.nvim_buf_delete(buf, { force = true })
  end, 'Gerrit: close')
end

--- Show a change, fetching the full detail if we only have a summary.
---@param change gerrit.Change
---@param opts { split: string|nil }|nil
M.show = function(change, opts)
  local buf = ui.scratch {
    name = ('gerrit://%s'):format(change.number),
    filetype = 'gerrit',
    modifiable = false,
  }

  draw(buf, change)
  attach_keys(buf, change)

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    callback = function()
      state[buf] = nil
    end,
  })

  local win = ui.open(buf, { split = opts and opts.split or 'tab' })
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].signcolumn = 'no'

  -- The list query does not carry the commit message, files or discussion, so
  -- fill those in as soon as the detailed query comes back.
  if not change.commitMessage then
    query.change(change.number, function(full)
      if full and vim.api.nvim_buf_is_valid(buf) then
        draw(buf, full)
      end
    end)
  end

  return buf
end

--- Open a change by number.
---@param number integer|string
---@param opts { split: string|nil }|nil
M.open = function(number, opts)
  query.change(number, function(change, err)
    if not change then
      util.err(err or 'change not found')
      return
    end
    M.show(change, opts)
  end)
end

return M
