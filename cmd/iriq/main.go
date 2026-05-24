package main

import (
	"os"

	"github.com/dpep/iriq/cmd/iriq/cli"
)

func main() {
	os.Exit(cli.Run(os.Stdin, os.Stdout, os.Stderr, os.Args[1:]))
}
