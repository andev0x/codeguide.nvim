local M = {}

local function decode_json(content)
  local ok, value = pcall(vim.json.decode, content)
  if not ok then
    return nil, value
  end
  return value
end

local function run_with_system(args, timeout_ms)
  local result = vim.system(args, { text = true, timeout = timeout_ms }):wait()
  if not result or result.code ~= 0 then
    local err = "Go engine failed"
    if result and result.stderr and result.stderr ~= "" then
      err = result.stderr
    end
    return nil, err
  end
  return decode_json(result.stdout)
end

local function run_with_system_async(args, timeout_ms, callback)
  vim.system(args, { text = true, timeout = timeout_ms }, function(result)
    local payload
    local err
    if not result or result.code ~= 0 then
      err = "Go engine failed"
      if result and result.stderr and result.stderr ~= "" then
        err = result.stderr
      end
    else
      payload, err = decode_json(result.stdout)
    end

    vim.schedule(function()
      callback(payload, err)
    end)
  end)
end

local function run_with_fn_system(args)
  local output = vim.fn.system(args)
  if vim.v.shell_error ~= 0 then
    return nil, output
  end
  return decode_json(output)
end

function M.analyze(bufnr, opts)
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  if file_path == "" then
    return nil, "Buffer has no file path"
  end

  local binary = opts.go.binary
  if vim.fn.executable(binary) ~= 1 then
    return nil, "Go engine binary not found: " .. binary
  end

  local args = {
    binary,
    "--file",
    file_path,
    "--max-functions",
    tostring(opts.max_functions),
    "--max-flow-edges",
    tostring(opts.max_flow_edges),
  }

  if vim.system then
    return run_with_system(args, opts.go.timeout_ms)
  end

  return run_with_fn_system(args)
end

function M.analyze_async(bufnr, opts, callback)
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  if file_path == "" then
    callback(nil, "Buffer has no file path")
    return
  end

  local binary = opts.go.binary
  if vim.fn.executable(binary) ~= 1 then
    callback(nil, "Go engine binary not found: " .. binary)
    return
  end

  local args = {
    binary,
    "--file",
    file_path,
    "--max-functions",
    tostring(opts.max_functions),
    "--max-flow-edges",
    tostring(opts.max_flow_edges),
  }

  if vim.system then
    run_with_system_async(args, opts.go.timeout_ms, callback)
    return
  end

  local result, err = run_with_fn_system(args)
  callback(result, err)
end

return M
