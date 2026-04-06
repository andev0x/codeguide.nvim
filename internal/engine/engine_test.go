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

	if result.EntryPoints[0].SelfScore <= 0 {
		t.Fatalf("expected entry point self score, got %#v", result.EntryPoints[0])
	}

	if result.EntryPoints[0].Score != result.EntryPoints[0].SelfScore+result.EntryPoints[0].DependencyScore {
		t.Fatalf("entry score should split into self + deps, got %#v", result.EntryPoints[0])
	}

	if result.EntryPoints[0].Breakdown.Calls == 0 {
		t.Fatalf("expected complexity breakdown with calls, got %#v", result.EntryPoints[0].Breakdown)
	}

	if result.EntryPoints[0].Role == "" || result.EntryPoints[0].Threshold == "" || result.EntryPoints[0].RoleAssessment == "" {
		t.Fatalf("expected role metadata, got %#v", result.EntryPoints[0])
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

	if !hasContribution(result.ExecutionFlow, "main", "startServer") {
		t.Fatalf("expected flow contribution for main -> startServer, got %#v", result.ExecutionFlow)
	}

	if len(result.FunctionRanges) == 0 {
		t.Fatalf("expected function ranges in result")
	}

	if len(result.ScoreThresholds) == 0 {
		t.Fatalf("expected score thresholds in result")
	}

	if len(result.FunctionGroups) == 0 {
		t.Fatalf("expected grouped function data in result")
	}

	if len(result.ModuleScores) == 0 {
		t.Fatalf("expected module scores in result")
	}

	if result.DataComplexity.Level == "" {
		t.Fatalf("expected data complexity insight in result")
	}
}

func TestAnalyzeDetectsHiddenInitEntry(t *testing.T) {
	root := t.TempDir()

	mainFile := filepath.Join(root, "main.go")
	writeFile(t, mainFile, `package demo

func init() {}

func main() {}
`)

	result, err := Analyze(Options{File: mainFile, MaxFunctions: 6, MaxFlowEdges: 8})
	if err != nil {
		t.Fatalf("Analyze failed: %v", err)
	}

	if !containsEntry(result.EntryPoints, "init") {
		t.Fatalf("expected hidden init entry point, got %#v", result.EntryPoints)
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

func containsEntry(entries []EntryPoint, name string) bool {
	for _, entry := range entries {
		if entry.Name == name {
			return true
		}
	}
	return false
}

func hasContribution(edges []FlowEdge, from string, to string) bool {
	for _, edge := range edges {
		if edge.From == from && edge.To == to && edge.Contribution >= 0 {
			return true
		}
	}
	return false
}
