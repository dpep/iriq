# Iriq Rust binary — build/install/test helpers.
#
#   make                   - same as `make help`
#   make build             - release build into rust/target/release/iriq
#   make install           - cargo install into ~/.cargo/bin
#   make test              - cargo test --workspace
#   make check             - Rust gate: fmt --check + clippy + test (CI mirror)
#   make uninstall         - cargo uninstall
#
# Ruby gem build/install is handled by Bundler/RubyGems; see CLAUDE.md.

CARGO       ?= cargo
RUST_DIR    := rust

.DEFAULT_GOAL := help
.PHONY: help build install test check fmt hooks clean uninstall

help:
	@echo "Iriq targets:"
	@echo "  make build            release build into $(RUST_DIR)/target/release/iriq"
	@echo "  make install          cargo install into ~/.cargo/bin"
	@echo "  make test             run cargo test --workspace"
	@echo "  make check            Rust gate: cargo fmt --check + clippy + test (run before merging)"
	@echo "  make fmt              cargo fmt the Rust crate"
	@echo "  make hooks            enable the committed git hooks (pre-push runs 'make check')"
	@echo "  make clean            remove $(RUST_DIR)/target/"
	@echo "  make uninstall        cargo uninstall iriq"

build:
	cd $(RUST_DIR) && $(CARGO) build --release --bin iriq

install:
	cd $(RUST_DIR) && $(CARGO) install --path iriq

test:
	cd $(RUST_DIR) && $(CARGO) test --workspace

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
	cd $(RUST_DIR) && $(CARGO) clean

uninstall:
	$(CARGO) uninstall iriq
