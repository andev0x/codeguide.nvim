# Contributing

Thanks for contributing to `codeguide.nvim`.

## Development Setup

1. Clone the repository.
2. Build the optional Go engine if needed:

   ```bash
   go build -o bin/codeguide-go ./cmd/codeguide-go
   ```

3. Run tests:

   ```bash
   go test ./...
   ```

## Architecture

- `plugin/codeguide.lua`: plugin bootstrap.
- `lua/codeguide/`: Lua integration, fallback analysis, UI, health checks.
- `cmd/codeguide-go/`: Go CLI entry for deep analysis.
- `internal/engine/`: Go AST analysis implementation.

Both engines must produce the same output contract consumed by UI.

## Pull Requests

- Keep changes focused.
- Add or update tests for behavior changes.
- Update docs when user-visible behavior changes.
- Ensure `go test ./...` passes.
