# Iriq Go binary — build/install/clean/uninstall helpers.
#
#   make                   - same as `make help`
#   make build             - dev build into ./bin/iriq (no SQLite, debug info)
#   make build-sqlite      - dev build with SQLite backend included
#   make release           - stripped + trimpath build (no SQLite)
#   make release-sqlite    - stripped + trimpath build with SQLite
#   make install           - go install into $GOBIN
#   make test              - go test ./... (both tag states)
#   make clean             - remove ./bin/
#   make uninstall         - remove the binary from $GOBIN
#
# The default build excludes the SQLite backend to keep the binary lean.
# Pass `-tags sqlite` (or use the *-sqlite targets) to compile it in. The
# CLI's `--version` output tells you which backends are baked in.
#
# Ruby gem build/install is handled by Bundler/RubyGems; see CLAUDE.md.

GO          ?= go
GO_DIR      := go
BIN_DIR     := bin
BIN         := $(BIN_DIR)/iriq
# Absolute output path: builds run inside $(GO_DIR) via `go -C`, so a
# relative -o would land under go/. Keep the binary at the repo-root bin/.
ABS_BIN     := $(CURDIR)/$(BIN)
PKG         := ./cmd/iriq

# Release flags strip the symbol table (-s), debug info (-w), and bake
# reproducible paths (-trimpath). Drops binary size ~30% with no
# functional impact; stack-trace function names are gone but file:line
# resolution still works.
RELEASE_FLAGS := -ldflags "-s -w" -trimpath

# Resolve $GOBIN, falling back to $GOPATH/bin (Go's default install location).
GOBIN       := $(shell $(GO) env GOBIN)
ifeq ($(GOBIN),)
GOBIN       := $(shell $(GO) env GOPATH)/bin
endif
INSTALLED   := $(GOBIN)/iriq

.DEFAULT_GOAL := help
.PHONY: help build build-sqlite release release-sqlite install test clean uninstall

help:
	@echo "Iriq Go targets:"
	@echo "  make build            slim dev build into $(BIN)"
	@echo "  make build-sqlite     dev build with SQLite backend"
	@echo "  make release          stripped slim build into $(BIN)"
	@echo "  make release-sqlite   stripped build with SQLite backend"
	@echo "  make install          go install into $(GOBIN)"
	@echo "  make test             run go test ./... in both tag states"
	@echo "  make clean            remove $(BIN_DIR)/"
	@echo "  make uninstall        remove $(INSTALLED)"

build:
	@mkdir -p $(BIN_DIR)
	$(GO) -C $(GO_DIR) build -o $(ABS_BIN) $(PKG)
	@echo "built $(BIN) (slim, debug)"

build-sqlite:
	@mkdir -p $(BIN_DIR)
	$(GO) -C $(GO_DIR) build -tags sqlite -o $(ABS_BIN) $(PKG)
	@echo "built $(BIN) (sqlite, debug)"

release:
	@mkdir -p $(BIN_DIR)
	$(GO) -C $(GO_DIR) build $(RELEASE_FLAGS) -o $(ABS_BIN) $(PKG)
	@echo "built $(BIN) (slim, stripped)"

release-sqlite:
	@mkdir -p $(BIN_DIR)
	$(GO) -C $(GO_DIR) build -tags sqlite $(RELEASE_FLAGS) -o $(ABS_BIN) $(PKG)
	@echo "built $(BIN) (sqlite, stripped)"

install:
	$(GO) -C $(GO_DIR) install $(PKG)
	@echo "installed $(INSTALLED)"

test:
	$(GO) -C $(GO_DIR) test ./...
	$(GO) -C $(GO_DIR) test -tags sqlite ./...

clean:
	rm -rf $(BIN_DIR)
	@echo "removed $(BIN_DIR)/"

uninstall:
	@if [ -f "$(INSTALLED)" ]; then \
		rm "$(INSTALLED)" && echo "removed $(INSTALLED)"; \
	else \
		echo "not installed at $(INSTALLED)"; \
	fi
