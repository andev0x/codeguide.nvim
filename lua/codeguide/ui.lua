local M = {}

local namespace = vim.api.nvim_create_namespace("codeguide")

local ENTRY_SIGN = "󰁔"
local IMPORTANT_SIGN = "󱡶"

local function set_default_highlights()
  vim.api.nvim_set_hl(0, "CodeGuideEntry", { default = true, fg = "#8EC07C", bold = true })
  vim.api.nvim_set_hl(0, "CodeGuideEntryLine", { default = true, link = "CursorLine" })
  vim.api.nvim_set_hl(0, "CodeGuideEntryVirtual", { default = true, fg = "#A9D78D", bold = true })
  vim.api.nvim_set_hl(0, "CodeGuideImportant", { default = true, fg = "#83A598" })
  vim.api.nvim_set_hl(0, "CodeGuideImportantLine", { default = true, link = "Visual" })
  vim.api.nvim_set_hl(0, "CodeGuideImportantVirtual", { default = true, fg = "#9AB7A5" })
  vim.api.nvim_set_hl(0, "CodeGuideAnnotationVirtual", { default = true, fg = "#FABD2F" })
  vim.api.nvim_set_hl(0, "CodeGuideScoreHigh", { default = true, fg = "#B8BB26", bold = true })
  vim.api.nvim_set_hl(0, "CodeGuideScoreMid", { default = true, fg = "#FABD2F" })
  vim.api.nvim_set_hl(0, "CodeGuideScoreLow", { default = true, fg = "#D79921" })
  vim.api.nvim_set_hl(0, "CodeGuideFlowArrow", { default = true, fg = "#7DAEA3" })
  vim.api.nvim_set_hl(0, "CodeGuideWinbar", { default = true, fg = "#A89984", italic = true })
  vim.api.nvim_set_hl(0, "CodeGuideBreadcrumb", { default = true, fg = "#89B482" })
  vim.api.nvim_set_hl(0, "CodeGuidePopupTitle", { default = true, fg = "#8EC07C", bold = true })
  vim.api.nvim_set_hl(0, "CodeGuidePopupFunction", { default = true, fg = "#83A598", bold = true })
  vim.api.nvim_set_hl(0, "CodeGuidePopupLocation", { default = true, fg = "#B8BB26" })
  vim.api.nvim_set_hl(0, "CodeGuideTreeGlyph", { default = true, fg = "#FABD2F" })
  vim.api.nvim_set_hl(0, "CodeGuidePopupScoreHot", { default = true, fg = "#FB4934", bold = true })
  vim.api.nvim_set_hl(0, "CodeGuidePopupScoreWarm", { default = true, fg = "#FABD2F", bold = true })
end

local function define_signs()
  vim.fn.sign_define("CodeGuideEntrySign", {
    text = ENTRY_SIGN,
    texthl = "CodeGuideEntry",
    linehl = "",
    numhl = "",
  })
  vim.fn.sign_define("CodeGuideImportantSign", {
    text = IMPORTANT_SIGN,
    texthl = "CodeGuideImportant",
    linehl = "",
    numhl = "",
  })
end

local function score_group(score)
  if score >= 21 then
    return "CodeGuideScoreHigh"
  end
  if score >= 11 then
    return "CodeGuideScoreMid"
  end
  return "CodeGuideScoreLow"
end

local function score_chunk(item)
  local score = (item and item.score) or 0
  local self_score = (item and item.self_score) or score
  local dependency_score = (item and item.dependency_score) or 0
  return {
    string.format(" [score:%d self:%d deps:%d]", score, self_score, dependency_score),
    score_group(score),
  }
end

local function flow_tree(result)
  local children = {}
  local contributions = {}
  local indegree = {}
  local nodes = {}

  for _, edge in ipairs(result.execution_flow or {}) do
    children[edge.from] = children[edge.from] or {}
    children[edge.from][#children[edge.from] + 1] = edge.to
    contributions[edge.from] = contributions[edge.from] or {}
    contributions[edge.from][edge.to] = edge.contribution or 0
    nodes[edge.from] = true
    nodes[edge.to] = true
    indegree[edge.to] = (indegree[edge.to] or 0) + 1
    indegree[edge.from] = indegree[edge.from] or 0
  end

  local starts = {}
  for _, entry in ipairs(result.entry_points or {}) do
    if nodes[entry.name] then
      starts[#starts + 1] = entry.name
    end
  end

  for node, deg in pairs(indegree) do
    if deg == 0 then
      starts[#starts + 1] = node
    end
  end

  local unique = {}
  local deduped = {}
  for _, node in ipairs(starts) do
    if node and not unique[node] then
      unique[node] = true
      deduped[#deduped + 1] = node
    end
  end

  table.sort(deduped)

  local lines = {}
  local visited = {}

  local function render(node, prefix, is_last, parent)
    local branch = is_last and "└─ " or "├─ "
    local row = prefix .. branch .. node
    if parent and contributions[parent] and contributions[parent][node] then
      row = row .. string.format(" (+%d)", contributions[parent][node])
    end
    lines[#lines + 1] = {
      text = row,
      node = node,
    }

    if visited[node] then
      lines[#lines + 1] = {
        text = prefix .. (is_last and "   " or "│  ") .. "└─ ...",
      }
      return
    end

    visited[node] = true
    local next_nodes = children[node] or {}
    for i, child in ipairs(next_nodes) do
      local next_prefix = prefix .. (is_last and "   " or "│  ")
      render(child, next_prefix, i == #next_nodes, node)
    end
  end

  if #deduped == 0 then
    return {
      { text = "  none" },
    }
  end

  for i, node in ipairs(deduped) do
    render(node, "", i == #deduped, nil)
  end

  return lines
end

local function normalize_name(name)
  if type(name) ~= "string" then
    return ""
  end
  return name:match("([^.]+)$") or name
end

local function build_jump_lookup(result)
  local lookup = {}

  local function upsert(name, line, file)
    if type(name) ~= "string" or name == "" then
      return
    end

    local current = lookup[name]
    if (not current) or ((line or 0) < (current.line or 0)) then
      lookup[name] = {
        name = name,
        line = line,
        file = file,
      }
    end

    local simple = normalize_name(name)
    local by_simple = lookup[simple]
    if (not by_simple) or ((line or 0) < (by_simple.line or 0)) then
      lookup[simple] = {
        name = simple,
        line = line,
        file = file,
      }
    end
  end

  for _, item in ipairs(result.entry_points or {}) do
    upsert(item.name, item.line, item.file or result.file)
  end
  for _, item in ipairs(result.important_functions or {}) do
    upsert(item.name, item.line, item.file or result.file)
  end
  for _, item in ipairs(result.function_ranges or {}) do
    upsert(item.name, item.line, item.file or result.file)
  end

  return lookup
end

local function get_current_win_for_buf(bufnr)
  local current = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(current) and vim.api.nvim_win_get_buf(current) == bufnr then
    return current
  end

  local wins = vim.fn.win_findbuf(bufnr)
  return wins[1]
end

local function threshold_label(item)
  if not item then
    return ""
  end
  if item.max and item.max >= 0 then
    return string.format("%s:%d-%d", item.label or "", item.min or 0, item.max)
  end
  return string.format("%s:%d+", item.label or "", item.min or 0)
end

local function metric_breakdown(item)
  local breakdown = (item and item.breakdown) or {}
  return string.format(
    "branching:%d nesting:%d loops:%d calls:%d",
    breakdown.branching or 0,
    breakdown.nesting_depth or 0,
    breakdown.loops or 0,
    breakdown.calls or 0
  )
end

local function data_breakdown(item)
  local data = (item and item.data_complexity) or {}
  return string.format(
    "data:%s maps:%d struct-depth:%d",
    data.level or "low",
    data.nested_maps or 0,
    data.struct_depth or 0
  )
end

local function make_summary_lines(result)
  local lines = {
    "  CodeGuide",
    "",
    "  Engine: " .. result.source,
  }
  local jump_index = {}
  local jump_lookup = build_jump_lookup(result)
  local max_name_width = 0
  for _, item in ipairs(result.important_functions or {}) do
    max_name_width = math.max(max_name_width, vim.fn.strdisplaywidth(item.name or ""))
  end

  lines[#lines + 1] = "  Thresholds:"
  if #(result.score_thresholds or {}) == 0 then
    lines[#lines + 1] = "    - simple:0-5, moderate:6-10, complex:11-20, needs-refactoring:21+"
  else
    local chunks = {}
    for _, item in ipairs(result.score_thresholds or {}) do
      chunks[#chunks + 1] = threshold_label(item)
    end
    lines[#lines + 1] = "    - " .. table.concat(chunks, " | ")
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Hotspots:"
  if #(result.hotspots or {}) == 0 then
    lines[#lines + 1] = "    - none"
  else
    for _, item in ipairs(result.hotspots or {}) do
      local role = item.role or "core-logic"
      lines[#lines + 1] = string.format(
        "    - %s score:%d (%s, %s:%d)",
        item.name or "?",
        item.score or 0,
        role,
        vim.fn.fnamemodify(item.file or result.file, ":t"),
        item.line or 0
      )
      jump_index[#lines] = {
        name = item.name,
        line = item.line,
        file = item.file or result.file,
      }
      lines[#lines + 1] = string.format("      reason: %s", item.reason or "")
      if item.suggestion and item.suggestion ~= "" then
        lines[#lines + 1] = string.format("      suggestion: %s", item.suggestion)
      end
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Entry Points:"

  if #result.entry_points == 0 then
    lines[#lines + 1] = "    - none"
  else
    for _, item in ipairs(result.entry_points) do
      lines[#lines + 1] = string.format(
        "    - %s  score:%3d (self:%d deps:%d entry:%d)  role:%s/%s  [%s]  (%s:%d)",
        item.name,
        item.score or 0,
        item.self_score or 0,
        item.dependency_score or 0,
        item.entry_score or 0,
        item.role or "core-logic",
        item.role_assessment or "acceptable",
        item.threshold or "simple",
        vim.fn.fnamemodify(item.file or result.file, ":t"),
        item.line
      )
      jump_index[#lines] = {
        name = item.name,
        line = item.line,
        file = item.file or result.file,
      }
      lines[#lines + 1] = "      " .. metric_breakdown(item)
      lines[#lines + 1] = "      " .. data_breakdown(item)
      if item.suggestions and item.suggestions[1] then
        lines[#lines + 1] = "      suggestion: " .. item.suggestions[1]
      end
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Important Functions:"
  if #result.important_functions == 0 then
    lines[#lines + 1] = "    - none"
  else
    for _, item in ipairs(result.important_functions) do
      local name = item.name or ""
      local pad = math.max(max_name_width - vim.fn.strdisplaywidth(name), 0)
      lines[#lines + 1] = string.format(
        "    - %s%s  score:%3d  (self:%d deps:%d)  role:%s/%s [%s]  (%s:%d)",
        name,
        string.rep(" ", pad),
        item.score or 0,
        item.self_score or 0,
        item.dependency_score or 0,
        item.role or "core-logic",
        item.role_assessment or "acceptable",
        item.threshold or "simple",
        vim.fn.fnamemodify(item.file or result.file, ":t"),
        item.line
      )
      jump_index[#lines] = {
        name = item.name,
        line = item.line,
        file = item.file or result.file,
      }
      lines[#lines + 1] = "      " .. metric_breakdown(item)
      lines[#lines + 1] = "      " .. data_breakdown(item)
      if item.suggestions and item.suggestions[1] then
        lines[#lines + 1] = "      suggestion: " .. item.suggestions[1]
      end
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Function Groups:"
  if #(result.function_groups or {}) == 0 then
    lines[#lines + 1] = "    - none"
  else
    for _, group in ipairs(result.function_groups or {}) do
      lines[#lines + 1] = string.format(
        "    - %s  score:%d  functions:%d  kind:%s",
        group.name or "group",
        group.score or 0,
        group.function_count or 0,
        group.kind or "call-graph"
      )
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Module Scores:"
  if #(result.module_scores or {}) == 0 then
    lines[#lines + 1] = "    - none"
  else
    for _, module in ipairs(result.module_scores or {}) do
      lines[#lines + 1] = string.format(
        "    - %s  score:%d  functions:%d",
        module.module or "module",
        module.score or 0,
        module.function_count or 0
      )
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Data Complexity:"
  local data = result.data_complexity or {}
  lines[#lines + 1] = string.format(
    "    - level:%s nested_maps:%d struct_depth:%d",
    data.level or "low",
    data.nested_maps or 0,
    data.struct_depth or 0
  )
  for _, item in ipairs(data.types or {}) do
    lines[#lines + 1] = string.format(
      "    - type %s maps:%d struct-depth:%d (%s)",
      item.name or "?",
      item.nested_maps or 0,
      item.struct_depth or 0,
      vim.fn.fnamemodify(item.file or result.file, ":t")
    )
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Execution Flow (tree):"
  for _, row in ipairs(flow_tree(result)) do
    lines[#lines + 1] = "    " .. row.text
    if row.node then
      local mapped = jump_lookup[row.node] or jump_lookup[normalize_name(row.node)]
      if mapped then
        jump_index[#lines] = {
          name = mapped.name,
          line = mapped.line,
          file = mapped.file or result.file,
        }
      end
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  Annotations:"
  if #result.annotations == 0 then
    lines[#lines + 1] = "    - none"
  else
    for _, annotation in ipairs(result.annotations) do
      lines[#lines + 1] = string.format("    - %s line %d", annotation.kind, annotation.line)
    end
  end

  return lines, jump_index
end

local function jump_to_item(item, source_file)
  local path = item.file or source_file

  if path and path ~= "" and vim.fn.filereadable(path) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(path))
  end

  vim.api.nvim_win_set_cursor(0, { math.max(item.line, 1), 0 })
end

local function join_entry_names(result, current_file)
  local names = {}
  for _, item in ipairs(result.entry_points or {}) do
    if (not item.file) or item.file == current_file then
      names[#names + 1] = item.name
    end
  end
  if #names == 0 then
    for _, item in ipairs(result.entry_points or {}) do
      names[#names + 1] = item.name
    end
  end
  if #names == 0 then
    return "none"
  end
  return table.concat(names, ", ")
end

local function function_at_cursor(bufnr, cursor_line, result)
  local current_file = vim.api.nvim_buf_get_name(bufnr)
  for _, item in ipairs(result.function_ranges or {}) do
    local same_file = (not item.file) or item.file == current_file
    local start_line = item.line or 0
    local end_line = item.end_line or start_line
    if same_file and cursor_line >= start_line and cursor_line <= end_line then
      return item
    end
  end
  return nil
end

local function add_highlight(bufnr, group, line, col_start, col_end)
  if col_start < col_end then
    pcall(vim.api.nvim_buf_add_highlight, bufnr, namespace, group, line, col_start, col_end)
  end
end

local function highlight_tree_glyphs(bufnr, line_idx, text)
  local from = 1
  while true do
    local s, e = text:find("[├└│─]", from)
    if not s then
      break
    end
    add_highlight(bufnr, "CodeGuideTreeGlyph", line_idx, s - 1, e)
    from = e + 1
  end
end

local function highlight_summary(bufnr, lines, jump_index)
  for i, text in ipairs(lines) do
    local line_idx = i - 1

    if i == 1 then
      add_highlight(bufnr, "CodeGuidePopupTitle", line_idx, 2, #text)
    end

    local jump = jump_index[i]
    if jump and jump.name then
      local fn_start, fn_end = text:find(jump.name, 1, true)
      if fn_start and fn_end then
        add_highlight(bufnr, "CodeGuidePopupFunction", line_idx, fn_start - 1, fn_end)
      end
    end

    local loc_start, loc_end = text:find("%([^:]+:%d+%)")
    if loc_start and loc_end then
      add_highlight(bufnr, "CodeGuidePopupLocation", line_idx, loc_start - 1, loc_end)
    end

    local score_start, score_end, score_value = text:find("score:%s*(%d+)")
    if score_start and score_end then
      local hl = tonumber(score_value or "0") > 20 and "CodeGuidePopupScoreHot" or "CodeGuidePopupScoreWarm"
      add_highlight(bufnr, hl, line_idx, score_start - 1, score_end)
    end

    if text:find("[├└│─]", 1) then
      highlight_tree_glyphs(bufnr, line_idx, text)
    end
  end
end

local function build_breadcrumb(result, fn)
  if not fn then
    return nil
  end

  local parents = {}
  for _, edge in ipairs(result.execution_flow or {}) do
    local to_name = normalize_name(edge.to)
    local from_name = normalize_name(edge.from)
    parents[to_name] = parents[to_name] or {}
    parents[to_name][#parents[to_name] + 1] = from_name
  end

  local current_name = normalize_name(fn.name)
  local path = { current_name }
  local guard = 0
  local current = current_name
  while parents[current] and parents[current][1] and guard < 8 do
    current = parents[current][1]
    table.insert(path, 1, current)
    guard = guard + 1
  end

  if #path <= 1 then
    return nil
  end

  return table.concat(path, " -> ")
end

function M.setup_highlights()
  set_default_highlights()
  define_signs()
end

function M.clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  pcall(vim.fn.sign_unplace, "codeguide", { buffer = bufnr })
  pcall(function()
    vim.b[bufnr].codeguide_breadcrumb = nil
  end)
end

function M.render(bufnr, result, opts, base_winbar)
  M.clear(bufnr)
  local marked_lines = {}
  local current_file = vim.api.nvim_buf_get_name(bufnr)

  for _, entry in ipairs(result.entry_points) do
    if (not entry.file) or entry.file == current_file then
      local line = math.max((entry.line or 1) - 1, 0)
      marked_lines[line] = true
      vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
        line_hl_group = "CodeGuideEntryLine",
        priority = 180,
      })
      if opts.show_virtual_text then
        vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
          virt_text = {
            { " entry " .. entry.name, "CodeGuideEntryVirtual" },
            score_chunk(entry),
          },
          virt_text_pos = "eol",
          priority = 180,
        })
      end
      if opts.show_signs then
        pcall(vim.fn.sign_place, 0, "codeguide", "CodeGuideEntrySign", bufnr, { lnum = line + 1, priority = 30 })
      end
    end
  end

  for _, fn in ipairs(result.important_functions) do
    if (not fn.file) or fn.file == current_file then
      local line = math.max((fn.line or 1) - 1, 0)
      if not marked_lines[line] then
        vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
          line_hl_group = "CodeGuideImportantLine",
          priority = 160,
        })
      end

      if opts.show_virtual_text then
        vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
          virt_text = {
            { " focus " .. fn.name, "CodeGuideImportantVirtual" },
            score_chunk(fn),
          },
          virt_text_pos = "eol",
          priority = 160,
        })
      end

      if opts.show_signs then
        pcall(vim.fn.sign_place, 0, "codeguide", "CodeGuideImportantSign", bufnr, { lnum = line + 1, priority = 20 })
      end
    end
  end

  if opts.highlight_annotations then
    for _, item in ipairs(result.annotations) do
      local line = math.max((item.line or 1) - 1, 0)
      vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
        virt_text = { { " signal " .. item.kind, "CodeGuideAnnotationVirtual" } },
        virt_text_pos = "eol",
        priority = 150,
      })
    end
  end

  M.update_chrome(bufnr, result, opts, base_winbar or "")
end

function M.update_chrome(bufnr, result, opts, base_winbar)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local wins = vim.fn.win_findbuf(bufnr)

  if opts.show_winbar then
    local bar = base_winbar or ""
    if result then
      local summary = "CodeGuide Entry: " .. join_entry_names(result, vim.api.nvim_buf_get_name(bufnr))
      bar = "%#CodeGuideWinbar#" .. summary
      if base_winbar and base_winbar ~= "" then
        bar = base_winbar .. "  " .. bar
      end
    end

    for _, win in ipairs(wins) do
      pcall(vim.api.nvim_set_option_value, "winbar", bar, { scope = "local", win = win })
    end
  end

  if opts.show_statusline_breadcrumb then
    if result then
      local target_win = get_current_win_for_buf(bufnr)
      local cursor_line = target_win and vim.api.nvim_win_get_cursor(target_win)[1] or 1
      local fn = function_at_cursor(bufnr, cursor_line, result)
      local crumb = build_breadcrumb(result, fn)
      if crumb then
        vim.b[bufnr].codeguide_breadcrumb = crumb
      else
        vim.b[bufnr].codeguide_breadcrumb = nil
      end
    else
      vim.b[bufnr].codeguide_breadcrumb = nil
    end
  end
end

function M.show_summary(result)
  local lines, jump_index = make_summary_lines(result)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  highlight_summary(buffer, lines, jump_index)
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].modifiable = false

  local width = 86
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.75))
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " codeguide.nvim ",
    title_pos = "center",
  })

  vim.wo[window].cursorline = true
  vim.wo[window].wrap = false

  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(window) then
      vim.api.nvim_win_close(window, true)
    end
  end, { buffer = buffer, silent = true, nowait = true })

  vim.keymap.set("n", "<CR>", function()
    local line = vim.api.nvim_win_get_cursor(window)[1]
    local item = jump_index[line]
    if not item then
      return
    end

    if vim.api.nvim_win_is_valid(window) then
      vim.api.nvim_win_close(window, true)
    end

    jump_to_item(item, result.file)
    local bufnr = vim.api.nvim_get_current_buf()
    local opts = require("codeguide.config").get()
    local analyzed = require("codeguide.analyzer").last(bufnr)
    local base = vim.api.nvim_get_option_value("winbar", { scope = "local", win = 0 })
    if base:find("CodeGuide Entry:", 1, true) then
      base = ""
    end
    M.update_chrome(bufnr, analyzed, opts, base)
  end, { buffer = buffer, silent = true, nowait = true })
end

return M
