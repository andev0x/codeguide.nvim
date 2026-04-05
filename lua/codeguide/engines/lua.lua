local M = {}

local KEYWORDS = {
  ["if"] = true,
  ["for"] = true,
  ["while"] = true,
  ["switch"] = true,
  ["catch"] = true,
  ["return"] = true,
  ["function"] = true,
  ["local"] = true,
  ["elseif"] = true,
  ["new"] = true,
  ["print"] = true,
}

local NAME_WEIGHTS = {
  { pattern = "main", weight = 8 },
  { pattern = "start", weight = 5 },
  { pattern = "run", weight = 4 },
  { pattern = "bootstrap", weight = 5 },
  { pattern = "setup", weight = 4 },
  { pattern = "init", weight = 5 },
  { pattern = "serve", weight = 4 },
  { pattern = "handle", weight = 4 },
  { pattern = "process", weight = 3 },
}

local ENTRY_FILE_HINTS = {
  ["main"] = true,
  ["index"] = true,
  ["app"] = true,
  ["server"] = true,
}

local TS_QUERIES = {
  lua = [[
    (function_declaration name: (identifier) @name) @func
    (local_function name: (identifier) @name) @func
  ]],
  go = [[
    (function_declaration name: (identifier) @name) @func
    (method_declaration name: (field_identifier) @name) @func
  ]],
  python = [[
    (function_definition name: (identifier) @name) @func
  ]],
  javascript = [[
    (function_declaration name: (identifier) @name) @func
    (method_definition name: (property_identifier) @name) @func
    (variable_declarator name: (identifier) @name value: (arrow_function)) @func
    (variable_declarator name: (identifier) @name value: (function_expression)) @func
  ]],
  typescript = [[
    (function_declaration name: (identifier) @name) @func
    (method_definition name: (property_identifier) @name) @func
    (variable_declarator name: (identifier) @name value: (arrow_function)) @func
    (variable_declarator name: (identifier) @name value: (function_expression)) @func
  ]],
}

local function basename(path)
  return vim.fn.fnamemodify(path, ":t:r"):lower()
end

local function visibility_for(ft, name, line)
  if ft == "go" then
    local first = name:sub(1, 1)
    if first:match("%u") then
      return "public"
    end
    return "private"
  end

  if ft == "lua" then
    if line:match("^%s*local%s+function") then
      return "private"
    end
    return "public"
  end

  if line:match("%f[%a]export%f[%A]") then
    return "public"
  end

  return "private"
end

local function detect_function(ft, line)
  if ft == "lua" then
    local name = line:match("^%s*function%s+([%w_%.:]+)%s*%(")
    if not name then
      name = line:match("^%s*local%s+function%s+([%w_]+)%s*%(")
    end
    return name
  end

  if ft == "go" then
    local recv, method = line:match("^%s*func%s*%(([^)]*)%)%s*([%w_]+)%s*%(")
    if recv and method then
      return method
    end
    return line:match("^%s*func%s+([%w_]+)%s*%(")
  end

  if ft == "python" then
    return line:match("^%s*def%s+([%w_]+)%s*%(")
  end

  local name = line:match("^%s*function%s+([%w_$]+)%s*%(")
  if name then
    return name
  end

  name = line:match("^%s*export%s+function%s+([%w_$]+)%s*%(")
  if name then
    return name
  end

  local variable_name = line:match("^%s*const%s+([%w_$]+)%s*=%s*function%s*%(")
    or line:match("^%s*let%s+([%w_$]+)%s*=%s*function%s*%(")
    or line:match("^%s*var%s+([%w_$]+)%s*=%s*function%s*%(")
    or line:match("^%s*const%s+([%w_$]+)%s*=%s*%([^)]*%)%s*=>")
    or line:match("^%s*let%s+([%w_$]+)%s*=%s*%([^)]*%)%s*=>")
    or line:match("^%s*var%s+([%w_$]+)%s*=%s*%([^)]*%)%s*=>")

  return variable_name
end

local function collect_functions_regex(ft, lines)
  local functions = {}

  for index, line in ipairs(lines) do
    local name = detect_function(ft, line)
    if name then
      functions[#functions + 1] = {
        name = name,
        line = index,
        visibility = visibility_for(ft, name, line),
        score = 0,
      }
    end
  end

  for i, fn in ipairs(functions) do
    local next_fn = functions[i + 1]
    fn.end_line = next_fn and (next_fn.line - 1) or #lines
  end

  return functions
end

local function collect_functions_treesitter(bufnr, ft, lines)
  local query_text = TS_QUERIES[ft]
  if not query_text then
    return {}
  end

  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, ft)
  if not ok_parser or not parser then
    return {}
  end

  local trees = parser:parse()
  if not trees or not trees[1] then
    return {}
  end

  local ok_query, query = pcall(vim.treesitter.query.parse, ft, query_text)
  if not ok_query or not query then
    return {}
  end

  local root = trees[1]:root()
  local functions = {}
  local seen = {}

  local function unwrap_capture(node)
    if type(node) == "table" then
      return node[1]
    end
    return node
  end

  for _, match in query:iter_matches(root, bufnr, 0, -1) do
    local name_node
    local func_node

    for id, node in pairs(match) do
      node = unwrap_capture(node)
      local capture = query.captures[id]
      if capture == "name" then
        name_node = node
      elseif capture == "func" then
        func_node = node
      end
    end

    if name_node and func_node then
      local ok_name, name = pcall(vim.treesitter.get_node_text, name_node, bufnr)
      local ok_range, row_start, _, row_end, _ = pcall(func_node.range, func_node)

      if ok_name and ok_range and type(name) == "string" and name ~= "" then
        local line = row_start + 1
        local key = name .. ":" .. tostring(line)
        if not seen[key] then
          seen[key] = true
          functions[#functions + 1] = {
            name = name,
            line = line,
            end_line = math.max(row_end + 1, line),
            visibility = visibility_for(ft, name, lines[line] or ""),
            score = 0,
          }
        end
      end
    end
  end

  return functions
end

local function collect_functions(bufnr, ft, lines)
  local ts_functions = collect_functions_treesitter(bufnr, ft, lines)
  if #ts_functions > 0 then
    table.sort(ts_functions, function(a, b)
      return a.line < b.line
    end)
    return ts_functions
  end

  return collect_functions_regex(ft, lines)
end

local function collect_annotations(lines)
  local annotations = {}

  for i, line in ipairs(lines) do
    local upper = line:upper()
    local kind
    if upper:find("TODO", 1, true) then
      kind = "TODO"
    elseif upper:find("FIXME", 1, true) then
      kind = "FIXME"
    end

    if kind then
      annotations[#annotations + 1] = {
        kind = kind,
        line = i,
        text = vim.trim(line),
      }
    end
  end

  return annotations
end

local function function_map(functions)
  local map = {}
  for _, fn in ipairs(functions) do
    map[fn.name] = fn
  end
  return map
end

local function collect_edges(lines, functions)
  local edges = {}
  local seen = {}
  local by_name = function_map(functions)
  local outgoing = {}
  local incoming = {}

  for _, fn in ipairs(functions) do
    outgoing[fn.name] = 0
    incoming[fn.name] = 0
  end

  for _, fn in ipairs(functions) do
    for line_nr = fn.line, fn.end_line do
      local content = lines[line_nr]
      if content then
        for callee in content:gmatch("([%a_][%w_]*)%s*%(") do
          if not KEYWORDS[callee] and by_name[callee] and callee ~= fn.name then
            local key = fn.name .. "->" .. callee
            if not seen[key] then
              seen[key] = true
              edges[#edges + 1] = {
                from = fn.name,
                to = callee,
                line = line_nr,
              }
              outgoing[fn.name] = outgoing[fn.name] + 1
              incoming[callee] = incoming[callee] + 1
            end
          end
        end
      end
    end
  end

  return edges, outgoing, incoming
end

local function score_name(name)
  local lower = name:lower()
  local score = 0
  for _, item in ipairs(NAME_WEIGHTS) do
    if lower:find(item.pattern, 1, true) then
      score = score + item.weight
    end
  end
  return score
end

local function choose_entry_points(file_path, functions)
  local file_hint = basename(file_path)
  local entries = {}

  for _, fn in ipairs(functions) do
    local score = score_name(fn.name)
    if ENTRY_FILE_HINTS[file_hint] and fn.line <= 120 then
      score = score + 2
    end
    if fn.name == "main" then
      score = score + 4
    end
    if score > 0 then
      entries[#entries + 1] = {
        name = fn.name,
        line = fn.line,
        score = score,
        reason = "entry-like naming",
      }
    end
  end

  table.sort(entries, function(a, b)
    if a.score == b.score then
      return a.line < b.line
    end
    return a.score > b.score
  end)

  if #entries == 0 and functions[1] then
    entries[1] = {
      name = functions[1].name,
      line = functions[1].line,
      score = 1,
      reason = "first function in file",
    }
  end

  while #entries > 3 do
    table.remove(entries)
  end

  return entries
end

local function line_distance_to_entry(fn, entries)
  local best
  for _, entry in ipairs(entries) do
    local distance = math.abs((entry.line or 0) - (fn.line or 0))
    if not best or distance < best then
      best = distance
    end
  end
  return best or 99999
end

local function rank_functions(functions, entries, outgoing, incoming, max_functions)
  local entry_names = {}
  for _, entry in ipairs(entries) do
    entry_names[entry.name] = true
  end

  local ranked = {}
  for _, fn in ipairs(functions) do
    local score = score_name(fn.name)

    if fn.visibility == "public" then
      score = score + 2
    end

    if entry_names[fn.name] then
      score = score + 5
    end

    score = score + math.min(outgoing[fn.name] or 0, 3)
    score = score + math.min(incoming[fn.name] or 0, 2)

    local distance = line_distance_to_entry(fn, entries)
    if distance <= 20 then
      score = score + 3
    elseif distance <= 60 then
      score = score + 2
    elseif distance <= 120 then
      score = score + 1
    end

    ranked[#ranked + 1] = {
      name = fn.name,
      line = fn.line,
      score = score,
      visibility = fn.visibility,
    }
  end

  table.sort(ranked, function(a, b)
    if a.score == b.score then
      return a.line < b.line
    end
    return a.score > b.score
  end)

  while #ranked > max_functions do
    table.remove(ranked)
  end

  return ranked
end

local function select_flow(entries, ranked, edges, max_edges)
  local interesting = {}
  for _, item in ipairs(entries) do
    interesting[item.name] = true
  end
  for _, item in ipairs(ranked) do
    interesting[item.name] = true
  end

  local filtered = {}
  for _, edge in ipairs(edges) do
    if interesting[edge.from] or interesting[edge.to] then
      filtered[#filtered + 1] = edge
    end
  end

  if #filtered == 0 then
    filtered = edges
  end

  while #filtered > max_edges do
    table.remove(filtered)
  end

  return filtered
end

function M.analyze(bufnr, opts)
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.bo[bufnr].filetype
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local functions = collect_functions(bufnr, filetype, lines)
  local annotations = collect_annotations(lines)
  local edges, outgoing, incoming = collect_edges(lines, functions)
  local entries = choose_entry_points(file_path, functions)
  local ranked = rank_functions(functions, entries, outgoing, incoming, opts.max_functions)
  local flow = select_flow(entries, ranked, edges, opts.max_flow_edges)

  return {
    source = "lua-fallback",
    file = file_path,
    entry_points = entries,
    important_functions = ranked,
    execution_flow = flow,
    annotations = annotations,
  }
end

return M
