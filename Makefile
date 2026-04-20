# Makefile for OpenVSMobile
# Builds the Go server, Flutter client, and focused bridge validation flows.

FLUTTER ?=
FLUTTER_BIN := $(strip $(or \
	$(FLUTTER), \
	$(shell command -v flutter 2>/dev/null), \
	$(wildcard $(HOME)/flutter/bin/flutter), \
	$(wildcard $(HOME)/flutter-sdk/flutter/bin/flutter), \
	$(wildcard /home/faydev/flutter-sdk/flutter/bin/flutter)))

.PHONY: all build build-server build-android test lint clean deps run-server install-android \
	help flutter-prereq verify-bridge-extension verify-bridge-foundation

# Default target: build everything
all: build

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------

build: build-server build-android

build-server:
	@echo "==> Building Go server..."
	cd server && go build -o ../server_bin ./cmd/server
	@echo "==> Server binary: ./server_bin"

build-android: flutter-prereq
	@echo "==> Building Flutter APK with $(FLUTTER_BIN)..."
	cd app && $(FLUTTER_BIN) build apk

# -----------------------------------------------------------------------------
# Development
# -----------------------------------------------------------------------------

run-server: build-server
	@echo "==> Running Go server..."
	./server_bin

deps: flutter-prereq
	@echo "==> Getting Go dependencies..."
	cd server && go mod tidy
	@echo "==> Getting Flutter dependencies..."
	cd app && $(FLUTTER_BIN) pub get

install-android: build-android
	@echo "==> Installing APK to connected device..."
	cd app && $(FLUTTER_BIN) install

# -----------------------------------------------------------------------------
# Test & Quality
# -----------------------------------------------------------------------------

test: flutter-prereq
	@echo "==> Running Go tests..."
	cd server && go test ./...
	@echo "==> Running Flutter tests..."
	cd app && $(FLUTTER_BIN) test

lint: flutter-prereq
	@echo "==> Running go vet..."
	cd server && go vet ./...
	@echo "==> Running flutter analyze..."
	cd app && $(FLUTTER_BIN) analyze

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
	rm -f server_bin
	@if [ -n "$(FLUTTER_BIN)" ]; then \
		echo "==> Cleaning Flutter artifacts with $(FLUTTER_BIN)..."; \
		cd app && $(FLUTTER_BIN) clean; \
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
	@echo "  build-server            - Build Go server binary -> ./server_bin"
	@echo "  build-android           - Build Flutter APK"
	@echo "  run-server              - Build and run Go server"
	@echo "  deps                    - Run go mod tidy + flutter pub get"
	@echo "  install-android         - Build and install APK to a connected device"
	@echo "  test                    - Run Go and Flutter tests"
	@echo "  lint                    - Run go vet + flutter analyze"
	@echo "  flutter-prereq          - Show the resolved Flutter SDK or fail with setup guidance"
	@echo "  verify-bridge-extension - Compile the built-in mobile bridge extension from openvscode-server/"
	@echo "  verify-bridge-foundation - Run the bridge extension compile + targeted Go bridge checks"
	@echo "  clean                   - Remove server_bin and Flutter build artifacts"
	@echo "  help                    - Show this help message"
