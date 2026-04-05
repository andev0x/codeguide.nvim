local M = {}

local function ensure_list(value)
  if type(value) == "table" then
    return value
  end
  return {}
end

local function sort_by_score(items)
  table.sort(items, function(a, b)
    local left = a.score or 0
    local right = b.score or 0
    if left == right then
      return (a.line or 0) < (b.line or 0)
    end
    return left > right
  end)
end

local function sort_annotations(items)
  table.sort(items, function(a, b)
    if (a.line or 0) == (b.line or 0) then
      return (a.kind or "") < (b.kind or "")
    end
    return (a.line or 0) < (b.line or 0)
  end)
end

function M.normalize(result, opts)
  local normalized = {
    source = (result and result.source) or "unknown",
    file = (result and result.file) or "",
    entry_points = ensure_list(result and result.entry_points),
    important_functions = ensure_list(result and result.important_functions),
    execution_flow = ensure_list(result and result.execution_flow),
    annotations = ensure_list(result and result.annotations),
    function_ranges = ensure_list(result and result.function_ranges),
  }

  sort_by_score(normalized.entry_points)
  sort_by_score(normalized.important_functions)
  sort_annotations(normalized.annotations)

  local max_functions = (opts and opts.max_functions) or 6
  local max_flow_edges = (opts and opts.max_flow_edges) or 8
  local max_annotations = (opts and opts.max_annotations) or 6

  while #normalized.important_functions > max_functions do
    table.remove(normalized.important_functions)
  end

  while #normalized.execution_flow > max_flow_edges do
    table.remove(normalized.execution_flow)
  end

  while #normalized.annotations > max_annotations do
    table.remove(normalized.annotations)
  end

  for _, item in ipairs(normalized.entry_points) do
    item.file = item.file or normalized.file
  end

  for _, item in ipairs(normalized.important_functions) do
    item.file = item.file or normalized.file
  end

  for _, edge in ipairs(normalized.execution_flow) do
    edge.from_file = edge.from_file or normalized.file
    edge.to_file = edge.to_file or normalized.file
  end

  for _, item in ipairs(normalized.function_ranges) do
    item.file = item.file or normalized.file
  end

  return normalized
end

return M
