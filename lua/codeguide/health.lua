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

  local ok_telescope = pcall(require, "telescope")
  if ok_telescope then
    health.ok("Telescope detected (CodeGuideTelescope available)")
  else
    health.info("Telescope not installed (optional)")
  end

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim supports asynchronous vim.system")
  else
    health.warn("Neovim < 0.10 may fallback to synchronous shell execution")
  end
end

return M
