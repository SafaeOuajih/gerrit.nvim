--- The git half of the plugin: locating the Gerrit server from a remote, and
--- fetching and diffing patch sets.
---
--- Patch sets are ordinary commits living under `refs/changes/`, so reviewing
--- one is a `git fetch` away. Gerrit already tells us the commit hash of every
--- patch set, which means we never have to read `FETCH_HEAD` back and race
--- against another fetch: we fetch the ref, then address the commit by hash.

local config = require 'gerrit.config'
local util = require 'gerrit.util'

local M = {}

--- Directory git commands run in: the current buffer's, falling back to `cwd`.
---@return string
M.cwd = function()
  local file = vim.api.nvim_buf_get_name(0)
  if file ~= '' and vim.bo.buftype == '' then
    local dir = vim.fs.dirname(file)
    if vim.fn.isdirectory(dir) == 1 then
      return dir
    end
  end
  return vim.fn.getcwd()
end

--- Run git, without ever letting it stop for a password prompt.
---@param args string[]
---@param opts { cwd: string|nil }|nil
---@param cb fun(ok: boolean, stdout: string, stderr: string)
M.exec = function(args, opts, cb)
  opts = opts or {}
  local cmd = vim.list_extend({ 'git' }, args)

  vim.system(cmd, {
    cwd = opts.cwd or M.cwd(),
    text = true,
    timeout = config.options.timeout,
    env = {
      GIT_TERMINAL_PROMPT = '0',
      -- Keep whatever ssh command the user already relies on, but never let it
      -- block the editor on a passphrase prompt nobody can answer.
      GIT_SSH_COMMAND = (vim.env.GIT_SSH_COMMAND or 'ssh') .. ' -o BatchMode=yes',
    },
  }, vim.schedule_wrap(function(res)
    cb(res.code == 0, res.stdout or '', res.stderr or '')
  end))
end

--- Same as `exec`, but blocking. Used for the cheap, instant queries that the
--- rest of the module needs before it can do anything at all.
---@param args string[]
---@param cwd string|nil
---@return string|nil stdout nil when git failed
local function exec_sync(args, cwd)
  local res = vim
    .system(vim.list_extend({ 'git' }, args), {
      cwd = cwd or M.cwd(),
      text = true,
      env = { GIT_TERMINAL_PROMPT = '0' },
    })
    :wait(5000)
  if res.code ~= 0 then
    return nil
  end
  return util.trim(res.stdout or '')
end

--- Absolute path of the work tree we are in.
---@param cwd string|nil
---@return string|nil
M.root = function(cwd)
  local root = exec_sync({ 'rev-parse', '--show-toplevel' }, cwd)
  if root == '' then
    return nil
  end
  return root
end

---@class gerrit.Remote
---@field name string git remote name
---@field url string the remote URL as configured
---@field host string|nil ssh destination, `user@host` or a bare host
---@field port integer|nil ssh port
---@field project string|nil Gerrit project name

--- Pull the ssh destination and project out of a remote URL.
---@param url string
---@return string|nil host, integer|nil port, string|nil project
local function parse_url(url)
  local project

  -- ssh://user@host:29418/project
  local authority, path = url:match '^ssh://([^/]+)/(.*)$'
  if authority then
    project = path:gsub('%.git$', '')
    local host, port = authority:match '^(.*):(%d+)$'
    if host then
      return host, tonumber(port), project
    end
    return authority, nil, project
  end

  -- https://host/a/project -- usable for the project name only, since there is
  -- no ssh destination hiding in an HTTPS URL.
  path = url:match '^https?://[^/]+/(.*)$'
  if path then
    project = path:gsub('^a/', ''):gsub('%.git$', '')
    return nil, nil, project
  end

  -- user@host:project, the scp-like form
  local host, scp_path = url:match '^([^/]+):(.+)$'
  if host and not host:match '^%a+$' then
    return host, nil, (scp_path:gsub('%.git$', ''))
  end

  return nil, nil, nil
end

M.parse_url = parse_url

---@type table<string, gerrit.Remote|false>
local cache = {}

---@type fun(cwd: string|nil): gerrit.Remote|nil
local detect_remote

--- Find the remote that points at Gerrit.
---
--- A repository cloned by `repo` or by `git clone` from Gerrit usually has a
--- single remote, but a manually configured one often keeps `origin` for a
--- mirror and adds `gerrit` for review. Preference goes to an explicit
--- configuration, then to a remote named `gerrit`, then to whichever remote
--- looks like a Gerrit ssh URL.
---@param cwd string|nil
---@return gerrit.Remote|nil
M.remote = function(cwd)
  local key = cwd or M.cwd()

  local cached = cache[key]
  if cached ~= nil then
    return cached or nil
  end

  local remote = detect_remote(cwd)
  -- A miss is remembered too: repeating four failing git calls every time a
  -- query is built is worse than a slightly stale answer.
  cache[key] = remote or false
  return remote
end

--- Forget what we learned about a directory, after a remote may have changed.
M.forget = function()
  cache = {}
end

---@param cwd string|nil
---@return gerrit.Remote|nil
function detect_remote(cwd)
  local opts = config.options
  local names = util.lines(exec_sync({ 'remote' }, cwd))
  if #names == 0 then
    return nil
  end

  local wanted = {}
  if opts.remote then
    wanted = { opts.remote }
  else
    wanted = { 'gerrit', 'review', 'origin' }
    for _, name in ipairs(names) do
      table.insert(wanted, name)
    end
  end

  local fallback ---@type gerrit.Remote|nil
  for _, name in ipairs(wanted) do
    if vim.tbl_contains(names, name) then
      local url = exec_sync({ 'remote', 'get-url', name }, cwd)
      if url and url ~= '' then
        local host, port, project = parse_url(url)
        local remote = { name = name, url = url, host = host, port = port, project = project }
        -- A remote we can actually ssh to wins outright; keep anything else
        -- around in case it is all we have, since the project name is still
        -- worth having.
        if host then
          return remote
        end
        fallback = fallback or remote
      end
    end
  end

  return fallback
end

--- Whether a commit is already in the object store, so a fetch can be skipped.
---@param sha string
---@param cwd string|nil
---@return boolean
M.has_commit = function(sha, cwd)
  return exec_sync({ 'cat-file', '-e', sha .. '^{commit}' }, cwd) ~= nil
end

--- Make a patch set available locally.
---@param ref string the `refs/changes/...` ref of the patch set
---@param sha string the commit the ref points at
---@param cb fun(ok: boolean, err: string|nil)
M.fetch = function(ref, sha, cb)
  local cwd = M.cwd()
  if M.has_commit(sha, cwd) then
    cb(true, nil)
    return
  end

  local remote = M.remote(cwd)
  if not remote then
    cb(false, 'no git remote to fetch the patch set from')
    return
  end

  M.exec({ 'fetch', '--quiet', remote.name, ref }, { cwd = cwd }, function(ok, _, stderr)
    if not ok then
      cb(false, ('git fetch %s %s failed: %s'):format(remote.name, ref, util.trim(stderr)))
      return
    end
    cb(true, nil)
  end)
end

--- Produce the unified diff introduced by a commit.
---
--- `diff-tree --root` is used rather than `git show` so the output is the patch
--- and nothing else, and so that a change with no parent still produces a diff.
---@param sha string
---@param cb fun(lines: string[]|nil, err: string|nil)
M.diff = function(sha, cb)
  local args = { 'diff-tree', '--root', '--no-commit-id', '--patch', '-r', '-M', '--no-color', sha }
  M.exec(args, nil, function(ok, stdout, stderr)
    if not ok then
      cb(nil, ('git diff-tree failed: %s'):format(util.trim(stderr)))
      return
    end
    cb(util.lines(stdout), nil)
  end)
end

return M
