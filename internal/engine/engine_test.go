package engine

import (
	"os"
	"path/filepath"
	"testing"
)

func TestAnalyzeBuildsExpectedSignals(t *testing.T) {
	root := t.TempDir()

	mainFile := filepath.Join(root, "main.go")
	helpersFile := filepath.Join(root, "helpers.go")

	writeFile(t, mainFile, `package demo

// TODO: split startup wiring
func main() {
  startServer()
}

func startServer() {
  handleRequest()
}
`)

	writeFile(t, helpersFile, `package demo

func handleRequest() {}
`)

	result, err := Analyze(Options{File: mainFile, MaxFunctions: 6, MaxFlowEdges: 8})
	if err != nil {
		t.Fatalf("Analyze failed: %v", err)
	}

	if result.Source != "go-engine" {
		t.Fatalf("unexpected source: %s", result.Source)
	}

	if len(result.EntryPoints) == 0 || result.EntryPoints[0].Name != "main" {
		t.Fatalf("expected main as entry point, got %#v", result.EntryPoints)
	}

	if len(result.Annotations) == 0 || result.Annotations[0].Kind != "TODO" {
		t.Fatalf("expected TODO annotation, got %#v", result.Annotations)
	}

	if !containsEdge(result.ExecutionFlow, "main", "startServer") {
		t.Fatalf("expected main -> startServer edge, got %#v", result.ExecutionFlow)
	}

	if !containsEdge(result.ExecutionFlow, "startServer", "handleRequest") {
		t.Fatalf("expected startServer -> handleRequest edge, got %#v", result.ExecutionFlow)
	}
}

func writeFile(t *testing.T, path string, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatalf("failed writing fixture: %v", err)
	}
}

func containsEdge(edges []FlowEdge, from string, to string) bool {
	for _, edge := range edges {
		if edge.From == from && edge.To == to {
			return true
		}
	}
	return false
}
