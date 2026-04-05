local analyzer = require("codeguide.analyzer")
local config = require("codeguide.config")
local ui = require("codeguide.ui")

local M = {}

local initialized = false
local commands_registered = false
local uv = vim.uv or vim.loop
local timers = {}

local function can_analyze(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if vim.bo[bufnr].buftype ~= "" then
    return false
  end
  if vim.api.nvim_buf_get_name(bufnr) == "" then
    return false
  end
  return true
end

local function analyze_and_render(bufnr)
  if not can_analyze(bufnr) then
    return
  end

  local result, go_error = analyzer.analyze(bufnr)
  if result then
    ui.render(bufnr, result, config.get())
  end

  if go_error and config.get().notify_on_error then
    vim.notify("codeguide.nvim: " .. go_error, vim.log.levels.WARN)
  end
end

local function schedule_analysis(bufnr)
  local opts = config.get()
  local delay = opts.debounce_ms or 200

  if timers[bufnr] then
    timers[bufnr]:stop()
    timers[bufnr]:close()
    timers[bufnr] = nil
  end

  local timer = uv.new_timer()
  timers[bufnr] = timer
  timer:start(delay, 0, function()
    timer:stop()
    timer:close()
    timers[bufnr] = nil
    vim.schedule(function()
      analyze_and_render(bufnr)
    end)
  end)
end

local function register_commands()
  if commands_registered then
    return
  end

  vim.api.nvim_create_user_command("CodeGuideAnalyze", function(args)
    local bufnr = args.buf or vim.api.nvim_get_current_buf()
    analyze_and_render(bufnr)
  end, {
    desc = "Analyze current buffer and show code guide",
  })

  vim.api.nvim_create_user_command("CodeGuideExplain", function(args)
    local bufnr = args.buf or vim.api.nvim_get_current_buf()
    local result = analyzer.last(bufnr)
    if not result then
      result = analyzer.analyze(bufnr)
    end
    if result then
      ui.show_summary(result)
    end
  end, {
    desc = "Open a summary of detected code signals",
  })

  vim.api.nvim_create_user_command("CodeGuideClear", function(args)
    local bufnr = args.buf or vim.api.nvim_get_current_buf()
    ui.clear(bufnr)
  end, {
    desc = "Clear all codeguide highlights in current buffer",
  })

  commands_registered = true
end

local function register_autocmds()
  local group = vim.api.nvim_create_augroup("CodeGuideAutoAnalyze", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    group = group,
    callback = function(event)
      schedule_analysis(event.buf)
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    callback = function(event)
      if timers[event.buf] then
        timers[event.buf]:stop()
        timers[event.buf]:close()
        timers[event.buf] = nil
      end
      analyzer.clear(event.buf)
    end,
  })
end

function M.setup(opts)
  config.set(opts)

  if not initialized then
    ui.setup_highlights()
    initialized = true
  end

  register_commands()

  if config.get().auto_analyze then
    register_autocmds()
  else
    vim.api.nvim_create_augroup("CodeGuideAutoAnalyze", { clear = true })
  end
end

function M.analyze(bufnr)
  analyze_and_render(bufnr or vim.api.nvim_get_current_buf())
end

function M.explain(bufnr)
  local target = bufnr or vim.api.nvim_get_current_buf()
  local result = analyzer.last(target) or analyzer.analyze(target)
  if result then
    ui.show_summary(result)
  end
end

return M
