package engine

import (
	"bufio"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type Options struct {
	File         string
	MaxFunctions int
	MaxFlowEdges int
}

type Result struct {
	Source             string              `json:"source"`
	File               string              `json:"file"`
	EntryPoints        []EntryPoint        `json:"entry_points"`
	ImportantFunctions []ImportantFunction `json:"important_functions"`
	ExecutionFlow      []FlowEdge          `json:"execution_flow"`
	Annotations        []Annotation        `json:"annotations"`
	FunctionRanges     []FunctionRange     `json:"function_ranges"`
}

type EntryPoint struct {
	Name   string `json:"name"`
	Line   int    `json:"line"`
	Score  int    `json:"score"`
	Reason string `json:"reason"`
	File   string `json:"file,omitempty"`
}

type ImportantFunction struct {
	Name       string `json:"name"`
	Line       int    `json:"line"`
	Score      int    `json:"score"`
	Visibility string `json:"visibility"`
	File       string `json:"file,omitempty"`
}

type FlowEdge struct {
	From     string `json:"from"`
	To       string `json:"to"`
	Line     int    `json:"line"`
	FromFile string `json:"from_file,omitempty"`
	ToFile   string `json:"to_file,omitempty"`
}

type Annotation struct {
	Kind string `json:"kind"`
	Line int    `json:"line"`
	Text string `json:"text"`
}

type FunctionRange struct {
	Name    string `json:"name"`
	Line    int    `json:"line"`
	EndLine int    `json:"end_line"`
	File    string `json:"file,omitempty"`
}

type functionInfo struct {
	Canonical string
	Simple    string
	File      string
	Line      int
	EndLine   int
	Exported  bool
	Calls     map[string]int
}

type edgeInfo struct {
	From *functionInfo
	To   *functionInfo
	Line int
}

var nameWeights = []struct {
	pattern string
	weight  int
}{
	{pattern: "main", weight: 8},
	{pattern: "start", weight: 5},
	{pattern: "run", weight: 4},
	{pattern: "bootstrap", weight: 5},
	{pattern: "setup", weight: 4},
	{pattern: "init", weight: 5},
	{pattern: "serve", weight: 4},
	{pattern: "handle", weight: 4},
	{pattern: "process", weight: 3},
}

var entryFileHints = map[string]bool{
	"main":   true,
	"index":  true,
	"app":    true,
	"server": true,
}

func Analyze(opts Options) (Result, error) {
	if opts.File == "" {
		return Result{}, errors.New("missing file path")
	}

	if opts.MaxFunctions <= 0 {
		opts.MaxFunctions = 6
	}
	if opts.MaxFlowEdges <= 0 {
		opts.MaxFlowEdges = 8
	}

	absFile, err := filepath.Abs(opts.File)
	if err != nil {
		return Result{}, err
	}
	absFile = filepath.Clean(absFile)

	targetPackage, err := readPackageName(absFile)
	if err != nil {
		return Result{}, err
	}

	functions, err := collectFunctions(absFile, targetPackage)
	if err != nil {
		return Result{}, err
	}

	targetFunctions := make([]*functionInfo, 0)
	for _, fn := range functions {
		if filepath.Clean(fn.File) == absFile {
			targetFunctions = append(targetFunctions, fn)
		}
	}

	entries := chooseEntryPoints(absFile, targetFunctions)
	hiddenEntries := collectHiddenEntryPoints(absFile, functions)
	entries = mergeEntryPoints(entries, hiddenEntries)
	edges, outgoing, incoming := buildEdges(functions)
	important := rankFunctions(targetFunctions, entries, outgoing, incoming, opts.MaxFunctions)
	flow := selectFlow(entries, important, edges, opts.MaxFlowEdges)
	ranges := makeFunctionRanges(targetFunctions)

	annotations, err := scanAnnotations(absFile)
	if err != nil {
		return Result{}, err
	}

	return Result{
		Source:             "go-engine",
		File:               absFile,
		EntryPoints:        entries,
		ImportantFunctions: important,
		ExecutionFlow:      flow,
		Annotations:        annotations,
		FunctionRanges:     ranges,
	}, nil
}

func readPackageName(filePath string) (string, error) {
	fset := token.NewFileSet()
	parsed, err := parser.ParseFile(fset, filePath, nil, parser.PackageClauseOnly)
	if err != nil {
		return "", err
	}
	if parsed.Name == nil {
		return "", errors.New("unable to determine package name")
	}
	return parsed.Name.Name, nil
}

func collectFunctions(targetFile string, targetPackage string) ([]*functionInfo, error) {
	directory := filepath.Dir(targetFile)
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, directory, func(info os.FileInfo) bool {
		name := info.Name()
		return strings.HasSuffix(name, ".go") && !strings.HasSuffix(name, "_test.go")
	}, parser.ParseComments)
	if err != nil {
		return nil, err
	}

	pkg := pkgs[targetPackage]
	if pkg == nil {
		for _, anyPkg := range pkgs {
			pkg = anyPkg
			break
		}
	}
	if pkg == nil {
		return nil, errors.New("unable to parse package files")
	}

	fileNames := make([]string, 0, len(pkg.Files))
	for name := range pkg.Files {
		fileNames = append(fileNames, filepath.Clean(name))
	}
	sort.Strings(fileNames)

	funcs := make([]*functionInfo, 0)
	for _, fileName := range fileNames {
		fileNode := pkg.Files[fileName]
		decls := fileNode.Decls
		for _, decl := range decls {
			fnDecl, ok := decl.(*ast.FuncDecl)
			if !ok {
				continue
			}

			canonical, simple := functionNames(fnDecl)
			if simple == "" {
				continue
			}

			info := &functionInfo{
				Canonical: canonical,
				Simple:    simple,
				File:      filepath.Clean(fileName),
				Line:      fset.Position(fnDecl.Pos()).Line,
				EndLine:   fset.Position(fnDecl.End()).Line,
				Exported:  ast.IsExported(simple),
				Calls:     map[string]int{},
			}

			if fnDecl.Body != nil {
				ast.Inspect(fnDecl.Body, func(node ast.Node) bool {
					call, ok := node.(*ast.CallExpr)
					if !ok {
						return true
					}
					callee := callName(call.Fun)
					if callee != "" {
						info.Calls[callee] = info.Calls[callee] + 1
					}
					return true
				})
			}

			funcs = append(funcs, info)
		}
	}

	sort.Slice(funcs, func(i, j int) bool {
		if funcs[i].File == funcs[j].File {
			return funcs[i].Line < funcs[j].Line
		}
		return funcs[i].File < funcs[j].File
	})

	return funcs, nil
}

func functionNames(fnDecl *ast.FuncDecl) (string, string) {
	if fnDecl.Name == nil {
		return "", ""
	}

	simple := fnDecl.Name.Name
	if fnDecl.Recv == nil || len(fnDecl.Recv.List) == 0 {
		return simple, simple
	}

	recvName := receiverName(fnDecl.Recv.List[0].Type)
	if recvName == "" {
		return simple, simple
	}

	return recvName + "." + simple, simple
}

func receiverName(expr ast.Expr) string {
	switch value := expr.(type) {
	case *ast.Ident:
		return value.Name
	case *ast.StarExpr:
		if ident, ok := value.X.(*ast.Ident); ok {
			return ident.Name
		}
	}
	return ""
}

func callName(expr ast.Expr) string {
	switch value := expr.(type) {
	case *ast.Ident:
		return value.Name
	case *ast.SelectorExpr:
		return value.Sel.Name
	default:
		return ""
	}
}

func chooseEntryPoints(filePath string, funcs []*functionInfo) []EntryPoint {
	entries := make([]EntryPoint, 0)
	fileHint := strings.ToLower(strings.TrimSuffix(filepath.Base(filePath), filepath.Ext(filePath)))

	for _, fn := range funcs {
		score := scoreName(fn.Canonical)
		if entryFileHints[fileHint] && fn.Line <= 120 {
			score += 2
		}
		if fn.Simple == "main" {
			score += 4
		}
		if score > 0 {
			entries = append(entries, EntryPoint{
				Name:   fn.Canonical,
				Line:   fn.Line,
				Score:  score,
				Reason: "entry-like naming",
				File:   fn.File,
			})
		}
	}

	sort.Slice(entries, func(i, j int) bool {
		if entries[i].Score == entries[j].Score {
			return entries[i].Line < entries[j].Line
		}
		return entries[i].Score > entries[j].Score
	})

	if len(entries) == 0 && len(funcs) > 0 {
		entries = append(entries, EntryPoint{
			Name:   funcs[0].Canonical,
			Line:   funcs[0].Line,
			Score:  1,
			Reason: "first function in file",
			File:   funcs[0].File,
		})
	}

	if len(entries) > 3 {
		entries = entries[:3]
	}

	return entries
}

func buildEdges(funcs []*functionInfo) ([]edgeInfo, map[string]int, map[string]int) {
	edges := make([]edgeInfo, 0)
	outgoing := make(map[string]int, len(funcs))
	incoming := make(map[string]int, len(funcs))
	seen := map[string]bool{}

	bySimple := make(map[string][]*functionInfo)
	for _, fn := range funcs {
		bySimple[fn.Simple] = append(bySimple[fn.Simple], fn)
		outgoing[fn.Canonical] = 0
		incoming[fn.Canonical] = 0
	}

	for _, candidates := range bySimple {
		sort.Slice(candidates, func(i, j int) bool {
			if candidates[i].File == candidates[j].File {
				return candidates[i].Line < candidates[j].Line
			}
			return candidates[i].File < candidates[j].File
		})
	}

	for _, caller := range funcs {
		callees := make([]string, 0, len(caller.Calls))
		for name := range caller.Calls {
			callees = append(callees, name)
		}
		sort.Strings(callees)

		for _, callee := range callees {
			targets := bySimple[callee]
			if len(targets) == 0 {
				continue
			}

			target := chooseTarget(caller, targets)
			if target == nil || target.Canonical == caller.Canonical {
				continue
			}

			key := caller.Canonical + "->" + target.Canonical
			if seen[key] {
				continue
			}
			seen[key] = true

			edges = append(edges, edgeInfo{From: caller, To: target, Line: caller.Line})
			outgoing[caller.Canonical] = outgoing[caller.Canonical] + 1
			incoming[target.Canonical] = incoming[target.Canonical] + 1
		}
	}

	sort.Slice(edges, func(i, j int) bool {
		if edges[i].Line == edges[j].Line {
			return edges[i].From.Canonical < edges[j].From.Canonical
		}
		return edges[i].Line < edges[j].Line
	})

	return edges, outgoing, incoming
}

func chooseTarget(caller *functionInfo, targets []*functionInfo) *functionInfo {
	for _, target := range targets {
		if target.File == caller.File {
			return target
		}
	}
	return targets[0]
}

func rankFunctions(funcs []*functionInfo, entries []EntryPoint, outgoing map[string]int, incoming map[string]int, maxFunctions int) []ImportantFunction {
	ranked := make([]ImportantFunction, 0, len(funcs))
	entrySet := map[string]bool{}
	for _, entry := range entries {
		entrySet[entry.Name] = true
	}

	for _, fn := range funcs {
		score := scoreName(fn.Canonical)
		if fn.Exported {
			score += 2
		}
		if entrySet[fn.Canonical] {
			score += 5
		}
		score += min(outgoing[fn.Canonical], 3)
		score += min(incoming[fn.Canonical], 2)

		distance := lineDistanceToEntry(fn.Line, entries)
		if distance <= 20 {
			score += 3
		} else if distance <= 60 {
			score += 2
		} else if distance <= 120 {
			score += 1
		}

		visibility := "private"
		if fn.Exported {
			visibility = "public"
		}

		ranked = append(ranked, ImportantFunction{
			Name:       fn.Canonical,
			Line:       fn.Line,
			Score:      score,
			Visibility: visibility,
			File:       fn.File,
		})
	}

	sort.Slice(ranked, func(i, j int) bool {
		if ranked[i].Score == ranked[j].Score {
			return ranked[i].Line < ranked[j].Line
		}
		return ranked[i].Score > ranked[j].Score
	})

	if len(ranked) > maxFunctions {
		ranked = ranked[:maxFunctions]
	}

	return ranked
}

func selectFlow(entries []EntryPoint, important []ImportantFunction, edges []edgeInfo, maxFlowEdges int) []FlowEdge {
	interesting := map[string]bool{}
	for _, entry := range entries {
		interesting[entry.Name] = true
	}
	for _, item := range important {
		interesting[item.Name] = true
	}

	flow := make([]FlowEdge, 0)
	for _, edge := range edges {
		from := edge.From.Canonical
		to := edge.To.Canonical
		if interesting[from] || interesting[to] {
			flow = append(flow, FlowEdge{From: from, To: to, Line: edge.Line, FromFile: edge.From.File, ToFile: edge.To.File})
		}
	}

	if len(flow) == 0 {
		for _, edge := range edges {
			flow = append(flow, FlowEdge{From: edge.From.Canonical, To: edge.To.Canonical, Line: edge.Line, FromFile: edge.From.File, ToFile: edge.To.File})
		}
	}

	if len(flow) > maxFlowEdges {
		flow = flow[:maxFlowEdges]
	}

	return flow
}

func scanAnnotations(filePath string) ([]Annotation, error) {
	handle, err := os.Open(filePath)
	if err != nil {
		return nil, err
	}
	defer handle.Close()

	annotations := make([]Annotation, 0)
	scanner := bufio.NewScanner(handle)
	line := 0

	for scanner.Scan() {
		line++
		text := scanner.Text()
		upper := strings.ToUpper(text)
		kind := ""
		if strings.Contains(upper, "TODO") {
			kind = "TODO"
		} else if strings.Contains(upper, "FIXME") {
			kind = "FIXME"
		}
		if kind != "" {
			annotations = append(annotations, Annotation{Kind: kind, Line: line, Text: strings.TrimSpace(text)})
		}
	}

	if err := scanner.Err(); err != nil {
		return nil, err
	}

	return annotations, nil
}

func scoreName(name string) int {
	lower := strings.ToLower(name)
	score := 0
	for _, item := range nameWeights {
		if strings.Contains(lower, item.pattern) {
			score += item.weight
		}
	}
	return score
}

func collectHiddenEntryPoints(targetFile string, funcs []*functionInfo) []EntryPoint {
	entries := make([]EntryPoint, 0)
	for _, fn := range funcs {
		if fn.Simple != "init" {
			continue
		}
		score := 6
		if filepath.Clean(fn.File) != filepath.Clean(targetFile) {
			score += 1
		}
		entries = append(entries, EntryPoint{
			Name:   fn.Canonical,
			Line:   fn.Line,
			Score:  score,
			Reason: "hidden entry: init",
			File:   fn.File,
		})
	}

	for _, fn := range funcs {
		if strings.EqualFold(fn.Simple, "ServeHTTP") || strings.EqualFold(fn.Simple, "Handle") {
			entries = append(entries, EntryPoint{
				Name:   fn.Canonical,
				Line:   fn.Line,
				Score:  5,
				Reason: "hidden entry: interface hook",
				File:   fn.File,
			})
		}
	}

	return entries
}

func mergeEntryPoints(primary []EntryPoint, extras []EntryPoint) []EntryPoint {
	merged := make([]EntryPoint, 0, len(primary)+len(extras))
	seen := map[string]bool{}

	appendUnique := func(item EntryPoint) {
		key := item.Name + ":" + item.File
		if seen[key] {
			return
		}
		seen[key] = true
		merged = append(merged, item)
	}

	for _, item := range primary {
		appendUnique(item)
	}
	for _, item := range extras {
		appendUnique(item)
	}

	sort.Slice(merged, func(i, j int) bool {
		if merged[i].Score == merged[j].Score {
			return merged[i].Line < merged[j].Line
		}
		return merged[i].Score > merged[j].Score
	})

	if len(merged) > 5 {
		merged = merged[:5]
	}

	return merged
}

func makeFunctionRanges(funcs []*functionInfo) []FunctionRange {
	ranges := make([]FunctionRange, 0, len(funcs))
	for _, fn := range funcs {
		endLine := fn.EndLine
		if endLine < fn.Line {
			endLine = fn.Line
		}
		ranges = append(ranges, FunctionRange{
			Name:    fn.Canonical,
			Line:    fn.Line,
			EndLine: endLine,
			File:    fn.File,
		})
	}
	return ranges
}

func lineDistanceToEntry(line int, entries []EntryPoint) int {
	best := 100000
	for _, entry := range entries {
		distance := abs(line - entry.Line)
		if distance < best {
			best = distance
		}
	}
	return best
}

func min(value int, max int) int {
	if value < max {
		return value
	}
	return max
}

func abs(value int) int {
	if value < 0 {
		return -value
	}
	return value
}
