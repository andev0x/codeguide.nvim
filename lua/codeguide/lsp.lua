local M = {}

local SYMBOL_KINDS = {
  [6] = true, -- Method
  [12] = true, -- Function
}

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

local function refresh_item(item)
  item.score = item.score or 0
  item.self_score = item.self_score or 0
  item.dependency_score = item.dependency_score or 0
  if item.score == 0 and (item.self_score > 0 or item.dependency_score > 0) then
    item.score = item.self_score + item.dependency_score
  end
  if item.score > 0 and item.self_score == 0 and item.dependency_score == 0 then
    item.self_score = item.score
  end
  item.score = (item.self_score or 0) + (item.dependency_score or 0)
  item.role = item.role or "core-logic"
  item.threshold = score_band(item.score)
  item.role_assessment = role_assessment(item.role, item.score)
  item.breakdown = item.breakdown or {
    branching = 0,
    nesting_depth = 0,
    loops = 0,
    calls = 0,
  }
  item.data_complexity = item.data_complexity or {
    nested_maps = 0,
    struct_depth = 0,
    level = "low",
  }
end

local function boost_item(item, delta, mode)
  refresh_item(item)
  if mode == "dependency" then
    item.dependency_score = (item.dependency_score or 0) + delta
  else
    item.self_score = (item.self_score or 0) + delta
  end
  refresh_item(item)
end

local function text_document(bufnr)
  return { uri = vim.uri_from_bufnr(bufnr) }
end

local function has_client(bufnr)
  if vim.lsp.get_clients then
    return #vim.lsp.get_clients({ bufnr = bufnr }) > 0
  end

  local clients = vim.lsp.buf_get_clients(bufnr)
  if type(clients) ~= "table" then
    return false
  end

  if #clients > 0 then
    return true
  end

  return next(clients) ~= nil
end

local function request_sync(bufnr, method, params, timeout_ms)
  if not vim.lsp.buf_request_sync then
    return {}
  end

  local result = vim.lsp.buf_request_sync(bufnr, method, params, timeout_ms)
  if not result then
    return {}
  end

  local items = {}
  for _, response in pairs(result) do
    if response and response.result then
      items[#items + 1] = response.result
    end
  end

  return items
end

local function flatten_symbols(result, bucket)
  if type(result) ~= "table" then
    return
  end

  if result.kind and SYMBOL_KINDS[result.kind] and result.name then
    local range = result.selectionRange or result.range
    if range and range.start then
      bucket[#bucket + 1] = {
        name = result.name,
        line = (range.start.line or 0) + 1,
      }
    end
  end

  for _, child in ipairs(result.children or {}) do
    flatten_symbols(child, bucket)
  end
end

local function collect_document_symbols(bufnr, timeout_ms)
  local params = { textDocument = text_document(bufnr) }
  local all = request_sync(bufnr, "textDocument/documentSymbol", params, timeout_ms)
  local symbols = {}

  for _, payload in ipairs(all) do
    if payload[1] and payload[1].location then
      for _, item in ipairs(payload) do
        if item.name and item.location and item.location.range then
          symbols[#symbols + 1] = {
            name = item.name,
            line = (item.location.range.start.line or 0) + 1,
          }
        end
      end
    else
      for _, item in ipairs(payload) do
        flatten_symbols(item, symbols)
      end
    end
  end

  return symbols
end

local function count_incoming_calls(bufnr, line, timeout_ms)
  local pos = {
    textDocument = text_document(bufnr),
    position = { line = math.max(line - 1, 0), character = 0 },
  }

  local prepared = request_sync(bufnr, "textDocument/prepareCallHierarchy", pos, timeout_ms)
  local first_item

  for _, payload in ipairs(prepared) do
    if payload[1] then
      first_item = payload[1]
      break
    end
  end

  if not first_item then
    return 0
  end

  local incoming = request_sync(bufnr, "callHierarchy/incomingCalls", { item = first_item }, timeout_ms)
  local count = 0
  for _, payload in ipairs(incoming) do
    if type(payload) == "table" then
      count = count + #payload
    end
  end

  return count
end

local function find_by_name(items, name)
  local function normalize(value)
    return (value or ""):match("([^.]+)$") or ""
  end

  local expected = normalize(name)
  for _, item in ipairs(items) do
    if item.name == name or normalize(item.name) == expected then
      return item
    end
  end
  return nil
end

function M.enrich(bufnr, result, opts)
  local lsp_opts = opts.lsp or {}
  if not lsp_opts.enabled or not has_client(bufnr) then
    return result
  end

  local timeout = lsp_opts.timeout_ms or 800
  local symbols = collect_document_symbols(bufnr, timeout)

  local seen_entry = {}
  for _, item in ipairs(result.entry_points or {}) do
    seen_entry[item.name] = true
  end

  local seen_important = {}
  for _, item in ipairs(result.important_functions or {}) do
    seen_important[item.name] = true
  end

  if lsp_opts.enrich then
    for _, symbol in ipairs(symbols) do
      local important = find_by_name(result.important_functions, symbol.name)
      if important then
        boost_item(important, 2, "self")
      elseif not seen_important[symbol.name] then
        local added = {
          name = symbol.name,
          line = symbol.line,
          score = 2,
          self_score = 2,
          dependency_score = 0,
          breakdown = {
            branching = 0,
            nesting_depth = 0,
            loops = 0,
            calls = 0,
          },
          role = "utility",
          threshold = "simple",
          role_assessment = "acceptable",
          data_complexity = {
            nested_maps = 0,
            struct_depth = 0,
            level = "low",
          },
          visibility = "public",
          reason = "lsp-symbol",
          file = result.file,
        }
        refresh_item(added)
        result.important_functions[#result.important_functions + 1] = added
        seen_important[symbol.name] = true
      end

      if symbol.name == "main" or symbol.name == "init" then
        if not seen_entry[symbol.name] then
          local added_entry = {
            name = symbol.name,
            line = symbol.line,
            score = 4,
            self_score = 4,
            dependency_score = 0,
            entry_score = 4,
            breakdown = {
              branching = 0,
              nesting_depth = 0,
              loops = 0,
              calls = 0,
            },
            role = "utility",
            threshold = "simple",
            role_assessment = "acceptable",
            data_complexity = {
              nested_maps = 0,
              struct_depth = 0,
              level = "low",
            },
            reason = "lsp-symbol",
            file = result.file,
          }
          refresh_item(added_entry)
          result.entry_points[#result.entry_points + 1] = added_entry
          seen_entry[symbol.name] = true
        end
      end
    end

    local boosted = 0
    for _, item in ipairs(result.important_functions or {}) do
      if boosted >= 4 then
        break
      end
      local incoming = count_incoming_calls(bufnr, item.line or 1, timeout)
      if incoming > 0 then
        boost_item(item, math.min(incoming, 3), "dependency")
      end
      boosted = boosted + 1
    end
  end

  return result
end

return M
