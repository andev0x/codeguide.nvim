local M = {}

function M.check()
  local ok_health, health = pcall(require, "vim.health")
  if not ok_health then
    health = require("health")
  end

  health.start("codeguide.nvim")

  if vim.fn.has("nvim-0.9") == 1 then
    health.ok("Neovim version is supported")
  else
    health.error("Neovim 0.9 or newer is required")
  end

  local binary = require("codeguide.config").get().go.binary
  if vim.fn.executable(binary) == 1 then
    health.ok("Go engine found: " .. binary)
  else
    health.warn("Go engine not found. Fallback Lua engine will be used.")
  end
end

return M
