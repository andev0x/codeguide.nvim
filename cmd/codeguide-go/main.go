package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"

	"github.com/andev0x/codeguide.nvim/internal/engine"
)

func main() {
	var file string
	var maxFunctions int
	var maxFlowEdges int

	flag.StringVar(&file, "file", "", "path to the file to analyze")
	flag.IntVar(&maxFunctions, "max-functions", 6, "maximum number of important functions")
	flag.IntVar(&maxFlowEdges, "max-flow-edges", 8, "maximum number of flow edges")
	flag.Parse()

	if file == "" {
		fmt.Fprintln(os.Stderr, "missing required --file flag")
		os.Exit(2)
	}

	result, err := engine.Analyze(engine.Options{
		File:         file,
		MaxFunctions: maxFunctions,
		MaxFlowEdges: maxFlowEdges,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}
}
