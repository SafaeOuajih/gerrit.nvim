--- Talking to Gerrit over its ssh command line API.
---
--- Gerrit exposes the whole review workflow on port 29418: `gerrit query`
--- reads changes, `gerrit review` posts messages, votes and inline comments.
--- It needs no token and no extra configuration -- if `git push` to the server
--- works, so does this.

local config = require 'gerrit.config'
local git = require 'gerrit.git'
local util = require 'gerrit.util'

local M = {}

---@class gerrit.Target
---@field host string ssh destination
---@field port integer|nil
---@field project string|nil

--- Work out which server to talk to.
---
--- The configured host always wins; otherwise the git remote of the repository
--- we are in decides, which is what makes the plugin work across several
--- Gerrit servers without any per-project setup.
---@return gerrit.Target|nil target, string|nil err
M.target = function()
  local opts = config.options
  local remote = git.remote()

  local host = opts.host or (remote and remote.host)
  if not host then
    local hint = remote and ('remote %q is %s'):format(remote.name, remote.url)
      or 'this directory has no git remote'
    return nil, ('cannot tell which Gerrit server to use (%s); set `host` in setup()'):format(hint)
  end

  local port = opts.port
  if not port and (not opts.host or opts.host == (remote and remote.host)) then
    port = remote and remote.port
  end

  return { host = host, port = port, project = opts.project or (remote and remote.project) }, nil
end

--- Run a `gerrit` subcommand on the server.
---@param args string[] arguments after the `gerrit` command word
---@param opts { stdin: string|nil }|nil
---@param cb fun(ok: boolean, stdout: string, stderr: string)
M.exec = function(args, opts, cb)
  opts = opts or {}

  local target, err = M.target()
  if not target then
    cb(false, '', err or 'no Gerrit server')
    return
  end

  local cmd = { 'ssh' }
  vim.list_extend(cmd, config.options.ssh_args)
  if target.port then
    vim.list_extend(cmd, { '-p', tostring(target.port) })
  end
  table.insert(cmd, target.host)
  table.insert(cmd, 'gerrit')
  vim.list_extend(cmd, args)

  vim.system(cmd, {
    text = true,
    stdin = opts.stdin,
    timeout = config.options.timeout,
  }, vim.schedule_wrap(function(res)
    local stderr = res.stderr or ''
    if res.code ~= 0 and util.trim(stderr) == '' then
      stderr = ('ssh exited with %d'):format(res.code)
    end
    cb(res.code == 0, res.stdout or '', stderr)
  end))
end

return M
