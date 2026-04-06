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

local SCORE_THRESHOLDS = {
  { label = "simple", min = 0, max = 5 },
  { label = "moderate", min = 6, max = 10 },
  { label = "complex", min = 11, max = 20 },
  { label = "needs-refactoring", min = 21, max = -1 },
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

local function score_band(score)
  if score <= 5 then
    return "simple"
  end
  if score <= 10 then
    return "moderate"
  end
  if score <= 20 then
    return "complex"
  end
  return "needs-refactoring"
end

local function role_assessment(role, score)
  if role == "orchestrator" then
    if score <= 20 then
      return "acceptable"
    end
    if score <= 30 then
      return "monitor"
    end
    return "should-optimize"
  end

  if role == "utility" then
    if score <= 5 then
      return "acceptable"
    end
    if score <= 10 then
      return "should-optimize"
    end
    return "needs-refactoring"
  end

  if score <= 10 then
    return "acceptable"
  end
  if score <= 20 then
    return "monitor"
  end
  return "needs-refactoring"
end

local function data_complexity_level(nested_maps, struct_depth)
  if nested_maps >= 3 or struct_depth >= 4 then
    return "high"
  end
  if nested_maps >= 2 or struct_depth >= 2 then
    return "medium"
  end
  return "low"
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
        self_score = 0,
        dependency_score = 0,
        entry_score = 0,
        branching = 0,
        nesting_depth = 0,
        loops = 0,
        call_count = 0,
        role = "core-logic",
        threshold = "simple",
        role_assessment = "acceptable",
        hotspots = {},
        suggestions = {},
        data_complexity = {
          nested_maps = 0,
          struct_depth = 0,
          level = "low",
        },
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
            self_score = 0,
            dependency_score = 0,
            entry_score = 0,
            branching = 0,
            nesting_depth = 0,
            loops = 0,
            call_count = 0,
            role = "core-logic",
            threshold = "simple",
            role_assessment = "acceptable",
            hotspots = {},
            suggestions = {},
            data_complexity = {
              nested_maps = 0,
              struct_depth = 0,
              level = "low",
            },
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
                contribution = by_name[callee].self_score or 0,
              }
            end
          end
        end
      end
    end
  end

  return edges
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

local function count_pattern(line, pattern)
  local count = 0
  local start = 1
  while true do
    local s, e = line:find(pattern, start)
    if not s then
      break
    end
    count = count + 1
    start = e + 1
  end
  return count
end

local function derive_hotspots_and_suggestions(fn)
  local hotspots = {}
  local suggestions = {}
  local seen = {}

  local function add(text)
    if text ~= "" and not seen[text] then
      seen[text] = true
      suggestions[#suggestions + 1] = text
    end
  end

  if (fn.branching or 0) >= 6 then
    hotspots[#hotspots + 1] = "high branching"
    add("replace long condition chains with table-driven dispatch")
  end

  if (fn.nesting_depth or 0) >= 3 then
    hotspots[#hotspots + 1] = "deep nesting"
    add("extract nested blocks into helper functions and use guard clauses")
  end

  if (fn.loops or 0) >= 3 then
    hotspots[#hotspots + 1] = "loop-heavy"
    add("split loop responsibilities and extract inner loops")
  end

  if (fn.loops or 0) >= 2 and (fn.nesting_depth or 0) >= 2 then
    add("extract inner-loop work into dedicated functions")
  end

  if (fn.call_count or 0) >= 8 and (fn.branching or 0) <= 2 then
    add("consider splitting orchestration into smaller stage functions")
  end

  if (fn.score or 0) > 20 then
    hotspots[#hotspots + 1] = "score above threshold"
    add("decompose function and reduce transitive dependencies")
  end

  if #suggestions == 0 and (fn.score or 0) > 10 then
    add("review function boundaries and extract focused helpers")
  end

  fn.hotspots = hotspots
  fn.suggestions = suggestions
end

local function infer_role(fn)
  if (fn.call_count or 0) >= 5 and (fn.branching or 0) <= 3 and (fn.loops or 0) <= 1 then
    return "orchestrator"
  end
  if (fn.self_score or 0) <= 5 and (fn.branching or 0) <= 2 and (fn.loops or 0) == 0 and (fn.nesting_depth or 0) <= 1 then
    return "utility"
  end
  return "core-logic"
end

local function analyze_function_complexity(lines, fn)
  local branch = 0
  local loops = 0
  local calls = 0
  local depth = 0
  local current_depth = 0
  local nested_maps = 0

  for line_nr = fn.line, fn.end_line do
    local raw = lines[line_nr] or ""
    local line = raw:gsub("//.*$", "")

    local close_count = select(2, line:gsub("}", ""))
    current_depth = math.max(current_depth - close_count, 0)

    branch = branch + count_pattern(line, "%f[%a]if%f[%A]")
    branch = branch + count_pattern(line, "%f[%a]elseif%f[%A]")
    branch = branch + count_pattern(line, "%f[%a]switch%f[%A]")
    branch = branch + count_pattern(line, "%f[%a]case%f[%A]")

    loops = loops + count_pattern(line, "%f[%a]for%f[%A]")
    loops = loops + count_pattern(line, "%f[%a]while%f[%A]")

    local line_calls = 0
    for callee in line:gmatch("([%a_][%w_]*)%s*%(") do
      if not KEYWORDS[callee] then
        line_calls = line_calls + 1
      end
    end
    calls = calls + line_calls

    local opens = select(2, line:gsub("{", ""))
    current_depth = current_depth + opens
    if current_depth > depth then
      depth = current_depth
    end

    local map_brackets = select(2, line:gsub("%[", ""))
    if map_brackets > nested_maps then
      nested_maps = map_brackets
    end
  end

  fn.branching = branch
  fn.loops = loops
  fn.call_count = calls
  fn.nesting_depth = math.max(depth, 0)
  fn.self_score = branch + loops + calls + fn.nesting_depth
  fn.data_complexity = {
    nested_maps = nested_maps,
    struct_depth = math.max(fn.nesting_depth - 1, 0),
    level = data_complexity_level(nested_maps, math.max(fn.nesting_depth - 1, 0)),
  }
end

local function compute_dependency_scores(functions, edges)
  local adjacency = {}
  local by_name = function_map(functions)

  for _, fn in ipairs(functions) do
    adjacency[fn.name] = {}
  end

  for _, edge in ipairs(edges) do
    adjacency[edge.from][#adjacency[edge.from] + 1] = edge.to
  end

  for _, fn in ipairs(functions) do
    local visited = {}
    local sum = 0

    local function walk(name)
      for _, callee in ipairs(adjacency[name] or {}) do
        if not visited[callee] then
          visited[callee] = true
          local target = by_name[callee]
          if target then
            sum = sum + (target.self_score or 0)
            walk(callee)
          end
        end
      end
    end

    walk(fn.name)
    fn.dependency_score = sum
    fn.score = (fn.self_score or 0) + sum
  end

  for _, edge in ipairs(edges) do
    local target = by_name[edge.to]
    edge.contribution = target and (target.self_score or 0) or 0
  end
end

local function decorate_function(fn)
  fn.role = infer_role(fn)
  fn.threshold = score_band(fn.score or 0)
  fn.role_assessment = role_assessment(fn.role, fn.score or 0)
  derive_hotspots_and_suggestions(fn)
end

local function build_breakdown(fn)
  return {
    branching = fn.branching or 0,
    nesting_depth = fn.nesting_depth or 0,
    loops = fn.loops or 0,
    calls = fn.call_count or 0,
  }
end

local function to_entry(fn, reason)
  return {
    name = fn.name,
    line = fn.line,
    score = fn.score or 0,
    self_score = fn.self_score or 0,
    dependency_score = fn.dependency_score or 0,
    entry_score = fn.entry_score or 0,
    breakdown = build_breakdown(fn),
    role = fn.role,
    threshold = fn.threshold,
    role_assessment = fn.role_assessment,
    hotspots = fn.hotspots,
    suggestions = fn.suggestions,
    data_complexity = fn.data_complexity,
    reason = reason,
  }
end

local function to_important(fn)
  return {
    name = fn.name,
    line = fn.line,
    score = fn.score or 0,
    self_score = fn.self_score or 0,
    dependency_score = fn.dependency_score or 0,
    breakdown = build_breakdown(fn),
    role = fn.role,
    threshold = fn.threshold,
    role_assessment = fn.role_assessment,
    hotspots = fn.hotspots,
    suggestions = fn.suggestions,
    data_complexity = fn.data_complexity,
    visibility = fn.visibility,
  }
end

local function choose_entry_points(file_path, functions)
  local file_hint = basename(file_path)
  local entries = {}

  for _, fn in ipairs(functions) do
    local entry_score = score_name(fn.name)
    if ENTRY_FILE_HINTS[file_hint] and fn.line <= 120 then
      entry_score = entry_score + 2
    end
    if fn.name == "main" then
      entry_score = entry_score + 4
    end
    fn.entry_score = entry_score
    if entry_score > 0 then
      entries[#entries + 1] = to_entry(fn, "entry-like naming")
    end
  end

  table.sort(entries, function(a, b)
    if a.entry_score == b.entry_score then
      return a.line < b.line
    end
    return a.entry_score > b.entry_score
  end)

  if #entries == 0 and functions[1] then
    functions[1].entry_score = 1
    entries[1] = to_entry(functions[1], "first function in file")
  end

  while #entries > 3 do
    table.remove(entries)
  end

  return entries
end

local function rank_functions(functions, max_functions)
  local ranked = {}
  for _, fn in ipairs(functions) do
    ranked[#ranked + 1] = to_important(fn)
  end

  table.sort(ranked, function(a, b)
    if a.score == b.score then
      if (a.self_score or 0) == (b.self_score or 0) then
        return a.line < b.line
      end
      return (a.self_score or 0) > (b.self_score or 0)
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
      filtered[#filtered + 1] = {
        from = edge.from,
        to = edge.to,
        line = edge.line,
        contribution = edge.contribution or 0,
      }
    end
  end

  if #filtered == 0 then
    for _, edge in ipairs(edges) do
      filtered[#filtered + 1] = {
        from = edge.from,
        to = edge.to,
        line = edge.line,
        contribution = edge.contribution or 0,
      }
    end
  end

  while #filtered > max_edges do
    table.remove(filtered)
  end

  return filtered
end

local function collect_hotspots(functions, max_items)
  local items = {}
  for _, fn in ipairs(functions) do
    if fn.hotspots and #fn.hotspots > 0 then
      items[#items + 1] = {
        name = fn.name,
        line = fn.line,
        score = fn.score,
        role = fn.role,
        reason = table.concat(fn.hotspots, ", "),
        suggestion = fn.suggestions and fn.suggestions[1] or nil,
      }
    end
  end

  table.sort(items, function(a, b)
    if a.score == b.score then
      return a.line < b.line
    end
    return a.score > b.score
  end)

  while #items > max_items do
    table.remove(items)
  end

  return items
end

local function build_function_groups(entries, functions, edges)
  local by_name = function_map(functions)
  local adjacency = {}
  for _, fn in ipairs(functions) do
    adjacency[fn.name] = {}
  end
  for _, edge in ipairs(edges) do
    adjacency[edge.from][#adjacency[edge.from] + 1] = edge.to
  end

  local groups = {}
  local seen_groups = {}

  local function build_group(root)
    if not root or not by_name[root] then
      return
    end

    local visited = {}
    local stack = { root }
    while #stack > 0 do
      local name = table.remove(stack)
      if not visited[name] then
        visited[name] = true
        for _, child in ipairs(adjacency[name] or {}) do
          if not visited[child] then
            stack[#stack + 1] = child
          end
        end
      end
    end

    local names = {}
    local score = 0
    for name in pairs(visited) do
      names[#names + 1] = name
      score = score + ((by_name[name] and by_name[name].score) or 0)
    end
    table.sort(names)
    local key = table.concat(names, "|")
    if key ~= "" and not seen_groups[key] then
      seen_groups[key] = true
      groups[#groups + 1] = {
        name = root .. " pipeline",
        kind = "call-graph",
        score = score,
        function_count = #names,
        functions = names,
      }
    end
  end

  for _, entry in ipairs(entries) do
    build_group(entry.name)
  end

  if #groups == 0 and functions[1] then
    local top = functions[1]
    for i = 2, #functions do
      if (functions[i].score or 0) > (top.score or 0) then
        top = functions[i]
      end
    end
    build_group(top.name)
  end

  table.sort(groups, function(a, b)
    if a.score == b.score then
      return a.name < b.name
    end
    return a.score > b.score
  end)

  while #groups > 5 do
    table.remove(groups)
  end

  return groups
end

local function build_module_scores(file_path, functions)
  local module = vim.fn.fnamemodify(file_path, ":t")
  local score = 0
  for _, fn in ipairs(functions) do
    score = score + (fn.score or 0)
  end
  return {
    {
      module = module,
      score = score,
      function_count = #functions,
    },
  }
end

local function build_data_complexity(functions)
  local nested_maps = 0
  local struct_depth = 0
  local types = {}

  for _, fn in ipairs(functions) do
    local dc = fn.data_complexity or {}
    local maps = dc.nested_maps or 0
    local depth = dc.struct_depth or 0
    if maps > nested_maps then
      nested_maps = maps
    end
    if depth > struct_depth then
      struct_depth = depth
    end
  end

  return {
    level = data_complexity_level(nested_maps, struct_depth),
    nested_maps = nested_maps,
    struct_depth = struct_depth,
    types = types,
  }
end

function M.analyze(bufnr, opts)
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  local filetype = vim.bo[bufnr].filetype
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local functions = collect_functions(bufnr, filetype, lines)
  for _, fn in ipairs(functions) do
    analyze_function_complexity(lines, fn)
  end

  local edges = collect_edges(lines, functions)
  compute_dependency_scores(functions, edges)
  for _, fn in ipairs(functions) do
    decorate_function(fn)
  end

  local annotations = collect_annotations(lines)
  local entries = choose_entry_points(file_path, functions)
  local ranked = rank_functions(functions, opts.max_functions)
  local flow = select_flow(entries, ranked, edges, opts.max_flow_edges)
  local hotspots = collect_hotspots(functions, 8)
  local groups = build_function_groups(entries, functions, edges)
  local module_scores = build_module_scores(file_path, functions)
  local data_complexity = build_data_complexity(functions)

  local function_ranges = {}
  for _, fn in ipairs(functions) do
    function_ranges[#function_ranges + 1] = {
      name = fn.name,
      line = fn.line,
      end_line = fn.end_line or fn.line,
      file = file_path,
    }
  end

  return {
    source = "lua-fallback",
    file = file_path,
    entry_points = entries,
    important_functions = ranked,
    execution_flow = flow,
    annotations = annotations,
    function_ranges = function_ranges,
    score_thresholds = SCORE_THRESHOLDS,
    hotspots = hotspots,
    function_groups = groups,
    module_scores = module_scores,
    data_complexity = data_complexity,
  }
end

return M
