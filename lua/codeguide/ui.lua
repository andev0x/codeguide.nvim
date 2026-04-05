local M = {}

local namespace = vim.api.nvim_create_namespace("codeguide")

local function set_default_highlights()
  vim.api.nvim_set_hl(0, "CodeGuideEntryLine", { default = true, link = "CursorLine" })
  vim.api.nvim_set_hl(0, "CodeGuideEntryVirtual", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "CodeGuideImportantLine", { default = true, link = "Visual" })
  vim.api.nvim_set_hl(0, "CodeGuideImportantVirtual", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "CodeGuideAnnotationVirtual", { default = true, link = "DiagnosticWarn" })
end

local function make_summary_lines(result)
  local lines = {
    "CodeGuide",
    "",
    "Engine: " .. result.source,
    "",
    "Entry Points:",
  }

  if #result.entry_points == 0 then
    lines[#lines + 1] = "  - none"
  else
    for _, item in ipairs(result.entry_points) do
      lines[#lines + 1] = string.format("  - %s (line %d)", item.name, item.line)
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Important Functions:"
  if #result.important_functions == 0 then
    lines[#lines + 1] = "  - none"
  else
    for _, item in ipairs(result.important_functions) do
      lines[#lines + 1] = string.format("  - %s (score %d)", item.name, item.score or 0)
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Execution Flow:"
  if #result.execution_flow == 0 then
    lines[#lines + 1] = "  - none"
  else
    for _, edge in ipairs(result.execution_flow) do
      lines[#lines + 1] = string.format("  - %s -> %s", edge.from, edge.to)
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "Annotations:"
  if #result.annotations == 0 then
    lines[#lines + 1] = "  - none"
  else
    for _, annotation in ipairs(result.annotations) do
      lines[#lines + 1] = string.format("  - %s line %d", annotation.kind, annotation.line)
    end
  end

  return lines
end

function M.setup_highlights()
  set_default_highlights()
end

function M.clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
end

function M.render(bufnr, result, opts)
  M.clear(bufnr)
  local marked_lines = {}

  for _, entry in ipairs(result.entry_points) do
    local line = math.max((entry.line or 1) - 1, 0)
    marked_lines[line] = true
    vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
      line_hl_group = "CodeGuideEntryLine",
      priority = 180,
    })
    vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
      virt_text = { { " entry: " .. entry.name, "CodeGuideEntryVirtual" } },
      virt_text_pos = "eol",
      priority = 180,
    })
  end

  for _, fn in ipairs(result.important_functions) do
    local line = math.max((fn.line or 1) - 1, 0)
    if not marked_lines[line] then
      vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
        line_hl_group = "CodeGuideImportantLine",
        priority = 160,
      })
      vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
        virt_text = { { " focus: " .. fn.name, "CodeGuideImportantVirtual" } },
        virt_text_pos = "eol",
        priority = 160,
      })
    end
  end

  if opts.highlight_annotations then
    for _, item in ipairs(result.annotations) do
      local line = math.max((item.line or 1) - 1, 0)
      vim.api.nvim_buf_set_extmark(bufnr, namespace, line, 0, {
        virt_text = { { " signal: " .. item.kind, "CodeGuideAnnotationVirtual" } },
        virt_text_pos = "eol",
        priority = 150,
      })
    end
  end
end

function M.show_summary(result)
  local lines = make_summary_lines(result)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].bufhidden = "wipe"

  local width = 72
  local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.6))
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
    title = "codeguide.nvim",
    title_pos = "center",
  })

  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(window) then
      vim.api.nvim_win_close(window, true)
    end
  end, { buffer = buffer, silent = true, nowait = true })
end

return M
