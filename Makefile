# Makefile for OpenVSMobile
# Builds the Go server, Flutter client, and focused bridge validation flows.

.DEFAULT_GOAL := all

# -----------------------------------------------------------------------------
# Tools
# -----------------------------------------------------------------------------

GO ?= $(shell command -v go 2>/dev/null)

FLUTTER ?=
FLUTTER_BIN := $(strip $(or \
	$(FLUTTER), \
	$(shell command -v flutter 2>/dev/null), \
	$(wildcard $(HOME)/flutter/bin/flutter), \
	$(wildcard $(HOME)/flutter-sdk/flutter/bin/flutter), \
	$(wildcard /home/faydev/flutter-sdk/flutter/bin/flutter)))

# -----------------------------------------------------------------------------
# Directories & Files
# -----------------------------------------------------------------------------

SERVER_DIR := server
APP_DIR    := app
SERVER_BIN := server_bin

GO_FILES := $(shell find $(SERVER_DIR) -type f -name '*.go' 2>/dev/null)
GO_MOD   := $(SERVER_DIR)/go.mod

# -----------------------------------------------------------------------------
# OpenVSCode Server
# -----------------------------------------------------------------------------

VSCODE_PORT  ?= 3003
VSCODE_HOST  ?= 0.0.0.0
VSCODE_TOKEN ?= test
VSCODE_URL   ?= http://localhost:$(VSCODE_PORT)

OVSDIR       := openvscode-server
OVSSERVER_JS := $(OVSDIR)/out/server-main.js

# Node 22 is required by openvscode-server; resolve via nvm if available.
NODE22 ?= $(shell bash -c '. "$$HOME/.nvm/nvm.sh" && nvm which 22' 2>/dev/null)

# -----------------------------------------------------------------------------
# Phony targets
# -----------------------------------------------------------------------------

.PHONY: all build build-server build-android \
	run-server run-server-dev deps install-android \
	test verify verify-app lint clean help \
	go-prereq flutter-prereq \
	verify-bridge-extension verify-bridge-foundation

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------

all: build

build: build-server build-android

# File target: rebuilds only when Go sources change
$(SERVER_BIN): $(GO_FILES) $(GO_MOD)
	@echo "==> Building Go server..."
	cd $(SERVER_DIR) && $(GO) build -o ../$@ ./cmd/server
	@echo "==> Server binary: ./$@"

# Phony alias: always rebuild
build-server: go-prereq
	@echo "==> Force rebuilding Go server..."
	cd $(SERVER_DIR) && $(GO) build -o ../$(SERVER_BIN) ./cmd/server
	@echo "==> Server binary: ./$(SERVER_BIN)"

build-android: flutter-prereq
	@echo "==> Building Flutter APK with $(FLUTTER_BIN)..."
	cd $(APP_DIR) && $(FLUTTER_BIN) build apk

# -----------------------------------------------------------------------------
# Development
# -----------------------------------------------------------------------------

# Always recompile before running
run-server: build-server
	@echo "==> Ensuring OpenVSCode Server is running on port $(VSCODE_PORT)..."
	@VSCODE_PID=""; \
	if ! ss -tln 2>/dev/null | grep -q ':$(VSCODE_PORT) '; then \
		if [ ! -f "$(OVSSERVER_JS)" ]; then \
			echo "error: $(OVSSERVER_JS) not found. Run 'cd $(OVSDIR) && npm run compile' first." >&2; \
			exit 1; \
		fi; \
		if [ -z "$(NODE22)" ]; then \
			echo "error: Node 22 not found via nvm. Install it with: nvm install 22" >&2; \
			exit 1; \
		fi; \
		echo "==> Starting OpenVSCode Server on port $(VSCODE_PORT)..."; \
		cd $(OVSDIR) && $(NODE22) out/server-main.js --port $(VSCODE_PORT) --host $(VSCODE_HOST) --connection-token $(VSCODE_TOKEN) --accept-server-license-terms > /tmp/openvscode-$(VSCODE_PORT).log 2>&1 & \
		VSCODE_PID=$$!; \
		sleep 2; \
		if ! ss -tln 2>/dev/null | grep -q ':$(VSCODE_PORT) '; then \
			echo "error: OpenVSCode Server failed to start, check /tmp/openvscode-$(VSCODE_PORT).log" >&2; \
			kill $$VSCODE_PID 2>/dev/null; \
			exit 1; \
		fi; \
		echo "==> OpenVSCode Server ready"; \
	fi; \
	if [ -n "$$VSCODE_PID" ]; then trap 'echo "==> Stopping OpenVSCode Server..."; kill $$VSCODE_PID 2>/dev/null' EXIT INT TERM; fi; \
	echo "==> Running Go server..."; \
	./$(SERVER_BIN) -vscode-url $(VSCODE_URL) -vscode-token $(VSCODE_TOKEN) $(ARGS)

# Only recompile if Go sources changed
run-server-dev: $(SERVER_BIN)
	@echo "==> Ensuring OpenVSCode Server is running on port $(VSCODE_PORT)..."
	@VSCODE_PID=""; \
	if ! ss -tln 2>/dev/null | grep -q ':$(VSCODE_PORT) '; then \
		if [ ! -f "$(OVSSERVER_JS)" ]; then \
			echo "error: $(OVSSERVER_JS) not found. Run 'cd $(OVSDIR) && npm run compile' first." >&2; \
			exit 1; \
		fi; \
		if [ -z "$(NODE22)" ]; then \
			echo "error: Node 22 not found via nvm. Install it with: nvm install 22" >&2; \
			exit 1; \
		fi; \
		echo "==> Starting OpenVSCode Server on port $(VSCODE_PORT)..."; \
		cd $(OVSDIR) && $(NODE22) out/server-main.js --port $(VSCODE_PORT) --host $(VSCODE_HOST) --connection-token $(VSCODE_TOKEN) --accept-server-license-terms > /tmp/openvscode-$(VSCODE_PORT).log 2>&1 & \
		VSCODE_PID=$$!; \
		sleep 2; \
		if ! ss -tln 2>/dev/null | grep -q ':$(VSCODE_PORT) '; then \
			echo "error: OpenVSCode Server failed to start, check /tmp/openvscode-$(VSCODE_PORT).log" >&2; \
			kill $$VSCODE_PID 2>/dev/null; \
			exit 1; \
		fi; \
		echo "==> OpenVSCode Server ready"; \
	fi; \
	if [ -n "$$VSCODE_PID" ]; then trap 'echo "==> Stopping OpenVSCode Server..."; kill $$VSCODE_PID 2>/dev/null' EXIT INT TERM; fi; \
	echo "==> Running Go server..."; \
	./$(SERVER_BIN) -vscode-url $(VSCODE_URL) -vscode-token $(VSCODE_TOKEN) $(ARGS)

deps: go-prereq flutter-prereq
	@echo "==> Getting Go dependencies..."
	cd $(SERVER_DIR) && $(GO) mod tidy
	@echo "==> Getting Flutter dependencies..."
	cd $(APP_DIR) && $(FLUTTER_BIN) pub get

install-android: build-android
	@echo "==> Installing APK to connected device..."
	cd $(APP_DIR) && $(FLUTTER_BIN) install

# -----------------------------------------------------------------------------
# Test & Quality
# -----------------------------------------------------------------------------

test: go-prereq flutter-prereq
	@echo "==> Running Go tests..."
	cd $(SERVER_DIR) && $(GO) test ./...
	@echo "==> Running Flutter tests..."
	cd $(APP_DIR) && $(FLUTTER_BIN) test

verify: verify-app

verify-app:
	@./scripts/verify_repo.sh

lint: go-prereq flutter-prereq
	@echo "==> Running go vet..."
	cd $(SERVER_DIR) && $(GO) vet ./...
	@echo "==> Running flutter analyze..."
	cd $(APP_DIR) && $(FLUTTER_BIN) analyze

# -----------------------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------------------

go-prereq:
	@if [ -z "$(GO)" ]; then \
		echo "error: Go not found." >&2; \
		echo "hint: install Go and add it to PATH, or run 'make GO=/absolute/path/to/go <target>'" >&2; \
		exit 1; \
	fi
	@echo "==> Using Go: $(GO)"

flutter-prereq:
	@if [ -z "$(FLUTTER_BIN)" ]; then \
		echo "error: Flutter SDK not found." >&2; \
		echo "hint: install Flutter and add it to PATH, or run 'make FLUTTER=/absolute/path/to/flutter <target>'" >&2; \
		echo "hint: expected a runnable 'flutter' binary, for example '$$HOME/flutter/bin/flutter'" >&2; \
		exit 1; \
	fi
	@echo "==> Using Flutter SDK: $(FLUTTER_BIN)"

verify-bridge-extension:
	@./scripts/verify_bridge_foundation.sh --extension-only

verify-bridge-foundation:
	@./scripts/verify_bridge_foundation.sh

# -----------------------------------------------------------------------------
# Clean
# -----------------------------------------------------------------------------

clean:
	@echo "==> Cleaning build artifacts..."
	rm -f $(SERVER_BIN)
	@if [ -n "$(FLUTTER_BIN)" ]; then \
		echo "==> Cleaning Flutter artifacts with $(FLUTTER_BIN)..."; \
		cd $(APP_DIR) && $(FLUTTER_BIN) clean; \
	else \
		echo "==> Skipping Flutter clean; no Flutter SDK detected"; \
	fi

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

help:
	@echo "Available targets:"
	@echo "  all                     - Build server and Android APK (default)"
	@echo "  build                   - Alias for all"
	@echo "  build-server            - Force rebuild Go server binary -> ./server_bin"
	@echo "  build-android           - Build Flutter APK"
	@echo "  run-server              - Build server, start OpenVSCode Server (if not running), and run Go server"
	@echo "  run-server-dev          - Same as run-server but only rebuilds Go server if sources changed"
	@echo "  deps                    - Run go mod tidy + flutter pub get"
	@echo "  install-android         - Build and install APK to a connected device"
	@echo "  test                    - Run Go and Flutter tests"
	@echo "  verify                  - Run repo verification entry for Flutter app tests"
	@echo "  verify-app              - Alias for verify"
	@echo "  lint                    - Run go vet + flutter analyze"
	@echo "  go-prereq               - Show the resolved Go toolchain or fail with setup guidance"
	@echo "  flutter-prereq          - Show the resolved Flutter SDK or fail with setup guidance"
	@echo "  verify-bridge-extension - Compile the built-in mobile bridge extension from openvscode-server/"
	@echo "  verify-bridge-foundation- Run the bridge extension compile + targeted Go bridge checks"
	@echo "  clean                   - Remove server_bin and Flutter build artifacts"
	@echo "  help                    - Show this help message"
