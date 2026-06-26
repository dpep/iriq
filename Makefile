# Iriq Go binary — build/install/clean/uninstall helpers.
#
#   make                   - same as `make help`
#   make build             - dev build into ./bin/iriq
#   make release           - stripped + trimpath build
#   make install           - go install into $GOBIN
#   make test              - go test ./...
#   make clean             - remove ./bin/
#   make uninstall         - remove the binary from $GOBIN
#
# As of v0.31.0 SQLite is always linked into the Go build (modernc.org/sqlite,
# pure-Go, no cgo). The previous slim/sqlite split is gone — one binary,
# both backends. The CLI's --version output still prints a `Build:` line.
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

# Rust crate lives under rust/; CI gates fmt + clippy + tests there.
CARGO       ?= cargo
RUST_DIR    := rust

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
.PHONY: help build release install test clean uninstall check fmt hooks

help:
	@echo "Iriq Go targets:"
	@echo "  make build            dev build into $(BIN)"
	@echo "  make release          stripped release build into $(BIN)"
	@echo "  make install          go install into $(GOBIN)"
	@echo "  make test             run go test ./..."
	@echo "  make check            Rust gate: cargo fmt --check + clippy + test (run before merging)"
	@echo "  make fmt              cargo fmt the Rust crate"
	@echo "  make hooks            enable the committed git hooks (pre-push runs 'make check')"
	@echo "  make clean            remove $(BIN_DIR)/"
	@echo "  make uninstall        remove $(INSTALLED)"

build:
	@mkdir -p $(BIN_DIR)
	$(GO) -C $(GO_DIR) build -o $(ABS_BIN) $(PKG)
	@echo "built $(BIN) (debug)"

release:
	@mkdir -p $(BIN_DIR)
	$(GO) -C $(GO_DIR) build $(RELEASE_FLAGS) -o $(ABS_BIN) $(PKG)
	@echo "built $(BIN) (stripped)"

install:
	$(GO) -C $(GO_DIR) install $(PKG)
	@echo "installed $(INSTALLED)"

test:
	$(GO) -C $(GO_DIR) test ./...

# The Rust gate — mirrors CI's Rust job. Run before merging/pushing (the
# pre-push hook runs this for you once `make hooks` is enabled).
check:
	cd $(RUST_DIR) && $(CARGO) fmt --check
	cd $(RUST_DIR) && $(CARGO) clippy --workspace --all-targets -- -D warnings
	cd $(RUST_DIR) && $(CARGO) test --workspace

fmt:
	cd $(RUST_DIR) && $(CARGO) fmt

hooks:
	git config core.hooksPath .githooks
	@echo "git hooks enabled (.githooks) — pre-push now runs 'make check'"

clean:
	rm -rf $(BIN_DIR)
	@echo "removed $(BIN_DIR)/"

uninstall:
	@if [ -f "$(INSTALLED)" ]; then \
		rm "$(INSTALLED)" && echo "removed $(INSTALLED)"; \
	else \
		echo "not installed at $(INSTALLED)"; \
	fi
