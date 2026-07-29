--- `:checkhealth gerrit`
---
--- Almost every failure in this plugin is one of three things: ssh cannot
--- reach the server, the repository has no Gerrit remote, or the server is
--- older than the API we use. This tells them apart.

local config = require 'gerrit.config'
local git = require 'gerrit.git'
local ssh = require 'gerrit.ssh'
local util = require 'gerrit.util'

local M = {}

local health = vim.health

--- Ask the server for its version, blocking briefly so the report is useful.
---@param target gerrit.Target
local function check_server(target)
  local cmd = { 'ssh' }
  vim.list_extend(cmd, config.options.ssh_args)
  if target.port then
    vim.list_extend(cmd, { '-p', tostring(target.port) })
  end
  vim.list_extend(cmd, { target.host, 'gerrit', 'version' })

  health.info('running: ' .. table.concat(cmd, ' '))

  local res = vim.system(cmd, { text = true }):wait(config.options.timeout)
  if res.code ~= 0 then
    health.error(('the server did not answer: %s'):format(util.trim(res.stderr or '')), {
      'check that you can reach the host (VPN, DNS, firewall)',
      'check that your ssh key is loaded: ssh-add -l',
      ('try it by hand: %s'):format(table.concat(cmd, ' ')),
    })
    return
  end

  local version = util.trim(res.stdout or '')
  health.ok(version ~= '' and version or 'server reachable')

  local major, minor = version:match 'gerrit version (%d+)%.(%d+)'
  if major and tonumber(major) == 2 and tonumber(minor) < 12 then
    health.warn 'inline comments need `gerrit review --json`, which arrived in Gerrit 2.12'
  end
end

M.check = function()
  health.start 'gerrit.nvim'

  for _, exe in ipairs { 'ssh', 'git' } do
    if vim.fn.executable(exe) == 1 then
      health.ok(exe .. ' found')
    else
      health.error(exe .. ' is not on $PATH')
    end
  end

  local root = git.root()
  if root then
    health.ok('git work tree: ' .. root)
  else
    health.warn('not inside a git work tree; run :checkhealth from a checkout', {
      'the project and the server are read from the git remote',
    })
  end

  local remote = git.remote()
  if remote then
    health.info(('remote %s -> %s'):format(remote.name, remote.url))
    if remote.project then
      health.ok('project: ' .. remote.project)
    else
      health.warn('no project name could be read from the remote URL')
    end
  else
    health.warn 'no git remote found'
  end

  local target, err = ssh.target()
  if not target then
    health.error(err or 'no Gerrit server', {
      "set host = 'my-gerrit' in require('gerrit').setup {}",
      'or add an ssh:// remote pointing at the Gerrit server',
    })
    return
  end

  health.ok(('server: %s%s'):format(target.host, target.port and (':' .. target.port) or ''))
  check_server(target)
end

return M
