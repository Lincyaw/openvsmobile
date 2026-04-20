# Makefile for OpenVSMobile
# Builds Go server + Flutter Android client

# Use the project-specific Flutter SDK if available; fall back to PATH.
FLUTTER := /home/faydev/flutter-sdk/flutter/bin/flutter
ifeq ($(wildcard $(FLUTTER)),)
  FLUTTER := flutter
endif

.PHONY: all build build-server build-android test verify verify-app lint clean deps run-server install-android help

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

build-android:
	@echo "==> Building Flutter APK with $(FLUTTER)..."
	cd app && $(FLUTTER) build apk

# -----------------------------------------------------------------------------
# Development
# -----------------------------------------------------------------------------

run-server: build-server
	@echo "==> Running Go server..."
	./server_bin

deps:
	@echo "==> Getting Go dependencies..."
	cd server && go mod tidy
	@echo "==> Getting Flutter dependencies..."
	cd app && $(FLUTTER) pub get

install-android: build-android
	@echo "==> Installing APK to connected device..."
	cd app && $(FLUTTER) install

# -----------------------------------------------------------------------------
# Test & Quality
# -----------------------------------------------------------------------------

test:
	@echo "==> Running Go tests..."
	cd server && go test ./...
	@echo "==> Running Flutter tests..."
	cd app && $(FLUTTER) test

verify: verify-app

verify-app:
	@./scripts/verify_repo.sh

lint:
	@echo "==> Running go vet..."
	cd server && go vet ./...
	@echo "==> Running flutter analyze..."
	cd app && $(FLUTTER) analyze

# -----------------------------------------------------------------------------
# Clean
# -----------------------------------------------------------------------------

clean:
	@echo "==> Cleaning build artifacts..."
	rm -f server_bin
	cd app && $(FLUTTER) clean

# -----------------------------------------------------------------------------
# Help
# -----------------------------------------------------------------------------

help:
	@echo "Available targets:"
	@echo "  all            - Build server and Android APK (default)"
	@echo "  build          - Alias for all"
	@echo "  build-server   - Build Go server binary -> ./server_bin"
	@echo "  build-android  - Build Flutter APK"
	@echo "  run-server     - Build and run Go server"
	@echo "  deps           - Run go mod tidy + flutter pub get"
	@echo "  install-android- Build and install APK to connected device"
	@echo "  test           - Run Go and Flutter tests"
	@echo "  verify         - Run repo verification entry for Flutter app tests"
	@echo "  verify-app     - Alias for verify"
	@echo "  lint           - Run go vet + flutter analyze"
	@echo "  clean          - Remove server_bin and flutter build artifacts"
	@echo "  help           - Show this help message"
