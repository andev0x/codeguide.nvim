local M = {}

local function has_telescope()
  return pcall(require, "telescope")
end

local function to_entries(result, mode)
  local items = {}
  local source = mode == "entry" and (result.entry_points or {}) or (result.important_functions or {})
  for _, item in ipairs(source) do
    items[#items + 1] = {
      name = item.name,
      line = item.line,
      file = item.file or result.file,
      score = item.score,
    }
  end
  return items
end

local function build_display(item)
  local file = vim.fn.fnamemodify(item.file or "", ":.")
  return string.format("%s  (%s:%d)", item.name or "?", file, item.line or 0)
end

function M.pick(mode)
  if not has_telescope() then
    vim.notify("codeguide.nvim: telescope.nvim not found", vim.log.levels.WARN)
    return
  end

  local analyzer = require("codeguide.analyzer")
  local bufnr = vim.api.nvim_get_current_buf()
  local result = analyzer.last(bufnr) or analyzer.analyze(bufnr)
  if not result then
    vim.notify("codeguide.nvim: no analysis result yet", vim.log.levels.WARN)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  local items = to_entries(result, mode)

  pickers
    .new({}, {
      prompt_title = "CodeGuide " .. (mode == "entry" and "Entry Points" or "Important Functions"),
      finder = finders.new_table({
        results = items,
        entry_maker = function(item)
          return {
            value = item,
            display = build_display(item),
            ordinal = string.format("%s %s %d", item.name or "", item.file or "", item.line or 0),
          }
        end,
      }),
      sorter = conf.generic_sorter({}),
      attach_mappings = function(prompt_bufnr)
        actions.select_default:replace(function()
          actions.close(prompt_bufnr)
          local selection = action_state.get_selected_entry()
          if not selection or not selection.value then
            return
          end

          local item = selection.value
          if item.file and item.file ~= "" and vim.fn.filereadable(item.file) == 1 then
            vim.cmd("edit " .. vim.fn.fnameescape(item.file))
          end
          vim.api.nvim_win_set_cursor(0, { math.max(item.line or 1, 1), 0 })
        end)
        return true
      end,
    })
    :find()

end

return M
