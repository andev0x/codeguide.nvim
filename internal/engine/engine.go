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

type ComplexityBreakdown struct {
	Branching    int `json:"branching"`
	NestingDepth int `json:"nesting_depth"`
	Loops        int `json:"loops"`
	Calls        int `json:"calls"`
}

type DataComplexity struct {
	NestedMaps  int    `json:"nested_maps"`
	StructDepth int    `json:"struct_depth"`
	Level       string `json:"level"`
}

type EntryPoint struct {
	Name            string              `json:"name"`
	Line            int                 `json:"line"`
	Score           int                 `json:"score"`
	SelfScore       int                 `json:"self_score"`
	DependencyScore int                 `json:"dependency_score"`
	EntryScore      int                 `json:"entry_score"`
	Breakdown       ComplexityBreakdown `json:"breakdown"`
	Role            string              `json:"role"`
	Threshold       string              `json:"threshold"`
	RoleAssessment  string              `json:"role_assessment"`
	Hotspots        []string            `json:"hotspots,omitempty"`
	Suggestions     []string            `json:"suggestions,omitempty"`
	DataComplexity  DataComplexity      `json:"data_complexity"`
	Reason          string              `json:"reason"`
	File            string              `json:"file,omitempty"`
}

type ImportantFunction struct {
	Name            string              `json:"name"`
	Line            int                 `json:"line"`
	Score           int                 `json:"score"`
	SelfScore       int                 `json:"self_score"`
	DependencyScore int                 `json:"dependency_score"`
	Breakdown       ComplexityBreakdown `json:"breakdown"`
	Role            string              `json:"role"`
	Threshold       string              `json:"threshold"`
	RoleAssessment  string              `json:"role_assessment"`
	Hotspots        []string            `json:"hotspots,omitempty"`
	Suggestions     []string            `json:"suggestions,omitempty"`
	DataComplexity  DataComplexity      `json:"data_complexity"`
	Visibility      string              `json:"visibility"`
	File            string              `json:"file,omitempty"`
}

type FlowEdge struct {
	From         string `json:"from"`
	To           string `json:"to"`
	Line         int    `json:"line"`
	Contribution int    `json:"contribution"`
	FromFile     string `json:"from_file,omitempty"`
	ToFile       string `json:"to_file,omitempty"`
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

type ScoreThreshold struct {
	Label string `json:"label"`
	Min   int    `json:"min"`
	Max   int    `json:"max"`
}

type Hotspot struct {
	Name       string `json:"name"`
	Line       int    `json:"line"`
	Score      int    `json:"score"`
	Role       string `json:"role"`
	Reason     string `json:"reason"`
	Suggestion string `json:"suggestion,omitempty"`
	File       string `json:"file,omitempty"`
}

type FunctionGroup struct {
	Name          string   `json:"name"`
	Kind          string   `json:"kind"`
	Score         int      `json:"score"`
	FunctionCount int      `json:"function_count"`
	Functions     []string `json:"functions"`
}

type ModuleScore struct {
	Module        string `json:"module"`
	Score         int    `json:"score"`
	FunctionCount int    `json:"function_count"`
}

type TypeComplexity struct {
	Name        string `json:"name"`
	NestedMaps  int    `json:"nested_maps"`
	StructDepth int    `json:"struct_depth"`
	File        string `json:"file,omitempty"`
}

type DataComplexityInsight struct {
	Level       string           `json:"level"`
	NestedMaps  int              `json:"nested_maps"`
	StructDepth int              `json:"struct_depth"`
	Types       []TypeComplexity `json:"types"`
}

type Result struct {
	Source             string                `json:"source"`
	File               string                `json:"file"`
	EntryPoints        []EntryPoint          `json:"entry_points"`
	ImportantFunctions []ImportantFunction   `json:"important_functions"`
	ExecutionFlow      []FlowEdge            `json:"execution_flow"`
	Annotations        []Annotation          `json:"annotations"`
	FunctionRanges     []FunctionRange       `json:"function_ranges"`
	ScoreThresholds    []ScoreThreshold      `json:"score_thresholds"`
	Hotspots           []Hotspot             `json:"hotspots"`
	FunctionGroups     []FunctionGroup       `json:"function_groups"`
	ModuleScores       []ModuleScore         `json:"module_scores"`
	DataComplexity     DataComplexityInsight `json:"data_complexity"`
}

type functionInfo struct {
	Canonical string
	Simple    string
	File      string
	Line      int
	EndLine   int
	Exported  bool
	Calls     map[string]int

	SelfScore       int
	DependencyScore int
	TotalScore      int
	EntryScore      int

	Branching    int
	NestingDepth int
	Loops        int
	CallCount    int

	Role           string
	Threshold      string
	RoleAssessment string
	Hotspots       []string
	Suggestions    []string
	Data           DataComplexity
}

type edgeInfo struct {
	From         *functionInfo
	To           *functionInfo
	Line         int
	Contribution int
}

type namedType struct {
	Expr ast.Expr
	File string
}

type typeIndex struct {
	Named map[string]namedType
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

var builtinTypes = map[string]bool{
	"bool": true, "byte": true, "complex64": true, "complex128": true, "error": true,
	"float32": true, "float64": true, "int": true, "int8": true, "int16": true,
	"int32": true, "int64": true, "rune": true, "string": true, "uint": true,
	"uint8": true, "uint16": true, "uint32": true, "uint64": true, "uintptr": true,
	"any": true, "comparable": true,
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

	functions, types, err := collectFunctions(absFile, targetPackage)
	if err != nil {
		return Result{}, err
	}

	targetFunctions := make([]*functionInfo, 0)
	for _, fn := range functions {
		if filepath.Clean(fn.File) == absFile {
			targetFunctions = append(targetFunctions, fn)
		}
	}

	edges := buildEdges(functions)
	computeDependencyScores(functions, edges)
	applyDerivedSignals(functions)

	entries := chooseEntryPoints(absFile, targetFunctions)
	hiddenEntries := collectHiddenEntryPoints(absFile, functions)
	entries = mergeEntryPoints(entries, hiddenEntries)

	important := rankFunctions(targetFunctions, opts.MaxFunctions)
	flow := selectFlow(entries, important, edges, opts.MaxFlowEdges)
	ranges := makeFunctionRanges(targetFunctions)
	hotspots := collectHotspots(targetFunctions, 8)
	groups := buildFunctionGroups(entries, functions, edges)
	modules := buildModuleScores(functions)
	dataInsight := buildDataComplexityInsight(types)

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
		ScoreThresholds:    defaultScoreThresholds(),
		Hotspots:           hotspots,
		FunctionGroups:     groups,
		ModuleScores:       modules,
		DataComplexity:     dataInsight,
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

func collectFunctions(targetFile string, targetPackage string) ([]*functionInfo, *typeIndex, error) {
	directory := filepath.Dir(targetFile)
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, directory, func(info os.FileInfo) bool {
		name := info.Name()
		return strings.HasSuffix(name, ".go") && !strings.HasSuffix(name, "_test.go")
	}, parser.ParseComments)
	if err != nil {
		return nil, nil, err
	}

	pkg := pkgs[targetPackage]
	if pkg == nil {
		for _, anyPkg := range pkgs {
			pkg = anyPkg
			break
		}
	}
	if pkg == nil {
		return nil, nil, errors.New("unable to parse package files")
	}

	fileNames := make([]string, 0, len(pkg.Files))
	for name := range pkg.Files {
		fileNames = append(fileNames, filepath.Clean(name))
	}
	sort.Strings(fileNames)

	types := &typeIndex{Named: map[string]namedType{}}
	for _, fileName := range fileNames {
		fileNode := pkg.Files[fileName]
		for _, decl := range fileNode.Decls {
			gen, ok := decl.(*ast.GenDecl)
			if !ok || gen.Tok != token.TYPE {
				continue
			}
			for _, spec := range gen.Specs {
				typeSpec, ok := spec.(*ast.TypeSpec)
				if !ok || typeSpec.Name == nil || typeSpec.Type == nil {
					continue
				}
				types.Named[typeSpec.Name.Name] = namedType{Expr: typeSpec.Type, File: filepath.Clean(fileName)}
			}
		}
	}

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
				Data:      DataComplexity{Level: "low"},
			}

			analyzeFunctionDecl(fnDecl, info, types)
			info.SelfScore = info.Branching + info.NestingDepth + info.Loops + info.CallCount
			info.TotalScore = info.SelfScore
			info.Data.Level = dataComplexityLevel(info.Data.NestedMaps, info.Data.StructDepth)

			funcs = append(funcs, info)
		}
	}

	sort.Slice(funcs, func(i, j int) bool {
		if funcs[i].File == funcs[j].File {
			return funcs[i].Line < funcs[j].Line
		}
		return funcs[i].File < funcs[j].File
	})

	return funcs, types, nil
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

func analyzeFunctionDecl(fnDecl *ast.FuncDecl, info *functionInfo, types *typeIndex) {
	if fnDecl.Type != nil {
		analyzeFieldListTypes(fnDecl.Type.Params, info, types)
		analyzeFieldListTypes(fnDecl.Type.Results, info, types)
	}

	if fnDecl.Body == nil {
		return
	}

	analyzeBlock(fnDecl.Body, 0, info, types)
}

func analyzeFieldListTypes(fields *ast.FieldList, info *functionInfo, types *typeIndex) {
	if fields == nil {
		return
	}
	for _, field := range fields.List {
		if field != nil && field.Type != nil {
			updateDataFromTypeExpr(&info.Data, field.Type, types)
		}
	}
}

func analyzeBlock(block *ast.BlockStmt, depth int, info *functionInfo, types *typeIndex) {
	if block == nil {
		return
	}
	for _, stmt := range block.List {
		analyzeStmt(stmt, depth, info, types)
	}
}

func analyzeStmt(stmt ast.Stmt, depth int, info *functionInfo, types *typeIndex) {
	if stmt == nil {
		return
	}

	switch value := stmt.(type) {
	case *ast.BlockStmt:
		analyzeBlock(value, depth, info, types)
	case *ast.IfStmt:
		info.Branching++
		updateNesting(info, depth+1)
		analyzeStmt(value.Init, depth, info, types)
		analyzeExpr(value.Cond, depth, info, types)
		analyzeBlock(value.Body, depth+1, info, types)
		if value.Else != nil {
			analyzeStmt(value.Else, depth, info, types)
		}
	case *ast.SwitchStmt:
		cases := len(value.Body.List)
		if cases == 0 {
			cases = 1
		}
		info.Branching += cases
		updateNesting(info, depth+1)
		analyzeStmt(value.Init, depth, info, types)
		analyzeExpr(value.Tag, depth, info, types)
		for _, item := range value.Body.List {
			if clause, ok := item.(*ast.CaseClause); ok {
				for _, entry := range clause.List {
					analyzeExpr(entry, depth+1, info, types)
				}
				for _, bodyStmt := range clause.Body {
					analyzeStmt(bodyStmt, depth+1, info, types)
				}
			}
		}
	case *ast.TypeSwitchStmt:
		cases := len(value.Body.List)
		if cases == 0 {
			cases = 1
		}
		info.Branching += cases
		updateNesting(info, depth+1)
		analyzeStmt(value.Init, depth, info, types)
		analyzeStmt(value.Assign, depth, info, types)
		for _, item := range value.Body.List {
			if clause, ok := item.(*ast.CaseClause); ok {
				for _, bodyStmt := range clause.Body {
					analyzeStmt(bodyStmt, depth+1, info, types)
				}
			}
		}
	case *ast.SelectStmt:
		cases := len(value.Body.List)
		if cases == 0 {
			cases = 1
		}
		info.Branching += cases
		updateNesting(info, depth+1)
		for _, item := range value.Body.List {
			if clause, ok := item.(*ast.CommClause); ok {
				analyzeStmt(clause.Comm, depth+1, info, types)
				for _, bodyStmt := range clause.Body {
					analyzeStmt(bodyStmt, depth+1, info, types)
				}
			}
		}
	case *ast.ForStmt:
		info.Loops++
		updateNesting(info, depth+1)
		analyzeStmt(value.Init, depth, info, types)
		analyzeExpr(value.Cond, depth, info, types)
		analyzeStmt(value.Post, depth, info, types)
		analyzeBlock(value.Body, depth+1, info, types)
	case *ast.RangeStmt:
		info.Loops++
		updateNesting(info, depth+1)
		analyzeExpr(value.Key, depth, info, types)
		analyzeExpr(value.Value, depth, info, types)
		analyzeExpr(value.X, depth, info, types)
		analyzeBlock(value.Body, depth+1, info, types)
	case *ast.ExprStmt:
		analyzeExpr(value.X, depth, info, types)
	case *ast.AssignStmt:
		for _, lhs := range value.Lhs {
			analyzeExpr(lhs, depth, info, types)
		}
		for _, rhs := range value.Rhs {
			analyzeExpr(rhs, depth, info, types)
		}
	case *ast.DeclStmt:
		analyzeDecl(value.Decl, depth, info, types)
	case *ast.ReturnStmt:
		for _, expr := range value.Results {
			analyzeExpr(expr, depth, info, types)
		}
	case *ast.GoStmt:
		analyzeExpr(value.Call, depth, info, types)
	case *ast.DeferStmt:
		analyzeExpr(value.Call, depth, info, types)
	case *ast.SendStmt:
		analyzeExpr(value.Chan, depth, info, types)
		analyzeExpr(value.Value, depth, info, types)
	case *ast.IncDecStmt:
		analyzeExpr(value.X, depth, info, types)
	case *ast.LabeledStmt:
		analyzeStmt(value.Stmt, depth, info, types)
	case *ast.BranchStmt:
		return
	case *ast.EmptyStmt:
		return
	default:
		ast.Inspect(stmt, func(node ast.Node) bool {
			expr, ok := node.(ast.Expr)
			if ok {
				analyzeExpr(expr, depth, info, types)
			}
			return true
		})
	}
}

func analyzeDecl(decl ast.Decl, depth int, info *functionInfo, types *typeIndex) {
	if decl == nil {
		return
	}
	gen, ok := decl.(*ast.GenDecl)
	if !ok {
		return
	}
	for _, spec := range gen.Specs {
		switch value := spec.(type) {
		case *ast.ValueSpec:
			if value.Type != nil {
				updateDataFromTypeExpr(&info.Data, value.Type, types)
			}
			for _, expr := range value.Values {
				analyzeExpr(expr, depth, info, types)
			}
		case *ast.TypeSpec:
			if value.Type != nil {
				updateDataFromTypeExpr(&info.Data, value.Type, types)
			}
		}
	}
}

func analyzeExpr(expr ast.Expr, depth int, info *functionInfo, types *typeIndex) {
	if expr == nil {
		return
	}

	switch value := expr.(type) {
	case *ast.CallExpr:
		info.CallCount++
		callee := callName(value.Fun)
		if callee != "" {
			info.Calls[callee] = info.Calls[callee] + 1
		}
		analyzeExpr(value.Fun, depth, info, types)
		for _, arg := range value.Args {
			analyzeExpr(arg, depth, info, types)
		}
	case *ast.BinaryExpr:
		analyzeExpr(value.X, depth, info, types)
		analyzeExpr(value.Y, depth, info, types)
	case *ast.UnaryExpr:
		analyzeExpr(value.X, depth, info, types)
	case *ast.ParenExpr:
		analyzeExpr(value.X, depth, info, types)
	case *ast.SelectorExpr:
		analyzeExpr(value.X, depth, info, types)
	case *ast.IndexExpr:
		analyzeExpr(value.X, depth, info, types)
		analyzeExpr(value.Index, depth, info, types)
	case *ast.IndexListExpr:
		analyzeExpr(value.X, depth, info, types)
		for _, index := range value.Indices {
			analyzeExpr(index, depth, info, types)
		}
	case *ast.SliceExpr:
		analyzeExpr(value.X, depth, info, types)
		analyzeExpr(value.Low, depth, info, types)
		analyzeExpr(value.High, depth, info, types)
		analyzeExpr(value.Max, depth, info, types)
	case *ast.CompositeLit:
		if value.Type != nil {
			updateDataFromTypeExpr(&info.Data, value.Type, types)
		}
		for _, elt := range value.Elts {
			analyzeExpr(elt, depth, info, types)
		}
	case *ast.KeyValueExpr:
		analyzeExpr(value.Key, depth, info, types)
		analyzeExpr(value.Value, depth, info, types)
	case *ast.TypeAssertExpr:
		analyzeExpr(value.X, depth, info, types)
		if value.Type != nil {
			updateDataFromTypeExpr(&info.Data, value.Type, types)
		}
	case *ast.FuncLit:
		updateNesting(info, depth+1)
		if value.Type != nil {
			analyzeFieldListTypes(value.Type.Params, info, types)
			analyzeFieldListTypes(value.Type.Results, info, types)
		}
		analyzeBlock(value.Body, depth+1, info, types)
	case *ast.MapType:
		updateDataFromTypeExpr(&info.Data, value, types)
	case *ast.StructType:
		updateDataFromTypeExpr(&info.Data, value, types)
	case *ast.ArrayType:
		if value.Elt != nil {
			updateDataFromTypeExpr(&info.Data, value.Elt, types)
		}
	case *ast.StarExpr:
		updateDataFromTypeExpr(&info.Data, value.X, types)
	case *ast.ChanType:
		updateDataFromTypeExpr(&info.Data, value.Value, types)
	case *ast.FuncType:
		analyzeFieldListTypes(value.Params, info, types)
		analyzeFieldListTypes(value.Results, info, types)
	case *ast.InterfaceType:
		updateDataFromTypeExpr(&info.Data, value, types)
	case *ast.Ident:
		return
	case *ast.BasicLit:
		return
	default:
		return
	}
}

func updateNesting(info *functionInfo, depth int) {
	if depth > info.NestingDepth {
		info.NestingDepth = depth
	}
}

func updateDataFromTypeExpr(data *DataComplexity, expr ast.Expr, types *typeIndex) {
	if data == nil || expr == nil {
		return
	}
	mapDepth, structDepth := measureTypeDepth(expr, types, map[string]bool{})
	if mapDepth > data.NestedMaps {
		data.NestedMaps = mapDepth
	}
	if structDepth > data.StructDepth {
		data.StructDepth = structDepth
	}
	data.Level = dataComplexityLevel(data.NestedMaps, data.StructDepth)
}

func measureTypeDepth(expr ast.Expr, types *typeIndex, seen map[string]bool) (int, int) {
	if expr == nil {
		return 0, 0
	}

	switch value := expr.(type) {
	case *ast.MapType:
		keyMap, keyStruct := measureTypeDepth(value.Key, types, seen)
		valueMap, valueStruct := measureTypeDepth(value.Value, types, seen)
		mapDepth := max(1+keyMap, 1+valueMap)
		return mapDepth, max(keyStruct, valueStruct)
	case *ast.StructType:
		structDepth := 1
		mapDepth := 0
		if value.Fields != nil {
			for _, field := range value.Fields.List {
				childMap, childStruct := measureTypeDepth(field.Type, types, seen)
				if childMap > mapDepth {
					mapDepth = childMap
				}
				if 1+childStruct > structDepth {
					structDepth = 1 + childStruct
				}
			}
		}
		return mapDepth, structDepth
	case *ast.ArrayType:
		return measureTypeDepth(value.Elt, types, seen)
	case *ast.StarExpr:
		return measureTypeDepth(value.X, types, seen)
	case *ast.ChanType:
		return measureTypeDepth(value.Value, types, seen)
	case *ast.ParenExpr:
		return measureTypeDepth(value.X, types, seen)
	case *ast.InterfaceType:
		mapDepth := 0
		structDepth := 1
		if value.Methods != nil {
			for _, field := range value.Methods.List {
				childMap, childStruct := measureTypeDepth(field.Type, types, seen)
				if childMap > mapDepth {
					mapDepth = childMap
				}
				if childStruct > structDepth {
					structDepth = childStruct
				}
			}
		}
		return mapDepth, structDepth
	case *ast.FuncType:
		mapDepth := 0
		structDepth := 0
		if value.Params != nil {
			for _, field := range value.Params.List {
				childMap, childStruct := measureTypeDepth(field.Type, types, seen)
				mapDepth = max(mapDepth, childMap)
				structDepth = max(structDepth, childStruct)
			}
		}
		if value.Results != nil {
			for _, field := range value.Results.List {
				childMap, childStruct := measureTypeDepth(field.Type, types, seen)
				mapDepth = max(mapDepth, childMap)
				structDepth = max(structDepth, childStruct)
			}
		}
		return mapDepth, structDepth
	case *ast.Ident:
		if builtinTypes[value.Name] {
			return 0, 0
		}
		if types == nil || types.Named == nil {
			return 0, 0
		}
		named, ok := types.Named[value.Name]
		if !ok || named.Expr == nil {
			return 0, 0
		}
		if seen[value.Name] {
			return 0, 0
		}
		nextSeen := cloneSeen(seen)
		nextSeen[value.Name] = true
		return measureTypeDepth(named.Expr, types, nextSeen)
	case *ast.SelectorExpr:
		return 0, 0
	case *ast.IndexExpr:
		return measureTypeDepth(value.X, types, seen)
	case *ast.IndexListExpr:
		return measureTypeDepth(value.X, types, seen)
	default:
		return 0, 0
	}
}

func cloneSeen(seen map[string]bool) map[string]bool {
	copyMap := make(map[string]bool, len(seen)+1)
	for key, value := range seen {
		copyMap[key] = value
	}
	return copyMap
}

func buildEdges(funcs []*functionInfo) []edgeInfo {
	edges := make([]edgeInfo, 0)
	seen := map[string]bool{}

	bySimple := make(map[string][]*functionInfo)
	for _, fn := range funcs {
		bySimple[fn.Simple] = append(bySimple[fn.Simple], fn)
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

			edges = append(edges, edgeInfo{
				From:         caller,
				To:           target,
				Line:         caller.Line,
				Contribution: target.SelfScore,
			})
		}
	}

	sort.Slice(edges, func(i, j int) bool {
		if edges[i].Line == edges[j].Line {
			return edges[i].From.Canonical < edges[j].From.Canonical
		}
		return edges[i].Line < edges[j].Line
	})

	return edges
}

func chooseTarget(caller *functionInfo, targets []*functionInfo) *functionInfo {
	for _, target := range targets {
		if target.File == caller.File {
			return target
		}
	}
	return targets[0]
}

func computeDependencyScores(funcs []*functionInfo, edges []edgeInfo) {
	adjacency := map[string][]string{}
	byCanonical := map[string]*functionInfo{}

	for _, fn := range funcs {
		adjacency[fn.Canonical] = []string{}
		byCanonical[fn.Canonical] = fn
	}

	for _, edge := range edges {
		adjacency[edge.From.Canonical] = append(adjacency[edge.From.Canonical], edge.To.Canonical)
	}

	for _, fn := range funcs {
		visited := map[string]bool{}
		sum := 0
		var walk func(name string)
		walk = func(name string) {
			for _, callee := range adjacency[name] {
				if visited[callee] {
					continue
				}
				visited[callee] = true
				target := byCanonical[callee]
				if target != nil {
					sum += target.SelfScore
					walk(callee)
				}
			}
		}
		walk(fn.Canonical)
		fn.DependencyScore = sum
		fn.TotalScore = fn.SelfScore + fn.DependencyScore
	}
}

func applyDerivedSignals(funcs []*functionInfo) {
	for _, fn := range funcs {
		fn.Role = inferRole(fn)
		fn.Threshold = scoreBand(fn.TotalScore)
		fn.RoleAssessment = roleAssessment(fn.Role, fn.TotalScore)
		fn.Hotspots, fn.Suggestions = deriveHotspotsAndSuggestions(fn)
		fn.Data.Level = dataComplexityLevel(fn.Data.NestedMaps, fn.Data.StructDepth)
	}
}

func inferRole(fn *functionInfo) string {
	if fn.CallCount >= 5 && fn.Branching <= 3 && fn.Loops <= 1 {
		return "orchestrator"
	}
	if fn.SelfScore <= 5 && fn.Branching <= 2 && fn.Loops == 0 && fn.NestingDepth <= 1 {
		return "utility"
	}
	return "core-logic"
}

func scoreBand(score int) string {
	if score <= 5 {
		return "simple"
	}
	if score <= 10 {
		return "moderate"
	}
	if score <= 20 {
		return "complex"
	}
	return "needs-refactoring"
}

func roleAssessment(role string, score int) string {
	switch role {
	case "orchestrator":
		if score <= 20 {
			return "acceptable"
		}
		if score <= 30 {
			return "monitor"
		}
		return "should-optimize"
	case "utility":
		if score <= 5 {
			return "acceptable"
		}
		if score <= 10 {
			return "should-optimize"
		}
		return "needs-refactoring"
	default:
		if score <= 10 {
			return "acceptable"
		}
		if score <= 20 {
			return "monitor"
		}
		return "needs-refactoring"
	}
}

func deriveHotspotsAndSuggestions(fn *functionInfo) ([]string, []string) {
	hotspots := make([]string, 0)
	suggestions := make([]string, 0)
	seenSuggestion := map[string]bool{}

	addSuggestion := func(text string) {
		if text == "" || seenSuggestion[text] {
			return
		}
		seenSuggestion[text] = true
		suggestions = append(suggestions, text)
	}

	if fn.Branching >= 6 {
		hotspots = append(hotspots, "high branching")
		addSuggestion("replace long condition chains with table-driven dispatch")
	}

	if fn.NestingDepth >= 3 {
		hotspots = append(hotspots, "deep nesting")
		addSuggestion("extract nested blocks into helper functions and use guard clauses")
	}

	if fn.Loops >= 3 {
		hotspots = append(hotspots, "loop-heavy")
		addSuggestion("split loop responsibilities and extract inner loops")
	}

	if fn.Loops >= 2 && fn.NestingDepth >= 2 {
		addSuggestion("extract inner-loop work into dedicated functions")
	}

	if fn.CallCount >= 8 && fn.Branching <= 2 {
		addSuggestion("consider splitting orchestration into smaller stage functions")
	}

	if fn.TotalScore > 20 {
		hotspots = append(hotspots, "score above threshold")
		addSuggestion("decompose function and reduce transitive dependencies")
	}

	if len(suggestions) == 0 && fn.TotalScore > 10 {
		addSuggestion("review function boundaries and extract focused helpers")
	}

	return hotspots, suggestions
}

func chooseEntryPoints(filePath string, funcs []*functionInfo) []EntryPoint {
	entries := make([]EntryPoint, 0)
	fileHint := strings.ToLower(strings.TrimSuffix(filepath.Base(filePath), filepath.Ext(filePath)))

	for _, fn := range funcs {
		entryScore := scoreName(fn.Canonical)
		if entryFileHints[fileHint] && fn.Line <= 120 {
			entryScore += 2
		}
		if fn.Simple == "main" {
			entryScore += 4
		}
		fn.EntryScore = entryScore
		if entryScore > 0 {
			entries = append(entries, toEntryPoint(fn, "entry-like naming"))
		}
	}

	sort.Slice(entries, func(i, j int) bool {
		if entries[i].EntryScore == entries[j].EntryScore {
			return entries[i].Line < entries[j].Line
		}
		return entries[i].EntryScore > entries[j].EntryScore
	})

	if len(entries) == 0 && len(funcs) > 0 {
		first := funcs[0]
		first.EntryScore = 1
		entries = append(entries, toEntryPoint(first, "first function in file"))
	}

	if len(entries) > 3 {
		entries = entries[:3]
	}

	return entries
}

func toEntryPoint(fn *functionInfo, reason string) EntryPoint {
	return EntryPoint{
		Name:            fn.Canonical,
		Line:            fn.Line,
		Score:           fn.TotalScore,
		SelfScore:       fn.SelfScore,
		DependencyScore: fn.DependencyScore,
		EntryScore:      fn.EntryScore,
		Breakdown: ComplexityBreakdown{
			Branching:    fn.Branching,
			NestingDepth: fn.NestingDepth,
			Loops:        fn.Loops,
			Calls:        fn.CallCount,
		},
		Role:           fn.Role,
		Threshold:      fn.Threshold,
		RoleAssessment: fn.RoleAssessment,
		Hotspots:       copyStrings(fn.Hotspots),
		Suggestions:    copyStrings(fn.Suggestions),
		DataComplexity: fn.Data,
		Reason:         reason,
		File:           fn.File,
	}
}

func rankFunctions(funcs []*functionInfo, maxFunctions int) []ImportantFunction {
	ranked := make([]ImportantFunction, 0, len(funcs))

	for _, fn := range funcs {
		visibility := "private"
		if fn.Exported {
			visibility = "public"
		}

		ranked = append(ranked, ImportantFunction{
			Name:            fn.Canonical,
			Line:            fn.Line,
			Score:           fn.TotalScore,
			SelfScore:       fn.SelfScore,
			DependencyScore: fn.DependencyScore,
			Breakdown: ComplexityBreakdown{
				Branching:    fn.Branching,
				NestingDepth: fn.NestingDepth,
				Loops:        fn.Loops,
				Calls:        fn.CallCount,
			},
			Role:           fn.Role,
			Threshold:      fn.Threshold,
			RoleAssessment: fn.RoleAssessment,
			Hotspots:       copyStrings(fn.Hotspots),
			Suggestions:    copyStrings(fn.Suggestions),
			DataComplexity: fn.Data,
			Visibility:     visibility,
			File:           fn.File,
		})
	}

	sort.Slice(ranked, func(i, j int) bool {
		if ranked[i].Score == ranked[j].Score {
			if ranked[i].SelfScore == ranked[j].SelfScore {
				return ranked[i].Line < ranked[j].Line
			}
			return ranked[i].SelfScore > ranked[j].SelfScore
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
			flow = append(flow, FlowEdge{
				From:         from,
				To:           to,
				Line:         edge.Line,
				Contribution: edge.Contribution,
				FromFile:     edge.From.File,
				ToFile:       edge.To.File,
			})
		}
	}

	if len(flow) == 0 {
		for _, edge := range edges {
			flow = append(flow, FlowEdge{
				From:         edge.From.Canonical,
				To:           edge.To.Canonical,
				Line:         edge.Line,
				Contribution: edge.Contribution,
				FromFile:     edge.From.File,
				ToFile:       edge.To.File,
			})
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
		fn.EntryScore = 6
		if filepath.Clean(fn.File) != filepath.Clean(targetFile) {
			fn.EntryScore += 1
		}
		entries = append(entries, toEntryPoint(fn, "hidden entry: init"))
	}

	for _, fn := range funcs {
		if strings.EqualFold(fn.Simple, "ServeHTTP") || strings.EqualFold(fn.Simple, "Handle") {
			fn.EntryScore = max(fn.EntryScore, 5)
			entries = append(entries, toEntryPoint(fn, "hidden entry: interface hook"))
		}
	}

	return entries
}

func mergeEntryPoints(primary []EntryPoint, extras []EntryPoint) []EntryPoint {
	merged := make([]EntryPoint, 0, len(primary)+len(extras))
	indexByKey := map[string]int{}

	appendOrUpdate := func(item EntryPoint) {
		key := item.Name + ":" + item.File
		if idx, ok := indexByKey[key]; ok {
			if item.EntryScore > merged[idx].EntryScore {
				merged[idx] = item
			}
			return
		}
		indexByKey[key] = len(merged)
		merged = append(merged, item)
	}

	for _, item := range primary {
		appendOrUpdate(item)
	}
	for _, item := range extras {
		appendOrUpdate(item)
	}

	sort.Slice(merged, func(i, j int) bool {
		if merged[i].EntryScore == merged[j].EntryScore {
			return merged[i].Line < merged[j].Line
		}
		return merged[i].EntryScore > merged[j].EntryScore
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

func defaultScoreThresholds() []ScoreThreshold {
	return []ScoreThreshold{
		{Label: "simple", Min: 0, Max: 5},
		{Label: "moderate", Min: 6, Max: 10},
		{Label: "complex", Min: 11, Max: 20},
		{Label: "needs-refactoring", Min: 21, Max: -1},
	}
}

func collectHotspots(funcs []*functionInfo, maxItems int) []Hotspot {
	items := make([]Hotspot, 0)
	for _, fn := range funcs {
		if len(fn.Hotspots) == 0 {
			continue
		}
		suggestion := ""
		if len(fn.Suggestions) > 0 {
			suggestion = fn.Suggestions[0]
		}
		items = append(items, Hotspot{
			Name:       fn.Canonical,
			Line:       fn.Line,
			Score:      fn.TotalScore,
			Role:       fn.Role,
			Reason:     strings.Join(fn.Hotspots, ", "),
			Suggestion: suggestion,
			File:       fn.File,
		})
	}

	sort.Slice(items, func(i, j int) bool {
		if items[i].Score == items[j].Score {
			return items[i].Line < items[j].Line
		}
		return items[i].Score > items[j].Score
	})

	if len(items) > maxItems {
		items = items[:maxItems]
	}

	return items
}

func buildFunctionGroups(entries []EntryPoint, funcs []*functionInfo, edges []edgeInfo) []FunctionGroup {
	byCanonical := map[string]*functionInfo{}
	adj := map[string][]string{}
	for _, fn := range funcs {
		byCanonical[fn.Canonical] = fn
		adj[fn.Canonical] = []string{}
	}
	for _, edge := range edges {
		adj[edge.From.Canonical] = append(adj[edge.From.Canonical], edge.To.Canonical)
	}

	groups := make([]FunctionGroup, 0)
	seenGroup := map[string]bool{}

	buildGroup := func(root string) {
		if root == "" {
			return
		}
		if _, ok := byCanonical[root]; !ok {
			return
		}

		visited := map[string]bool{}
		stack := []string{root}
		for len(stack) > 0 {
			name := stack[len(stack)-1]
			stack = stack[:len(stack)-1]
			if visited[name] {
				continue
			}
			visited[name] = true
			for _, child := range adj[name] {
				if !visited[child] {
					stack = append(stack, child)
				}
			}
		}

		names := make([]string, 0, len(visited))
		score := 0
		for name := range visited {
			names = append(names, name)
			score += byCanonical[name].TotalScore
		}
		sort.Strings(names)
		key := strings.Join(names, "|")
		if key == "" || seenGroup[key] {
			return
		}
		seenGroup[key] = true

		groups = append(groups, FunctionGroup{
			Name:          root + " pipeline",
			Kind:          "call-graph",
			Score:         score,
			FunctionCount: len(names),
			Functions:     names,
		})
	}

	for _, entry := range entries {
		buildGroup(entry.Name)
	}

	if len(groups) == 0 {
		if len(funcs) > 0 {
			top := funcs[0]
			for _, fn := range funcs[1:] {
				if fn.TotalScore > top.TotalScore {
					top = fn
				}
			}
			buildGroup(top.Canonical)
		}
	}

	sort.Slice(groups, func(i, j int) bool {
		if groups[i].Score == groups[j].Score {
			return groups[i].Name < groups[j].Name
		}
		return groups[i].Score > groups[j].Score
	})

	if len(groups) > 5 {
		groups = groups[:5]
	}

	return groups
}

func buildModuleScores(funcs []*functionInfo) []ModuleScore {
	type bucket struct {
		score int
		count int
	}
	buckets := map[string]bucket{}

	for _, fn := range funcs {
		module := filepath.Base(fn.File)
		item := buckets[module]
		item.score += fn.TotalScore
		item.count++
		buckets[module] = item
	}

	modules := make([]ModuleScore, 0, len(buckets))
	for module, item := range buckets {
		modules = append(modules, ModuleScore{
			Module:        module,
			Score:         item.score,
			FunctionCount: item.count,
		})
	}

	sort.Slice(modules, func(i, j int) bool {
		if modules[i].Score == modules[j].Score {
			return modules[i].Module < modules[j].Module
		}
		return modules[i].Score > modules[j].Score
	})

	if len(modules) > 8 {
		modules = modules[:8]
	}

	return modules
}

func buildDataComplexityInsight(types *typeIndex) DataComplexityInsight {
	insight := DataComplexityInsight{
		Level:       "low",
		NestedMaps:  0,
		StructDepth: 0,
		Types:       []TypeComplexity{},
	}

	if types == nil || len(types.Named) == 0 {
		return insight
	}

	names := make([]string, 0, len(types.Named))
	for name := range types.Named {
		names = append(names, name)
	}
	sort.Strings(names)

	details := make([]TypeComplexity, 0)
	for _, name := range names {
		named := types.Named[name]
		seen := map[string]bool{name: true}
		mapDepth, structDepth := measureTypeDepth(named.Expr, types, seen)

		if mapDepth > insight.NestedMaps {
			insight.NestedMaps = mapDepth
		}
		if structDepth > insight.StructDepth {
			insight.StructDepth = structDepth
		}

		if mapDepth >= 2 || structDepth >= 2 {
			details = append(details, TypeComplexity{
				Name:        name,
				NestedMaps:  mapDepth,
				StructDepth: structDepth,
				File:        named.File,
			})
		}
	}

	sort.Slice(details, func(i, j int) bool {
		left := max(details[i].NestedMaps, details[i].StructDepth)
		right := max(details[j].NestedMaps, details[j].StructDepth)
		if left == right {
			return details[i].Name < details[j].Name
		}
		return left > right
	})

	if len(details) > 8 {
		details = details[:8]
	}

	insight.Types = details
	insight.Level = dataComplexityLevel(insight.NestedMaps, insight.StructDepth)
	return insight
}

func dataComplexityLevel(nestedMaps int, structDepth int) string {
	if nestedMaps >= 3 || structDepth >= 4 {
		return "high"
	}
	if nestedMaps >= 2 || structDepth >= 2 {
		return "medium"
	}
	return "low"
}

func copyStrings(values []string) []string {
	if len(values) == 0 {
		return nil
	}
	copyValues := make([]string, len(values))
	copy(copyValues, values)
	return copyValues
}

func max(left int, right int) int {
	if left > right {
		return left
	}
	return right
}
