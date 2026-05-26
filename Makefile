# Loom — top-level developer commands.
#
# Tools required on the dev box (install once):
#   brew install xcodegen swiftlint swiftformat libgit2
#   xcodebuild -runFirstLaunch
#   xcodebuild -downloadComponent MetalToolchain   # SwiftTerm uses Metal shaders
#
# CI installs the same via .github/workflows/ci.yml.

PROJECT      := Loom.xcodeproj
SCHEME       := Loom
DESTINATION  := platform=macOS

.PHONY: all build test lint format project clean help install-tools

all: build

help:
	@echo "Targets:"
	@echo "  build          - xcodebuild build the Loom scheme"
	@echo "  test           - xcodebuild test the Loom scheme"
	@echo "  lint           - swiftlint --strict over Loom/ and Tests/"
	@echo "  format         - swiftformat in-place over Loom/ and Tests/"
	@echo "  project        - regenerate Loom.xcodeproj from project.yml"
	@echo "  install-tools  - brew-install required dev tooling"
	@echo "  clean          - xcodebuild clean + remove build/"

project:
	xcodegen generate

# Pipe xcodebuild through xcbeautify when present; otherwise raw output.
XCB := $(shell command -v xcbeautify 2>/dev/null)
ifeq ($(XCB),)
  PIPE :=
else
  PIPE := | $(XCB)
endif

build: project
	set -o pipefail; xcodebuild \
	  -project $(PROJECT) \
	  -scheme $(SCHEME) \
	  -destination '$(DESTINATION)' \
	  build $(PIPE)

test: project
	set -o pipefail; xcodebuild \
	  -project $(PROJECT) \
	  -scheme $(SCHEME) \
	  -destination '$(DESTINATION)' \
	  test $(PIPE)

lint:
	swiftlint --strict --quiet

format:
	swiftformat .

install-tools:
	brew install xcodegen swiftlint swiftformat libgit2
	xcodebuild -runFirstLaunch
	xcodebuild -downloadComponent MetalToolchain

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
	rm -rf build/ DerivedData/
