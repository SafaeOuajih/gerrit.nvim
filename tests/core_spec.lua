-- Offline exercise of gerrit.nvim: no server, no network.
-- Run with: nvim --clean --headless -l tests/core_spec.lua
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

io.write '== load every module ==\n'
for _, mod in ipairs {
  'gerrit',
  'gerrit.util',
  'gerrit.config',
  'gerrit.git',
  'gerrit.ssh',
  'gerrit.query',
  'gerrit.ui',
  'gerrit.comments',
  'gerrit.diff',
  'gerrit.review',
  'gerrit.change',
  'gerrit.picker',
  'gerrit.health',
} do
  local ok, err = pcall(require, mod)
  check(mod, ok, err)
end

local util = require 'gerrit.util'
local git = require 'gerrit.git'
local diff = require 'gerrit.diff'
local comments = require 'gerrit.comments'

-- Keep drafts out of the real state directory.
require('gerrit').setup { draft_file = '/tmp/gerrit-test-drafts.json', host = 'example', port = 29418 }
vim.fn.delete '/tmp/gerrit-test-drafts.json'

io.write '\n== remote URL parsing ==\n'
local cases = {
  { 'ssh://jdoe@gerrit.example.com:29418/tools/thing', 'jdoe@gerrit.example.com', 29418, 'tools/thing' },
  { 'ssh://host/project.git', 'host', nil, 'project' },
  { 'https://gerrit.example.com/a/foo/bar', nil, nil, 'foo/bar' },
  { 'git@github.com:me/repo.git', 'git@github.com', nil, 'me/repo' },
}
for _, case in ipairs(cases) do
  local host, port, project = git.parse_url(case[1])
  check(case[1], host == case[2] and port == case[3] and project == case[4], vim.inspect { host, port, project })
end

io.write '\n== quoting ==\n'
check('plain stays plain', util.quote 'status:open' == 'status:open')
check('spaces get quoted', util.quote 'a b' == '"a b"', util.quote 'a b')
check('quotes get escaped', util.quote 'say "hi"' == '"say \\"hi\\""', util.quote 'say "hi"')

io.write '\n== diff parsing ==\n'
local sample = vim.split(
  table.concat({
    'diff --git a/src/foo.c b/src/foo.c',
    'index 1111111..2222222 100644',
    '--- a/src/foo.c',
    '+++ b/src/foo.c',
    '@@ -10,6 +10,7 @@ static int old(void)',
    ' context one',
    ' context two',
    '-removed line',
    '+added line',
    '+second added',
    ' context three',
    '@@ -40 +41,2 @@',
    '+tail',
    'diff --git a/new.txt b/new.txt',
    'new file mode 100644',
    '--- /dev/null',
    '+++ b/new.txt',
    '@@ -0,0 +1,2 @@',
    '+hello',
    '+world',
  }, '\n'),
  '\n'
)

local map = diff.parse(sample, 0)
check('file header is a file comment', map[1] and map[1].file == 'src/foo.c' and map[1].line == nil, vim.inspect(map[1]))
check('index line is not commentable', map[2] == nil)
check('first context is new line 10', map[6] and map[6].line == 10 and map[6].side == 'REVISION', vim.inspect(map[6]))
check('second context is new line 11', map[7] and map[7].line == 11, vim.inspect(map[7]))
check(
  'removed line is old 12 on PARENT',
  map[8] and map[8].line == 12 and map[8].side == 'PARENT' and map[8].file == 'src/foo.c',
  vim.inspect(map[8])
)
check('added line is new 12 on REVISION', map[9] and map[9].line == 12 and map[9].side == 'REVISION', vim.inspect(map[9]))
check('second added line is new 13', map[10] and map[10].line == 13, vim.inspect(map[10]))
check('context after the edit is new 14', map[11] and map[11].line == 14, vim.inspect(map[11]))
check('countless hunk header parses', map[13] and map[13].line == 41, vim.inspect(map[13]))
check('second file header', map[14] and map[14].file == 'new.txt' and map[14].line == nil, vim.inspect(map[14]))
check('new file first line', map[19] and map[19].file == 'new.txt' and map[19].line == 1, vim.inspect(map[19]))
check('new file second line', map[20] and map[20].line == 2, vim.inspect(map[20]))
check('offset shifts everything', diff.parse(sample, 4)[5] ~= nil and diff.parse(sample, 4)[1] == nil)

io.write '\n== draft comments ==\n'
comments.clear 'p~1'
comments.add('p~1', { file = 'src/foo.c', side = 'REVISION', line = 12, message = 'this leaks' })
comments.add('p~1', { file = 'src/foo.c', side = 'PARENT', line = 12, message = 'why was this removed?' })
comments.add('p~1', { file = 'new.txt', side = 'REVISION', message = 'needs a licence header' })
check('three drafts held', comments.count 'p~1' == 3, comments.count 'p~1')
check('sides do not collide', comments.find('p~1', 'src/foo.c', 'PARENT', 12).message == 'why was this removed?')

comments.add('p~1', { file = 'src/foo.c', side = 'REVISION', line = 12, message = 'rewritten' })
check('re-commenting replaces', comments.count 'p~1' == 3 and comments.find('p~1', 'src/foo.c', 'REVISION', 12).message == 'rewritten')

local input = comments.to_input 'p~1'
check('grouped by file', input['src/foo.c'] and #input['src/foo.c'] == 2 and #input['new.txt'] == 1, vim.inspect(input))
check('file comment carries no line', input['new.txt'][1].line == nil)
check('marked unresolved', input['src/foo.c'][1].unresolved == true)

local encoded = vim.json.encode { comments = input, message = 'lgtm', labels = { ['Code-Review'] = 1 } }
check('encodes to a JSON object', encoded:sub(1, 1) == '{')
check('paths are object keys', encoded:find '"src/foo.c":%[' ~= nil, encoded)
local decoded = vim.json.decode(encoded)
check('round trips', decoded.labels['Code-Review'] == 1 and #decoded.comments['src/foo.c'] == 2)

io.write '\n== persistence ==\n'
check('drafts hit the disk', vim.fn.filereadable '/tmp/gerrit-test-drafts.json' == 1)
check('pending lists the change', #comments.pending() == 1 and comments.pending()[1].key == 'p~1')
comments.clear 'p~1'
check('clearing removes the file', vim.fn.filereadable '/tmp/gerrit-test-drafts.json' == 0)

io.write '\n== rendering a change ==\n'
local change = {
  project = 'tools/thing',
  branch = 'main',
  topic = 'cleanup',
  id = 'I1234',
  number = 4242,
  subject = 'foo: stop leaking the parser context',
  owner = { name = 'Safae Ouajih', email = 'ouajih.safae@gmail.com' },
  url = 'https://gerrit.example.com/c/tools/thing/+/4242',
  commitMessage = 'foo: stop leaking the parser context\n\nThe context was never freed on the error path.\n\nChange-Id: I1234\n',
  createdOn = os.time() - 86400,
  lastUpdated = os.time() - 3600,
  open = true,
  status = 'NEW',
  currentPatchSet = {
    number = 2,
    revision = 'deadbeef',
    ref = 'refs/changes/42/4242/2',
    approvals = {
      { type = 'Code-Review', value = '2', by = { name = 'Alice' } },
      { type = 'Verified', value = '-1', by = { name = 'CI' } },
    },
    files = {
      { file = '/COMMIT_MSG', type = 'ADDED', insertions = 9, deletions = 0 },
      { file = 'src/foo.c', type = 'MODIFIED', insertions = 12, deletions = -3 },
    },
    comments = {
      { file = 'src/foo.c', line = 12, reviewer = { name = 'Alice' }, message = 'nice catch' },
    },
  },
  comments = {
    { timestamp = os.time() - 7200, reviewer = { name = 'Alice' }, message = 'Patch Set 2: Code-Review+2' },
  },
  submitRecords = { { labels = { { label = 'Code-Review' }, { label = 'Verified' } } } },
}

local change_view = require 'gerrit.change'
local lines, hls = change_view.render(change)
check('renders something', #lines > 10, #lines)
check('has the subject', vim.tbl_contains(lines, change.subject))
check('has highlights', #hls > 0)
check('skips /COMMIT_MSG in the file list', not table.concat(lines, '\n'):find '/COMMIT_MSG')
check('shows the votes', table.concat(lines, '\n'):find 'Code%-Review%s+%+2' ~= nil)
check('shows a negative vote', table.concat(lines, '\n'):find 'Verified%s+%-1' ~= nil)

check('labels come from the change', vim.deep_equal(require('gerrit.query').labels(change), { 'Code-Review', 'Verified' }))

io.write '\n== opening the diff without a server ==\n'
git.fetch = function(_, _, cb)
  cb(true, nil)
end
git.diff = function(_, cb)
  cb(sample, nil)
end

diff.open(change, { split = 'tab' })
vim.wait(500, function()
  return vim.bo.filetype == 'diff'
end)

local buf = vim.api.nvim_get_current_buf()
check('diff buffer opened', vim.bo[buf].filetype == 'diff', vim.bo[buf].filetype)
check('named after the change', vim.api.nvim_buf_get_name(buf):find 'gerrit://4242/2/diff' ~= nil, vim.api.nvim_buf_get_name(buf))
check('read only', vim.bo[buf].modifiable == false)

local body = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
check('header sits on top', body[1]:find 'Change 4242' ~= nil, body[1])
check('diff follows the header', body[5] == 'diff --git a/src/foo.c b/src/foo.c', body[5])

vim.api.nvim_win_set_cursor(0, { 13, 0 })
local loc = diff.loc_at_cursor(buf)
check('cursor maps through the header offset', loc and loc.line == 12 and loc.side == 'REVISION', vim.inspect(loc))

check('published comment is drawn', #vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace 'gerrit.diff', 0, -1, {}) == 1)

comments.add('tools/thing~4242', { file = 'src/foo.c', side = 'REVISION', line = 12, message = 'still leaking' })
diff.redraw 'tools/thing~4242'
check('draft is drawn too', #vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_create_namespace 'gerrit.diff', 0, -1, {}) == 2)
comments.clear 'tools/thing~4242'

io.write '\n== the change buffer ==\n'
local change_buf = change_view.show(change, { split = 'tab' })
check('change buffer opened', vim.api.nvim_buf_is_valid(change_buf))
check('read only', vim.bo[change_buf].modifiable == false)
local maps = vim.api.nvim_buf_get_keymap(change_buf, 'n')
local lhs = vim.tbl_map(function(m)
  return m.lhs
end, maps)
check('keys are attached', vim.tbl_contains(lhs, 'R') and vim.tbl_contains(lhs, 'q'), vim.inspect(lhs))

io.write '\n== the review buffer ==\n'
local sent
require('gerrit.review').publish = function(_, input, cb)
  sent = input
  cb(true, nil)
end
require('gerrit.review').open(change)
vim.wait(200)
local review_buf = vim.api.nvim_get_current_buf()
local review_lines = vim.api.nvim_buf_get_lines(review_buf, 0, -1, false)
check('template mentions the change', review_lines[1]:find 'Change 4242' ~= nil, review_lines[1])
check('offers both labels', vim.tbl_contains(review_lines, 'Code-Review:') and vim.tbl_contains(review_lines, 'Verified:'))

io.write '\n== the command ==\n'
check('command exists', vim.fn.exists ':Gerrit' == 2)

io.write(('\n%s\n'):format(failures == 0 and 'all checks passed' or (failures .. ' checks failed')))
vim.cmd(('cquit %d'):format(failures == 0 and 0 or 1))
