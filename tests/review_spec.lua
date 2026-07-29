-- Round trip through the review compose buffer, with no server behind it.
-- Run with: nvim --clean --headless -l tests/review_spec.lua
vim.opt.runtimepath:prepend(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))))

local failures = 0
local function check(name, ok, extra)
  if ok then
    io.write('  ok   ' .. name .. '\n')
  else
    failures = failures + 1
    io.write('  FAIL ' .. name .. (extra and ('  -> ' .. tostring(extra)) or '') .. '\n')
  end
end

require('gerrit').setup { draft_file = '/tmp/gerrit-test-drafts2.json', host = 'example', port = 29418 }
vim.fn.delete '/tmp/gerrit-test-drafts2.json'

local comments = require 'gerrit.comments'
local review = require 'gerrit.review'
local query = require 'gerrit.query'

local change = {
  project = 'tools/thing',
  branch = 'main',
  number = 4242,
  subject = 'foo: fix the leak',
  owner = { name = 'Safae Ouajih' },
  currentPatchSet = { number = 2, revision = 'deadbeef', ref = 'refs/changes/42/4242/2' },
  submitRecords = { { labels = { { label = 'Code-Review' }, { label = 'Verified' } } } },
}
local key = query.key(change)

local sent
review.publish = function(_, input, cb)
  sent = input
  cb(true, nil)
end

--- Open the compose buffer, replace its contents, and hit publish.
---@param lines string[]
local function compose(lines)
  sent = nil
  review.open(change)
  vim.wait(100)
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.cmd 'stopinsert'
  -- "m" so the buffer-local <C-s> mapping is actually looked up.
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<C-s>', true, false, true), 'mx', false)
  vim.wait(200, function()
    return sent ~= nil
  end)
end

io.write '== message and votes ==\n'
compose {
  '# Change 4242  foo: fix the leak',
  '# a dropped comment line',
  'Code-Review: +1',
  'Verified:',
  '',
  'Looks good, one nit inline.',
  '',
  'Thanks for the fix.',
  '',
}
check('published something', sent ~= nil)
check('vote captured', sent and sent.labels and sent.labels['Code-Review'] == 1, vim.inspect(sent and sent.labels))
check('empty label skipped', sent and sent.labels and sent.labels['Verified'] == nil)
check(
  'message keeps its paragraphs',
  sent and sent.message == 'Looks good, one nit inline.\n\nThanks for the fix.',
  vim.inspect(sent and sent.message)
)
check('# lines dropped', sent and not sent.message:find '#')
check('no comments when none drafted', sent and sent.comments == nil)

io.write '\n== a negative vote ==\n'
compose { 'Code-Review: -2', '', 'This breaks the ABI.' }
check('negative vote captured', sent and sent.labels['Code-Review'] == -2, vim.inspect(sent and sent.labels))

io.write '\n== prose that looks like a label ==\n'
compose { 'Code-Review: +1', '', 'Note: I did not test this.', 'Verified: not really' }
check('label after the message stays prose', sent and sent.message:find 'Verified: not really' ~= nil, vim.inspect(sent and sent.message))
check('only the real vote is sent', sent and sent.labels['Verified'] == nil and sent.labels['Code-Review'] == 1)

io.write '\n== drafts ride along ==\n'
comments.clear(key)
comments.add(key, { file = 'src/foo.c', side = 'REVISION', line = 12, message = 'off by one' })
comments.add(key, { file = 'src/foo.c', side = 'PARENT', line = 40, message = 'why drop this?' })
compose { 'Code-Review: -1', '', 'Two nits.' }
check('comments attached', sent and sent.comments and #sent.comments['src/foo.c'] == 2, vim.inspect(sent and sent.comments))
check('drafts cleared after publishing', comments.count(key) == 0, comments.count(key))

io.write '\n== an empty review is refused ==\n'
compose { '# nothing here', 'Code-Review:', '' }
check('nothing published', sent == nil)

io.write '\n== a bad vote is refused ==\n'
compose { 'Code-Review: yes', '', 'hello' }
check('nothing published', sent == nil)

io.write '\n== comments only, no message ==\n'
comments.add(key, { file = 'src/foo.c', side = 'REVISION', message = 'file level note' })
compose { 'Code-Review:', '' }
check('published on the strength of the drafts', sent ~= nil and sent.message == nil and sent.comments ~= nil, vim.inspect(sent))

io.write '\n== :Gerrit dispatch ==\n'
local opened
require('gerrit.change').show = function(c)
  opened = c
  return vim.api.nvim_create_buf(false, true)
end
query.change = function(number, cb)
  cb(vim.tbl_extend('force', change, { number = tonumber(number) }), nil)
end
vim.cmd 'Gerrit open 777'
vim.wait(200, function()
  return opened ~= nil
end)
check('subcommand routed', opened and opened.number == 777, vim.inspect(opened and opened.number))

sent = nil
vim.cmd 'Gerrit message 888 lgtm, ship it'
vim.wait(200, function()
  return sent ~= nil
end)
check('quick message posted', sent and sent.message == 'lgtm, ship it', vim.inspect(sent))

comments.clear 'tools/thing~4242'
comments.clear 'tools/thing~888'
io.write(('\n%s\n'):format(failures == 0 and 'all checks passed' or (failures .. ' checks failed')))
vim.cmd(('cquit %d'):format(failures == 0 and 0 or 1))
