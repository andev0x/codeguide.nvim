# codeguide.nvim

`codeguide.nvim` is a Neovim plugin that helps you understand unfamiliar codebases quickly by showing:

- likely entry points
- high-impact functions
- a compact execution flow
- relevant `TODO`/`FIXME` annotations

It is designed for onboarding, open source exploration, review, and debugging.

## Features

- Entry point detection from naming and file-context heuristics.
- Important function ranking using visibility, naming, proximity, and call relationships.
- Execution flow extraction (`main -> startServer -> handleRequest`).
- Focused signal rendering in-buffer with line highlights and virtual text.
- Summary view via floating window.
- Hybrid architecture:
  - Lua fallback engine (works out of the box)
  - optional Go engine (`codeguide-go`) for stronger AST-based analysis and cross-file package awareness.

## Requirements

- Neovim `>= 0.9`
- Treesitter parsers recommended for better fallback detection
- Go `>= 1.22` only if you want to build/use the optional Go engine

## Install

### lazy.nvim

```lua
{
  "andev0x/codeguide.nvim",
  config = function()
    require("codeguide").setup({
      auto_analyze = true,
      go = {
        enabled = true,
        binary = "codeguide-go",
      },
    })
  end,
}
```

### Build optional Go engine

```bash
go build -o bin/codeguide-go ./cmd/codeguide-go
```

Then either:

- add `bin` to `PATH`, or
- configure `go.binary` with an absolute path.

## Configuration

Defaults:

```lua
require("codeguide").setup({
  auto_analyze = true,
  debounce_ms = 200,
  max_functions = 6,
  max_flow_edges = 8,
  max_annotations = 6,
  highlight_annotations = true,
  notify_on_error = false,
  go = {
    enabled = true,
    binary = "codeguide-go",
    timeout_ms = 1200,
  },
})
```

## Commands

- `:CodeGuideAnalyze` analyze current buffer and render focused signals.
- `:CodeGuideExplain` open a compact summary window.
- `:CodeGuideClear` clear codeguide highlights for the current buffer.

## Health Check

Run:

```vim
:checkhealth codeguide
```

This validates Neovim compatibility and Go engine availability.

## Data Contract

Both engines return the same contract shape:

- `entry_points`
- `important_functions`
- `execution_flow`
- `annotations`

This keeps UI rendering engine-agnostic.

## Development

Run Go tests:

```bash
go test ./...
```

See `CONTRIBUTING.md` for workflow details.

## License

MIT. See `LICENSE`.

## Community

- Contribution guide: `CONTRIBUTING.md`
- Code of conduct: `CODE_OF_CONDUCT.md`
- CI: `.github/workflows/ci.yml`
