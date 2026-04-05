local analyzer = require("codeguide.analyzer")
local config = require("codeguide.config")
local ui = require("codeguide.ui")

local M = {}

local initialized = false
local commands_registered = false
local uv = vim.uv or vim.loop
local timers = {}
local latest_request = {}
local base_winbar = {}

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

  latest_request[bufnr] = (latest_request[bufnr] or 0) + 1
  local request_id = latest_request[bufnr]

  local function on_result(result, go_error)
    if request_id ~= latest_request[bufnr] then
      return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    if result then
      ui.render(bufnr, result, config.get(), base_winbar[bufnr] or "")
    end

    if go_error and go_error ~= "Stale analysis" and config.get().notify_on_error then
      vim.notify("codeguide.nvim: " .. go_error, vim.log.levels.WARN)
    end
  end

  if analyzer.analyze_async then
    analyzer.analyze_async(bufnr, on_result)
  else
    local result, go_error = analyzer.analyze(bufnr)
    on_result(result, go_error)
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

  vim.api.nvim_create_user_command("CodeGuideTelescope", function(args)
    local mode = vim.trim(args.args or "")
    if mode == "" then
      mode = "important"
    end
    require("codeguide.telescope").pick(mode)
  end, {
    nargs = "?",
    complete = function()
      return { "important", "entry" }
    end,
    desc = "Open Telescope picker for codeguide items",
  })

  vim.api.nvim_create_user_command("CodeGuideClear", function(args)
    local bufnr = args.buf or vim.api.nvim_get_current_buf()
    ui.clear(bufnr)
    ui.update_chrome(bufnr, nil, config.get(), base_winbar[bufnr] or "")
    analyzer.clear(bufnr)
  end, {
    desc = "Clear all codeguide highlights in current buffer",
  })

  commands_registered = true
end

local function track_winbar(bufnr)
  if not config.get().show_winbar then
    return
  end
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) ~= bufnr then
    return
  end
  if not base_winbar[bufnr] then
    local current = vim.api.nvim_get_option_value("winbar", { scope = "local", win = win })
    if current and current:find("CodeGuide Entry:", 1, true) then
      current = ""
    end
    base_winbar[bufnr] = current
  end
end

local function register_autocmds()
  local group = vim.api.nvim_create_augroup("CodeGuideAutoAnalyze", { clear = true })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "TextChanged", "TextChangedI" }, {
    group = group,
    callback = function(event)
      if event.event == "BufEnter" then
        track_winbar(event.buf)
      end
      schedule_analysis(event.buf)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "CursorMoved", "CursorMovedI" }, {
    group = group,
    callback = function(event)
      if not vim.api.nvim_buf_is_valid(event.buf) then
        return
      end
      if not can_analyze(event.buf) then
        return
      end
      local result = analyzer.last(event.buf)
      ui.update_chrome(event.buf, result, config.get(), base_winbar[event.buf] or "")
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
      latest_request[event.buf] = nil
      base_winbar[event.buf] = nil
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

function M.breadcrumb()
  return vim.b.codeguide_breadcrumb or ""
end

function M.telescope(mode)
  require("codeguide.telescope").pick(mode or "important")
end

return M
