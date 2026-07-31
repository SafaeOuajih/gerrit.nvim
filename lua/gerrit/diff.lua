--- The diff view, and the mapping from screen lines back to Gerrit comments.
---
--- Reviewing in a terminal is mostly a bookkeeping problem: the cursor is on
--- line 41 of a buffer holding a unified diff, and Gerrit wants to hear about
--- line 88 of `src/foo.c` on the revision side. Parsing the hunk headers once,
--- when the diff is rendered, gives that answer for every line up front.

local comments = require 'gerrit.comments'
local config = require 'gerrit.config'
local git = require 'gerrit.git'
local query = require 'gerrit.query'
local ui = require 'gerrit.ui'
local util = require 'gerrit.util'

local M = {}

local ns = vim.api.nvim_create_namespace 'gerrit.diff'

---@class gerrit.Loc
---@field file string path to attach a comment to
---@field side 'REVISION'|'PARENT'
---@field line integer|nil nil on a file header, which means a file comment
---@field text string the diff line with its +/-/space marker removed

---@class gerrit.DiffState
---@field change gerrit.Change
---@field key string
---@field map table<integer, gerrit.Loc> buffer line to Gerrit location
---@field index table<string, table<string, table<integer, integer>>> file/side/line to buffer line

---@type table<integer, gerrit.DiffState>
local state = {}

--- Walk a unified diff and record what every line points at.
---@param lines string[] the diff, without any header we prepended
---@param offset integer number of buffer lines sitting above the diff
---@return table<integer, gerrit.Loc> map
local function parse(lines, offset)
  local map = {}
  local old_path, new_path ---@type string|nil, string|nil
  local old_ln, new_ln ---@type integer|nil, integer|nil

  for i, line in ipairs(lines) do
    local bufline = i + offset

    local a, b = line:match '^diff %-%-git a/(.-) b/(.+)$'
    if a then
      old_path, new_path = a, b
      old_ln, new_ln = nil, nil
      -- A comment on the header is a comment on the file as a whole, which
      -- Gerrit expresses as a comment with no line number.
      map[bufline] = { file = b, side = 'REVISION', text = b }
    elseif not old_ln and line:match '^%-%-%- ' then
      old_path = line:match '^%-%-%- a/(.+)$' or old_path
    elseif not old_ln and line:match '^%+%+%+ ' then
      new_path = line:match '^%+%+%+ b/(.+)$' or new_path
    else
      local o, n = line:match '^@@ %-(%d+),?%d* %+(%d+),?%d* @@'
      if o then
        old_ln, new_ln = tonumber(o), tonumber(n)
      elseif new_ln and old_ln then
        local marker = line:sub(1, 1)
        local text = line:sub(2)
        if marker == '+' then
          map[bufline] = { file = new_path, side = 'REVISION', line = new_ln, text = text }
          new_ln = new_ln + 1
        elseif marker == '-' then
          map[bufline] = { file = old_path, side = 'PARENT', line = old_ln, text = text }
          old_ln = old_ln + 1
        elseif marker == ' ' or line == '' then
          map[bufline] = { file = new_path, side = 'REVISION', line = new_ln, text = text }
          new_ln = new_ln + 1
          old_ln = old_ln + 1
        elseif marker ~= '\\' then
          -- Anything else ends the hunk body; "\ No newline at end of file"
          -- belongs to the line above it and is skipped.
          old_ln, new_ln = nil, nil
        end
      end
    end
  end

  return map
end

M.parse = parse

--- Invert the line map so a Gerrit location can be found on screen again.
---@param map table<integer, gerrit.Loc>
---@return table<string, table<string, table<integer, integer>>>
local function build_index(map)
  local index = {}
  for bufline, loc in pairs(map) do
    if loc.line then
      index[loc.file] = index[loc.file] or {}
      index[loc.file][loc.side] = index[loc.file][loc.side] or {}
      index[loc.file][loc.side][loc.line] = bufline
    end
  end
  return index
end

--- Header shown above the diff, summarising the change and the keys.
---@param change gerrit.Change
---@return string[]
local function header(change)
  local keys = config.options.keys.diff
  local patch_set = change.currentPatchSet or {}
  return {
    ('Change %s  %s'):format(change.number, change.subject or ''),
    ('%s  %s  patch set %s  by %s'):format(
      change.project or '?',
      change.branch or '?',
      patch_set.number or '?',
      util.get(change, 'owner', 'name') or '?'
    ),
    ('%s comment   %s delete   %s/%s navigate   %s review   %s quit'):format(
      keys.comment,
      keys.delete,
      keys.next,
      keys.prev,
      keys.review,
      keys.quit
    ),
    '',
  }
end

--- Draw drafts and published comments into the gutter and between the lines.
---@param buf integer
local function decorate(buf)
  local st = state[buf]
  if not st or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

  local width = math.max(vim.api.nvim_win_get_width(0) - 12, 40)

  --- Hang a block of virtual lines under a buffer line.
  ---@param bufline integer
  ---@param title string
  ---@param body string
  ---@param hl string
  ---@param sign string
  local function annotate(bufline, title, body, hl, sign)
    local virt = { { { '  ' .. title, hl } } }
    for _, text in ipairs(util.wrap(body, width)) do
      table.insert(virt, { { '  ' .. text, hl } })
    end

    vim.api.nvim_buf_set_extmark(buf, ns, bufline - 1, 0, {
      virt_lines = virt,
      sign_text = sign,
      sign_hl_group = hl .. 'Sign',
    })
  end

  -- Comments already on the server, so a diff shows the discussion so far.
  for _, comment in ipairs(util.get(st.change, 'currentPatchSet', 'comments') or {}) do
    local bufline = util.get(st.index, comment.file, 'REVISION', comment.line)
    if bufline then
      local who = util.get(comment, 'reviewer', 'name') or 'someone'
      annotate(bufline, who .. ':', comment.message or '', 'GerritComment', '▏')
    end
  end

  -- Then our own drafts, which are the point of the exercise.
  for _, draft in ipairs(comments.list(st.key)) do
    local bufline
    if draft.line then
      bufline = util.get(st.index, draft.file, draft.side, draft.line)
    else
      for line, loc in pairs(st.map) do
        if loc.file == draft.file and not loc.line then
          bufline = line
          break
        end
      end
    end
    if bufline then
      annotate(bufline, 'draft:', draft.message, 'GerritDraft', '▌')
    end
  end
end

--- Redraw every open diff buffer showing a change, after its drafts changed.
---@param key string
M.redraw = function(key)
  for buf, st in pairs(state) do
    if not vim.api.nvim_buf_is_valid(buf) then
      state[buf] = nil
    elseif st.key == key then
      decorate(buf)
    end
  end
end

--- The change a diff buffer belongs to, if it is one of ours.
---@param buf integer
---@return gerrit.Change|nil
M.change_at = function(buf)
  local st = state[buf]
  return st and st.change
end

--- The Gerrit location the cursor currently sits on.
---@param buf integer
---@return gerrit.Loc|nil
M.loc_at_cursor = function(buf)
  local st = state[buf]
  if not st then
    return nil
  end
  return st.map[vim.api.nvim_win_get_cursor(0)[1]]
end

--- The lines the user selected, or the cursor line outside visual mode.
---@return integer first, integer last
local function selected_lines()
  local mode = vim.fn.mode()
  if mode == 'v' or mode == 'V' or mode == '\22' then
    local a, b = vim.fn.line 'v', vim.fn.line '.'
    -- Leave visual mode now, with "x", so the escape cannot leak into the
    -- comment window we are about to open.
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
    if a > b then
      a, b = b, a
    end
    return a, b
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return line, line
end

--- Draft a comment on the cursor line, or on the selection.
---@param buf integer
local function comment(buf)
  local st = state[buf]
  local first, last = selected_lines()

  local from = st.map[first]
  if not from then
    util.warn 'nothing to comment on here'
    return
  end

  -- A selection only makes sense while it stays on one side of one file.
  local to = from
  for line = first + 1, last do
    local loc = st.map[line]
    if loc and loc.file == from.file and loc.side == from.side and loc.line then
      to = loc
    end
  end

  local range
  if from.line and to.line and to.line > from.line then
    range = {
      start_line = from.line,
      start_character = 0,
      end_line = to.line,
      end_character = #to.text,
    }
  end

  local existing = comments.find(st.key, from.file, from.side, from.line)
  local where = from.line and (':' .. from.line) or ' (whole file)'

  ui.editor({
    title = ('Comment on %s%s'):format(from.file, where),
    footer = ('%s save   %s cancel'):format(config.options.keys.review.publish, config.options.keys.review.quit),
    lines = existing and vim.split(existing.message, '\n', { plain = true }) or { '' },
    accept = config.options.keys.review.publish,
    cancel = config.options.keys.review.quit,
    height = 0.3,
    insert = not existing,
  }, function(lines)
    local message = table.concat(util.strip_blank(lines), '\n')
    if message == '' then
      comments.remove(st.key, from.file, from.side, from.line)
    else
      comments.add(st.key, {
        file = from.file,
        side = from.side,
        line = from.line,
        range = range,
        message = message,
      })
    end
    M.redraw(st.key)
  end)
end

--- Drop the draft under the cursor.
---@param buf integer
local function delete(buf)
  local st = state[buf]
  local loc = M.loc_at_cursor(buf)
  if not loc then
    return
  end

  if comments.remove(st.key, loc.file, loc.side, loc.line) then
    M.redraw(st.key)
    util.info 'draft comment dropped'
  else
    util.warn 'no draft comment here'
  end
end

--- Jump to the next or previous annotated line.
---@param buf integer
---@param forward boolean
local function navigate(buf, forward)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})
  if #marks == 0 then
    util.info 'no comments in this diff'
    return
  end

  local lines = {}
  for _, mark in ipairs(marks) do
    table.insert(lines, mark[2] + 1)
  end
  table.sort(lines)

  local current = vim.api.nvim_win_get_cursor(0)[1]
  local target
  if forward then
    for _, line in ipairs(lines) do
      if line > current then
        target = line
        break
      end
    end
    target = target or lines[1]
  else
    for i = #lines, 1, -1 do
      if lines[i] < current then
        target = lines[i]
        break
      end
    end
    target = target or lines[#lines]
  end

  vim.api.nvim_win_set_cursor(0, { target, 0 })
  vim.cmd 'normal! zz'
end

--- Open the working-tree copy of the file under the cursor.
---@param buf integer
local function edit(buf)
  local loc = M.loc_at_cursor(buf)
  if not loc then
    return
  end

  local root = git.root()
  local path = root and vim.fs.joinpath(root, loc.file) or loc.file
  if vim.fn.filereadable(path) == 0 then
    util.warn(('%s is not in the working tree'):format(loc.file))
    return
  end

  vim.cmd.edit(vim.fn.fnameescape(path))
  if loc.line then
    pcall(vim.api.nvim_win_set_cursor, 0, { loc.line, 0 })
  end
end

--- Wire up the buffer-local keys.
---@param buf integer
---@param change gerrit.Change
local function attach_keys(buf, change)
  local keys = config.options.keys.diff

  ui.map(buf, { 'n', 'x' }, keys.comment, function()
    comment(buf)
  end, 'Gerrit: draft a comment')
  ui.map(buf, 'n', keys.delete, function()
    delete(buf)
  end, 'Gerrit: drop the draft comment')
  ui.map(buf, 'n', keys.next, function()
    navigate(buf, true)
  end, 'Gerrit: next comment')
  ui.map(buf, 'n', keys.prev, function()
    navigate(buf, false)
  end, 'Gerrit: previous comment')
  ui.map(buf, 'n', keys.review, function()
    require('gerrit.review').open(change)
  end, 'Gerrit: review this change')
  ui.map(buf, 'n', keys.edit, function()
    edit(buf)
  end, 'Gerrit: open the file')
  ui.map(buf, 'n', keys.quit, function()
    vim.api.nvim_buf_delete(buf, { force = true })
  end, 'Gerrit: close')
end

--- Render the diff of a change into a buffer.
---@param change gerrit.Change
---@param lines string[] the raw unified diff
---@param opts { split: string|nil }|nil
local function render(change, lines, opts)
  local head = header(change)
  local patch_set = change.currentPatchSet or {}

  local buf = ui.scratch {
    name = ('gerrit://%s/%s/diff'):format(change.number, patch_set.number or 0),
    filetype = 'diff',
    modifiable = false,
  }

  ui.set_lines(buf, vim.list_extend(vim.deepcopy(head), lines))

  local map = parse(lines, #head)
  state[buf] = {
    change = change,
    key = query.key(change),
    map = map,
    index = build_index(map),
  }

  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = buf,
    callback = function()
      state[buf] = nil
    end,
  })

  local win = ui.open(buf, { split = opts and opts.split or 'tab' })
  vim.wo[win].wrap = false
  vim.wo[win].signcolumn = 'yes'
  vim.wo[win].number = false

  -- The header is not part of the diff; keep the diff syntax off it.
  local hl_ns = vim.api.nvim_create_namespace 'gerrit.diff.header'
  for i = 0, #head - 1 do
    vim.api.nvim_buf_set_extmark(buf, hl_ns, i, 0, {
      line_hl_group = i == 0 and 'GerritHeader' or 'GerritHint',
    })
  end

  attach_keys(buf, change)
  decorate(buf)

  return buf
end

--- Fetch a change's current patch set and show its diff.
---@param change gerrit.Change
---@param opts { split: string|nil }|nil
M.open = function(change, opts)
  local patch_set = change.currentPatchSet
  if not patch_set or not patch_set.revision or not patch_set.ref then
    util.err 'this change has no current patch set to diff'
    return
  end

  util.info(('fetching patch set %s of change %s...'):format(patch_set.number, change.number))

  git.fetch(patch_set.ref, patch_set.revision, function(ok, err)
    if not ok then
      util.err(err or 'fetch failed')
      return
    end

    git.diff(patch_set.revision, function(lines, diff_err)
      if not lines then
        util.err(diff_err or 'diff failed')
        return
      end
      if #lines == 0 then
        util.warn 'this patch set has an empty diff'
        return
      end
      render(change, lines, opts)
    end)
  end)
end

return M
