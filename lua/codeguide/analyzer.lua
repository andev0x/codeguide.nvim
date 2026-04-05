local config = require("codeguide.config")
local contracts = require("codeguide.contracts")
local go_engine = require("codeguide.engines.go")
local lua_engine = require("codeguide.engines.lua")

local M = {
  last_results = {},
}

function M.analyze(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "Invalid buffer"
  end

  local opts = config.get()
  local filetype = vim.bo[bufnr].filetype
  local result
  local go_error

  if filetype == "go" and opts.go.enabled then
    result, go_error = go_engine.analyze(bufnr, opts)
  end

  if not result then
    result = lua_engine.analyze(bufnr, opts)
  end

  local normalized = contracts.normalize(result, opts)
  M.last_results[bufnr] = normalized

  return normalized, go_error
end

function M.last(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return M.last_results[bufnr]
end

function M.clear(bufnr)
  if bufnr then
    M.last_results[bufnr] = nil
  else
    M.last_results = {}
  end
end

return M
