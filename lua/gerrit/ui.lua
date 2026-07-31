--- Buffer and window plumbing shared by every view in the plugin.

local util = require 'gerrit.util'

local M = {}

--- Highlight groups, all linked to standard ones so they follow the theme.
local links = {
  GerritHeader = 'Title',
  GerritField = 'Identifier',
  GerritSubject = 'Statement',
  GerritApproved = 'DiagnosticOk',
  GerritRejected = 'DiagnosticError',
  GerritDraft = 'DiagnosticWarn',
  GerritDraftSign = 'DiagnosticSignWarn',
  GerritComment = 'Comment',
  GerritCommentSign = 'DiagnosticSignInfo',
  GerritHint = 'NonText',
}

M.setup_highlights = function()
  for name, target in pairs(links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
end

--- Create a throwaway buffer that is never written to disk.
---@param opts { name: string|nil, filetype: string|nil, modifiable: boolean|nil }
---@return integer buf
M.scratch = function(opts)
  local buf = vim.api.nvim_create_buf(false, true)

  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = opts.modifiable ~= false
  if opts.filetype then
    vim.bo[buf].filetype = opts.filetype
  end
  if opts.name then
    for _, other in ipairs(vim.api.nvim_list_bufs()) do
      if other ~= buf and vim.api.nvim_buf_get_name(other) == opts.name then
        pcall(vim.api.nvim_buf_delete, other, { force = true })
      end
    end
    -- Naming is a convenience, not the point of the buffer.
    pcall(vim.api.nvim_buf_set_name, buf, opts.name)
  end

  return buf
end

--- Replace a buffer's contents, taking care of the 'modifiable' dance.
---@param buf integer
---@param lines string[]
M.set_lines = function(buf, lines)
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = modifiable
  vim.bo[buf].modified = false
end

--- Show a buffer, replacing an existing window on it if there is one.
---@param buf integer
---@param opts { split: string|nil }|nil `split` is one of tab, vsplit, split
---@return integer win
M.open = function(buf, opts)
  opts = opts or {}

  local existing = vim.fn.win_findbuf(buf)[1]
  if existing then
    vim.api.nvim_set_current_win(existing)
    return existing
  end

  if opts.split == 'tab' then
    vim.cmd.tabnew()
  elseif opts.split == 'vsplit' then
    vim.cmd.vsplit()
  elseif opts.split == 'split' then
    vim.cmd.split()
  end

  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  return win
end

--- Open a buffer in a centred floating window.
---@param buf integer
---@param opts { title: string|nil, footer: string|nil, width: number|nil, height: number|nil }
---@return integer win
M.float = function(buf, opts)
  opts = opts or {}

  local width = math.floor(vim.o.columns * (opts.width or 0.7))
  local height = math.floor(vim.o.lines * (opts.height or 0.4))
  width = math.max(math.min(width, vim.o.columns - 4), 20)
  height = math.max(math.min(height, vim.o.lines - 4), 5)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = opts.title and (' ' .. opts.title .. ' ') or nil,
    title_pos = 'center',
    footer = opts.footer and (' ' .. opts.footer .. ' ') or nil,
    footer_pos = opts.footer and 'center' or nil,
  })

  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  return win
end

--- Set a buffer-local mapping, tolerating a key that has been disabled by
--- setting it to false or the empty string in the config.
---@param buf integer
---@param mode string|string[]
---@param lhs string|false|nil
---@param rhs function
---@param desc string
M.map = function(buf, mode, lhs, rhs, desc)
  if not lhs or lhs == '' then
    return
  end
  vim.keymap.set(mode, lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
end

--- Open a floating scratch editor and call back with what was typed.
---
--- Used for both draft comments and the review message: anything that wants a
--- few lines of free text without the ceremony of a real file.
---@param opts { title: string, footer: string|nil, lines: string[]|nil, filetype: string|nil, accept: string, cancel: string, height: number|nil, insert: boolean|nil }
---@param on_accept fun(lines: string[])
---@param on_cancel fun()|nil
---@return integer buf, integer win
M.editor = function(opts, on_accept, on_cancel)
  local buf = M.scratch { filetype = opts.filetype or 'markdown' }
  M.set_lines(buf, opts.lines or { '' })

  local win = M.float(buf, {
    title = opts.title,
    footer = opts.footer,
    height = opts.height,
  })

  local done = false

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function accept()
    if done then
      return
    end
    done = true
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    close()
    on_accept(lines)
  end

  local function cancel()
    if done then
      return
    end
    done = true
    close()
    if on_cancel then
      on_cancel()
    end
  end

  M.map(buf, { 'n', 'i' }, opts.accept, accept, 'Accept')
  M.map(buf, 'n', opts.cancel, cancel, 'Cancel')
  M.map(buf, 'n', '<C-c>', cancel, 'Cancel')

  -- `:w` is the reflex most people reach for, so make it mean "accept".
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = buf,
    callback = accept,
  })

  if opts.insert then
    vim.cmd.startinsert()
  end

  return buf, win
end

--- Open a URL with the user's browser.
---@param url string
---@param browser string|nil
M.browse = function(url, browser)
  if browser then
    vim.system({ browser, url }, { detach = true })
    return
  end
  local ok, err = pcall(vim.ui.open, url)
  if not ok then
    util.err(('cannot open %s: %s'):format(url, err))
  end
end

return M
