# codeguide.nvim

A Neovim plugin for rapid codebase comprehension and analysis. CodeGuide helps developers understand unfamiliar codebases by automatically identifying and visualizing the most important elements: entry points, critical functions, execution flows, and relevant annotations.

Designed for onboarding, open-source exploration, code review, and debugging workflows.

## Demo
<div align="center">
  <img src="https://raw.githubusercontent.com/andev0x/description-image-archive/refs/heads/main/codeguide/codeguide.gif" width="70%" alt="codeguide.nvim plugin" />
</div>

## Features

### Core Analysis

- Automatic entry point detection using naming conventions and file-context heuristics
- Function importance ranking based on visibility, naming, proximity, and call relationships
- Dual-component scoring system (self_score + dependency_score) for balanced assessment
- Complexity analysis by category (branching, nesting depth, loops, call counts)
- Function role classification (orchestrator, utility, core-logic) with contextual evaluation
- Execution flow extraction and visualization
- Hotspot identification with targeted refactoring suggestions
- Data structure complexity insights
- Comprehensive annotation detection (TODO, FIXME)

### User Interface

- In-buffer signal rendering with line highlights and virtual text scores
- Integrated window bar summary with optional breadcrumb navigation
- Interactive summary window with scrollable flow tree rendering
- Line jumping on selection for rapid navigation
- Telescope picker integration for efficient function browsing

### Engine Support

- Lua-based fallback engine (zero dependencies, works out of the box)
- Optional Go engine for enhanced AST-based analysis and cross-file package awareness
- Optional LSP integration for symbol enrichment and call hint analysis
- Unified data contract across all engines for consistent UI rendering

## Requirements

- Neovim 0.9 or later
- Treesitter parsers (recommended for improved detection accuracy)
- Go 1.22 or later (required only for building the optional Go engine)

## Installation

### Using lazy.nvim

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

### Building the Optional Go Engine

To enable the enhanced Go engine:

```bash
go build -o bin/codeguide-go ./cmd/codeguide-go
```

Then make the binary accessible via PATH or configure the absolute path in `go.binary`.

## Configuration

### Default Settings

```lua
require("codeguide").setup({
  auto_analyze = true,           -- Enable automatic analysis on buffer open
  debounce_ms = 500,             -- Debounce interval for analysis updates
  max_functions = 6,             -- Maximum important functions to display
  max_flow_edges = 8,            -- Maximum edges in execution flow visualization
  max_annotations = 6,           -- Maximum annotations (TODO/FIXME) to show
  highlight_annotations = true,  -- Enable annotation highlighting
  show_virtual_text = true,      -- Show virtual text scores
  show_signs = true,             -- Show signs in sign column
  show_winbar = true,            -- Show window bar summary
  show_statusline_breadcrumb = true,  -- Add breadcrumb to statusline
  notify_on_error = false,       -- Show error notifications
  lsp = {
    enabled = true,              -- Enable LSP integration
    enrich = true,               -- Enrich analysis with LSP data
    timeout_ms = 800,            -- LSP request timeout
  },
  go = {
    enabled = true,              -- Enable Go engine if available
    binary = "codeguide-go",     -- Path to Go binary
    timeout_ms = 1200,           -- Go engine timeout
    async = true,                -- Run Go engine asynchronously
  },
})
```

## Commands

### Core Commands

- `:CodeGuideAnalyze` - Analyze the current buffer and render visual signals
- `:CodeGuideExplain` - Open an interactive summary window with function details
- `:CodeGuideTelescope [important|entry]` - Browse functions using Telescope (when installed)
- `:CodeGuideClear` - Clear all CodeGuide highlights from the current buffer

### Statusline Integration

Add CodeGuide breadcrumb navigation to your statusline:

```lua
vim.o.statusline = "%f %= %{v:lua.require('codeguide').breadcrumb()}"
```

## Health Check

Verify your setup with:

```vim
:checkhealth codeguide
```

This command validates Neovim compatibility and confirms Go engine availability.

## Data Contract

Both the Lua and Go engines conform to the same unified data contract, ensuring consistent behavior across different analysis backends:

- `entry_points` - Detected entry points in the module
- `important_functions` - Functions ranked by importance score
- `execution_flow` - Call chain flow from entry to leaf functions
- `annotations` - TODO and FIXME markers with context
- `score_thresholds` - Complexity classification levels
- `hotspots` - Functions requiring refactoring attention
- `function_groups` - Related functions grouped by context
- `module_scores` - Aggregate scores by module
- `data_complexity` - Structure complexity metrics

This abstraction keeps the UI rendering layer engine-agnostic and maintainable.

## Development

### Running Tests

Execute the test suite:

```bash
go test ./...
```

### Contributing

CodeGuide welcomes contributions. Please review the following documents:

- `CONTRIBUTING.md` - Contribution workflow and guidelines
- `CODE_OF_CONDUCT.md` - Community standards and expectations
- `.github/workflows/ci.yml` - CI pipeline configuration

## License

This project is distributed under the MIT License. See the [LICENSE](License) file for details.

## Community and Support

- Report issues and request features on GitHub
- Contribute improvements via pull requests
- Follow our Code of Conduct for respectful collaboration
- Refer to [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines
