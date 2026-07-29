# gerrit.nvim

Review Gerrit changes from Neovim: browse them, read the diff, leave inline
comments, vote, and post the review without opening the web UI.

It talks to Gerrit over ssh on port 29418. There is no token to generate and
nothing to configure: if `git push` to your Gerrit works, so does this.

## Requirements

- Neovim 0.10 or newer
- `ssh` and `git`
- A Gerrit server you can reach over ssh (2.12 or newer, for `gerrit review --json`)
- Optional: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
  for the change picker; without it `vim.ui.select` is used

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ 'SafaeOuajih/gerrit.nvim', cmd = 'Gerrit', opts = {} }
```

## Use

Everything hangs off one command.

| Command | What it does |
| --- | --- |
| `:Gerrit` | pick from the open changes of the current project |
| `:Gerrit status:merged owner:self` | pick from any Gerrit query |
| `:Gerrit mine` | your own open changes |
| `:Gerrit open 12345` | the overview of one change |
| `:Gerrit diff 12345` | its diff, ready to be commented on |
| `:Gerrit review [12345]` | compose and publish a review |
| `:Gerrit message 12345 lgtm` | post a one-line message |
| `:Gerrit drafts` | the comments you have not published yet |

Where a change number is optional, it is taken from the current buffer when
you are already looking at a change.

### The overview

`:Gerrit` opens a picker; choosing a change shows its subject, owner, branch,
current votes, file list, commit message and the discussion so far.

| Key | Action |
| --- | --- |
| `<CR>` | open the diff |
| `R` | review this change |
| `gx` | open it in a browser |
| `r` | refresh |
| `q` | close |

### The diff

The patch set is fetched with `git fetch` and shown as a unified diff. Every
line knows which file and line number it maps to on Gerrit's side, so a comment
lands where you put the cursor.

| Key | Action |
| --- | --- |
| `c` | comment on the cursor line, or on the visual selection |
| `X` | drop the draft comment under the cursor |
| `]c` / `[c` | jump between comments |
| `R` | review this change |
| `gf` | open the real file at this line |
| `q` | close |

Commenting on a `diff --git` header attaches the comment to the file as a
whole. Commenting on a removed line attaches it to the parent side, which is
what Gerrit does when you comment on the left-hand pane.

Comments already on the server are shown inline in grey; your unpublished
drafts are shown in the warning colour with a marker in the sign column.

### The review

`R` opens a buffer holding the labels the change uses and room for a message:

```
# Change 4242  foo: stop leaking the parser context
# tools/thing  main  patch set 2
#
# 2 draft comments will be published with this review:
#   src/foo.c:12  off by one here
#   src/foo.c:40  why was this dropped?
#
# Vote by writing a value after a label; an empty value leaves it alone.
# Everything under the labels is the message. Lines starting with # are dropped.
# <C-s> publishes, q aborts.

Code-Review: +1
Verified:

Two nits inline, otherwise this looks right to me.
```

`<C-s>` (or `:w`) sends the message, the votes and every draft comment as a
single Gerrit review. `q` throws the buffer away and keeps the drafts.

Drafts survive quitting Neovim they are mirrored to a small JSON file under
`stdpath('state')` and are dropped only once the review is published.

## Configuration

Defaults, all optional:

```lua
require('gerrit').setup {
  -- The server. Both are read from the git remote when left nil, which is
  -- what makes the plugin work across several Gerrit servers unconfigured.
  -- Set `host` to an ~/.ssh/config alias and leave `port` nil to let ssh
  -- supply the port.
  host = nil,
  port = nil,
  ssh_args = { '-o', 'BatchMode=yes' },

  remote = nil,   -- git remote to fetch patch sets from; nil tries gerrit, review, origin
  project = nil,  -- project name; nil reads it from the remote URL

  query = 'status:open',   -- the default query for `:Gerrit`
  scope_to_project = true, -- narrow that query to the current project
  limit = 100,             -- most changes a query will return

  labels = { 'Code-Review', 'Verified' }, -- offered when the change lists none
  unresolved = true,                      -- publish comments as needing a reply

  timeout = 30000, -- ms before an ssh or git call is abandoned
  browser = nil,   -- command for the browse key; nil uses vim.ui.open
  draft_file = vim.fs.joinpath(vim.fn.stdpath 'state', 'gerrit-drafts.json'),

  keys = {
    change = { diff = '<CR>', review = 'R', browse = 'gx', refresh = 'r', quit = 'q' },
    diff = {
      comment = 'c',
      delete = 'X',
      next = ']c',
      prev = '[c',
      review = 'R',
      edit = 'gf',
      quit = 'q',
    },
    review = { publish = '<C-s>', quit = 'q' },
  },
}
```

Set any key to `false` to leave it unmapped.

### Several servers

Nothing needs to be configured per project. The ssh destination and the project
name come from the git remote of the repository the current buffer lives in, so
one install covers every Gerrit you work with. `host` is only needed when your
remote is an HTTPS URL, since an HTTPS remote says nothing about where ssh
should connect.

## Troubleshooting

`:checkhealth gerrit` reports which server was worked out, from which remote,
and whether it answers. The three things it usually catches:

- the host does not resolve you are off the VPN
- ssh asks for a passphrase your key is not in the agent (`ssh-add -l`)
- no remote looks like Gerrit set `host` in `setup()`

## How it works

- `gerrit query --format=JSON` lists and describes changes
- `git fetch <remote> refs/changes/NN/CHANGE/PATCHSET` brings the patch set local
- `git diff-tree --root -p` renders it
- `gerrit review --json <change>,<patchset>` publishes the message, the votes
  and the inline comments as one Gerrit `ReviewInput` on stdin

Sending the review as JSON on stdin is what makes inline comments possible over
ssh, and it sidesteps having to quote a multi-line message onto a command line.
