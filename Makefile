# Iriq Go binary — build/install/clean/uninstall helpers.
#
#   make           - same as `make help`
#   make build     - build into ./bin/iriq
#   make install   - go install into $GOBIN (defaults to $GOPATH/bin)
#   make test      - go test ./...
#   make clean     - remove ./bin/
#   make uninstall - remove the binary from $GOBIN
#
# Ruby gem build/install is handled by Bundler/RubyGems; see CLAUDE.md.

GO        ?= go
BIN_DIR   := bin
BIN       := $(BIN_DIR)/iriq
PKG       := ./cmd/iriq

# Resolve $GOBIN, falling back to $GOPATH/bin (Go's default install location).
GOBIN     := $(shell $(GO) env GOBIN)
ifeq ($(GOBIN),)
GOBIN     := $(shell $(GO) env GOPATH)/bin
endif
INSTALLED := $(GOBIN)/iriq

.DEFAULT_GOAL := help
.PHONY: help build install test clean uninstall

help:
	@echo "Iriq Go targets:"
	@echo "  make build       build into $(BIN)"
	@echo "  make install     go install into $(GOBIN)"
	@echo "  make test        run go test ./..."
	@echo "  make clean       remove $(BIN_DIR)/"
	@echo "  make uninstall   remove $(INSTALLED)"

build:
	@mkdir -p $(BIN_DIR)
	$(GO) build -o $(BIN) $(PKG)
	@echo "built $(BIN)"

install:
	$(GO) install $(PKG)
	@echo "installed $(INSTALLED)"

test:
	$(GO) test ./...

clean:
	rm -rf $(BIN_DIR)
	@echo "removed $(BIN_DIR)/"

uninstall:
	@if [ -f "$(INSTALLED)" ]; then \
		rm "$(INSTALLED)" && echo "removed $(INSTALLED)"; \
	else \
		echo "not installed at $(INSTALLED)"; \
	fi
