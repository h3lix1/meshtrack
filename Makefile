SHELL := /usr/bin/env bash

# Build configuration for the .app bundle (override: `make app CONFIG=debug`).
CONFIG ?= release

# The single external validator the Ralph loop trusts. `make verify` must be
# green before any commit. Tooling that may be absent locally degrades to a
# warning (CI installs everything and enforces strictly).

.PHONY: help verify bootstrap build test domain-purity format-check lint \
        coverage mutation protos-check perf secrets run app run-app loop clean

help:
	@echo "Meshtrack — make targets"
	@echo "  make bootstrap   install dev tooling (swiftformat, swiftlint, muter)"
	@echo "  make verify      run the full gate suite (the only validator the loop trusts)"
	@echo "  make build       swift build (warnings-as-errors, Swift 6 strict concurrency)"
	@echo "  make test        swift test with code coverage"
	@echo "  make run         run the meshtrackd collector"
	@echo "  make app         build a double-clickable Meshtrack.app (CONFIG=release|debug)"
	@echo "  make run-app     build Meshtrack.app and open it"
	@echo "  make loop        run the Ralph build loop (scripts/loop.sh)"
	@echo "  make clean       remove build artifacts"

bootstrap:
	@bash scripts/bootstrap.sh

# ---- the gate suite (order = fast-fail first) -----------------------------
verify: domain-purity format-check lint build test coverage mutation protos-check perf secrets
	@echo "✅ make verify: all gates green"

domain-purity:
	@bash scripts/check-domain-purity.sh

format-check:
	@if command -v swiftformat >/dev/null 2>&1; then \
		swiftformat --lint . ; \
	else echo "⚠️  swiftformat absent (run 'make bootstrap'); skipping format gate"; fi

lint:
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint lint --strict --quiet ; \
	else echo "⚠️  swiftlint absent (run 'make bootstrap'); skipping lint gate"; fi

build:
	@swift build

test:
	@swift test --enable-code-coverage

coverage:
	@bash scripts/check-coverage.sh

mutation:
	@bash scripts/check-mutation.sh

protos-check:
	@bash scripts/check-protobuf-codegen.sh

perf:
	@bash scripts/check-perf-budgets.sh

secrets:
	@bash scripts/check-secrets.sh

run:
	@swift run meshtrackd

# Assemble a proper macOS .app bundle (Info.plist + Dock icon + menu bar + ad-hoc
# signing) from the MeshtrackApp executable. `swift run` launches a bare executable
# that macOS treats as a background process; the bundle is the real app.
app:
	@CONFIG=$(CONFIG) bash scripts/make-app.sh

run-app: app
	@open Meshtrack.app

loop:
	@bash scripts/loop.sh

clean:
	@swift package clean ; rm -rf .build Meshtrack.app
