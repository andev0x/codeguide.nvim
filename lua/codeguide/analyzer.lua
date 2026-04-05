local config = require("codeguide.config")
local contracts = require("codeguide.contracts")
local go_engine = require("codeguide.engines.go")
local lua_engine = require("codeguide.engines.lua")
local lsp = require("codeguide.lsp")

local M = {
  last_results = {},
  ticks = {},
}

local function normalize_and_store(bufnr, result, opts, tick)
  local enriched = lsp.enrich(bufnr, result, opts)
  local normalized = contracts.normalize(enriched, opts)
  M.last_results[bufnr] = normalized
  M.ticks[bufnr] = tick or vim.api.nvim_buf_get_changedtick(bufnr)
  return normalized
end

function M.analyze(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil, "Invalid buffer"
  end

  local opts = config.get()
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  if M.last_results[bufnr] and M.ticks[bufnr] == tick then
    return M.last_results[bufnr]
  end

  local filetype = vim.bo[bufnr].filetype
  local result
  local go_error

  if filetype == "go" and opts.go.enabled and not opts.go.async then
    result, go_error = go_engine.analyze(bufnr, opts)
  end

  if not result then
    result = lua_engine.analyze(bufnr, opts)
  end

  return normalize_and_store(bufnr, result, opts, tick), go_error
end

function M.analyze_async(bufnr, callback)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    callback(nil, "Invalid buffer")
    return
  end

  local opts = config.get()
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  if M.last_results[bufnr] and M.ticks[bufnr] == tick then
    callback(M.last_results[bufnr])
    return
  end

  local filetype = vim.bo[bufnr].filetype
  if filetype == "go" and opts.go.enabled and opts.go.async and go_engine.analyze_async then
    local request_tick = tick
    go_engine.analyze_async(bufnr, opts, function(result, go_error)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        callback(nil, "Invalid buffer")
        return
      end

      local now_tick = vim.api.nvim_buf_get_changedtick(bufnr)
      if now_tick ~= request_tick then
        callback(nil, "Stale analysis")
        return
      end

      if not result then
        result = lua_engine.analyze(bufnr, opts)
      end
      callback(normalize_and_store(bufnr, result, opts, request_tick), go_error)
    end)
    return
  end

  local result, err = M.analyze(bufnr)
  callback(result, err)
end

function M.last(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return M.last_results[bufnr]
end

function M.clear(bufnr)
  if bufnr then
    M.last_results[bufnr] = nil
    M.ticks[bufnr] = nil
  else
    M.last_results = {}
    M.ticks = {}
  end
end

return M
