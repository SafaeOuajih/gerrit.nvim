--- Reading changes out of Gerrit with `gerrit query`.
---
--- The server answers in "JSON lines": one object per change, then a final
--- bookkeeping row giving the row count. Errors arrive the same way, as a row
--- whose `type` is `error`, so a query can succeed at the ssh level and still
--- have failed.

local config = require 'gerrit.config'
local ssh = require 'gerrit.ssh'
local util = require 'gerrit.util'

local M = {}

--- Enough to render a change in a list.
local LIST_FLAGS = { '--current-patch-set' }

--- Everything needed to review a change: the commit message, the file list,
--- who voted what, and both the change messages and the inline comments.
local DETAIL_FLAGS = {
  '--current-patch-set',
  '--all-reviewers',
  '--comments',
  '--commit-message',
  '--files',
  '--submit-records',
}

---@class gerrit.Approval
---@field type string label name
---@field description string|nil
---@field value string signed value, as a string
---@field grantedOn integer|nil
---@field by table|nil

---@class gerrit.InlineComment
---@field file string
---@field line integer|nil
---@field reviewer table|nil
---@field message string

---@class gerrit.PatchSet
---@field number integer|string
---@field revision string commit hash
---@field ref string `refs/changes/...`
---@field uploader table|nil
---@field approvals gerrit.Approval[]|nil
---@field files table[]|nil
---@field comments gerrit.InlineComment[]|nil

---@class gerrit.Change
---@field project string
---@field branch string
---@field topic string|nil
---@field id string the Change-Id
---@field number integer
---@field subject string
---@field owner table
---@field url string
---@field commitMessage string|nil
---@field createdOn integer
---@field lastUpdated integer
---@field open boolean
---@field status string
---@field currentPatchSet gerrit.PatchSet|nil
---@field comments table[]|nil change messages
---@field allReviewers table[]|nil
---@field submitRecords table[]|nil

--- Stable identifier for a change, used to file draft comments under.
---@param change gerrit.Change
---@return string
M.key = function(change)
  return ('%s~%s'):format(change.project or '?', change.number)
end

--- Turn the raw JSON-lines output into a list of changes.
---@param stdout string
---@return gerrit.Change[]|nil changes, string|nil err
local function decode(stdout)
  local changes = {}

  for _, line in ipairs(util.lines(stdout)) do
    local ok, row = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(row) == 'table' then
      if row.type == 'error' then
        return nil, row.message or 'query rejected by the server'
      elseif not row.type and row.number then
        row.number = tonumber(row.number) or row.number
        table.insert(changes, row)
      end
    end
  end

  return changes, nil
end

--- Run a query and hand back the changes it matched.
---@param query string a Gerrit query, e.g. `status:open owner:self`
---@param flags string[]|nil query flags, defaults to `LIST_FLAGS`
---@param cb fun(changes: gerrit.Change[]|nil, err: string|nil)
M.run = function(query, flags, cb)
  local args = { 'query', '--format=JSON' }
  vim.list_extend(args, flags or LIST_FLAGS)

  if not query:match 'limit:%d' then
    query = query .. (' limit:%d'):format(config.options.limit)
  end

  -- The query goes over as a single argument. ssh joins its arguments with
  -- spaces anyway, so splitting here would gain nothing and would break any
  -- quoting the user wrote, such as `message:"fix the thing"`.
  table.insert(args, util.trim(query))

  ssh.exec(args, nil, function(ok, stdout, stderr)
    if not ok then
      cb(nil, util.trim(stderr))
      return
    end
    cb(decode(stdout))
  end)
end

--- Restrict a query to the changes somebody has touched recently.
---
--- `status:open` on a long lived project matches everything anyone ever left
--- hanging, and the server has to walk all of it before we see a single row.
--- Asking only for the last couple of weeks is what makes `:Gerrit` come back
--- straight away; `max_age = nil` gives the old, exhaustive behaviour back.
---
--- Written as `NOT age:2w` rather than the `-age:2w` you would type in the web
--- UI: ssh passes the query over as plain arguments, so a word starting with a
--- dash is taken for a command line option long before the query parser gets a
--- look at it.
---@param query string
---@return string
M.recent = function(query)
  local window = config.options.max_age
  if not window or window == '' then
    return query
  end

  -- The frontier stops `message:` from looking like an age contraint, since it
  -- happens to end in "age:" as well.
  if query:match '%f[%a]age:' then
    return query
  end

  return ('%s NOT age:%s'):format(util.trim(query), window)
end

--- The default query for `:Gerrit`, narrowed to the current project when the
--- remote tells us what it is, and to the recent past.
---@return string
M.default_query = function()
  local opts = config.options
  local query = opts.query

  if opts.scope_to_project then
    local target = ssh.target()
    local project = target and target.project
    if project and not query:match 'project:' then
      query = ('project:%s %s'):format(util.quote(project), query)
    end
  end

  return M.recent(query)
end

--- Fetch one change, with everything needed to review it.
---@param number integer|string
---@param cb fun(change: gerrit.Change|nil, err: string|nil)
M.change = function(number, cb)
  M.run(('change:%s'):format(number), DETAIL_FLAGS, function(changes, err)
    if err then
      cb(nil, err)
      return
    end
    if not changes or #changes == 0 then
      cb(nil, ('no change numbered %s'):format(number))
      return
    end
    cb(changes[1], nil)
  end)
end

--- Label names this change actually uses, falling back to the configured list.
---@param change gerrit.Change
---@return string[]
M.labels = function(change)
  local seen, labels = {}, {}

  local function add(name)
    if name and not seen[name] then
      seen[name] = true
      table.insert(labels, name)
    end
  end

  for _, record in ipairs(change.submitRecords or {}) do
    for _, label in ipairs(record.labels or {}) do
      add(label.label)
    end
  end
  for _, approval in ipairs(util.get(change, 'currentPatchSet', 'approvals') or {}) do
    add(approval.type)
  end

  if #labels == 0 then
    for _, name in ipairs(config.options.labels) do
      add(name)
    end
  end

  return labels
end

return M
