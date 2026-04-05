local M = {}

local defaults = {
  auto_analyze = true,
  debounce_ms = 200,
  max_functions = 6,
  max_flow_edges = 8,
  max_annotations = 6,
  highlight_annotations = true,
  notify_on_error = false,
  go = {
    enabled = true,
    binary = "codeguide-go",
    timeout_ms = 1200,
  },
}

local state = vim.deepcopy(defaults)

function M.set(opts)
  state = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

function M.get()
  return state
end

function M.defaults()
  return vim.deepcopy(defaults)
end

return M
