-- Nothing is registered until setup() runs, so that a lazy-loaded install pays
-- nothing at startup. This file exists only to make the plugin usable when it
-- is dropped on the runtimepath without a plugin manager.
if vim.g.loaded_gerrit_nvim then
  return
end
vim.g.loaded_gerrit_nvim = true

if not vim.g.gerrit_no_default_setup then
  require('gerrit').setup {}
end
