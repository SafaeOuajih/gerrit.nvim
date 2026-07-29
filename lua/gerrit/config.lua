--- Configuration for gerrit.nvim.
---
--- Every option has a default, and the two that matter most -- which server to
--- talk to and which project a change belongs to -- are normally read from the
--- git remote of the repository you are sitting in, so `setup {}` is usually
--- enough. Set `host` explicitly if your remote is an HTTPS URL, since there is
--- no ssh destination to be recovered from one.

local M = {}

---@class gerrit.Keys.Change
---@field diff string open the diff for this change
---@field review string open the review compose buffer
---@field browse string open the change in a web browser
---@field refresh string re-query the change
---@field quit string close the buffer

---@class gerrit.Keys.Diff
---@field comment string draft a comment on the cursor line or the selection
---@field delete string drop the draft comment under the cursor
---@field next string jump to the next comment
---@field prev string jump to the previous comment
---@field review string open the review compose buffer
---@field edit string open the real file at the cursor line
---@field quit string close the buffer

---@class gerrit.Keys.Review
---@field publish string send the review
---@field quit string discard the compose buffer

---@class gerrit.Keys
---@field change gerrit.Keys.Change
---@field diff gerrit.Keys.Diff
---@field review gerrit.Keys.Review

---@class gerrit.Config
---@field host string|nil ssh destination, an alias or `user@host`; nil detects it from the git remote
---@field port integer|nil ssh port; leave nil when `host` is an alias whose Port is set in ~/.ssh/config
---@field ssh_args string[] extra arguments passed to ssh
---@field remote string|nil git remote patch sets are fetched from; nil picks `gerrit` then `origin`
---@field project string|nil project name; nil reads it from the remote URL
---@field query string default query used by `:Gerrit`
---@field scope_to_project boolean restrict the default query to the current project
---@field limit integer maximum number of changes fetched by a query
---@field labels string[] labels offered in the review buffer when the change lists none
---@field timeout integer milliseconds before an ssh or git call is abandoned
---@field browser string|nil command used by the "browse" key; nil picks a sensible default
---@field draft_file string|nil where unpublished comments are saved; nil disables persistence
---@field unresolved boolean mark published inline comments as needing a reply
---@field keys gerrit.Keys

---@type gerrit.Config
local defaults = {
  host = nil,
  port = nil,
  ssh_args = { '-o', 'BatchMode=yes' },
  remote = nil,
  project = nil,
  query = 'status:open',
  scope_to_project = true,
  limit = 100,
  labels = { 'Code-Review', 'Verified' },
  timeout = 30000,
  browser = nil,
  draft_file = vim.fs.joinpath(vim.fn.stdpath 'state' --[[@as string]], 'gerrit-drafts.json'),
  unresolved = true,

  keys = {
    change = {
      diff = '<CR>',
      review = 'R',
      browse = 'gx',
      refresh = 'r',
      quit = 'q',
    },
    diff = {
      comment = 'c',
      delete = 'X',
      next = ']c',
      prev = '[c',
      review = 'R',
      edit = 'gf',
      quit = 'q',
    },
    review = {
      publish = '<C-s>',
      quit = 'q',
    },
  },
}

---@type gerrit.Config
M.options = vim.deepcopy(defaults)

--- Merge user options over the defaults.
---@param opts gerrit.Config|nil
M.setup = function(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
end

return M
