-- Runs only when `agentmux attach` starts nvim. It sources this file with
-- --cmd, before the user's config.
if vim.g.loaded_agentmux or not vim.env.AGENTMUX_SESSION then
  return
end
vim.g.loaded_agentmux = true
require('agentmux').setup()
