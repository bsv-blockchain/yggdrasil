# Yggdrasil — top-level developer commands.
#
# Tools required on the dev box (install once):
#   brew install xcodegen libgit2
#   xcodebuild -runFirstLaunch
#   xcodebuild -downloadComponent MetalToolchain   # SwiftTerm uses Metal shaders
#
# SwiftFormat and SwiftLint are PINNED here (not brew) and auto-downloaded to
# .tools/ on first use, so `make format`/`make lint` behave identically to CI
# regardless of the version a dev or the runner image happens to have. This is
# the single source of truth for both versions — CI calls these same targets.

PROJECT      := Yggdrasil.xcodeproj
SCHEME       := Yggdrasil
DESTINATION  := platform=macOS

# Pinned lint/format tool versions (single source of truth, shared with CI).
SWIFTFORMAT_VERSION := 0.60.1
SWIFTLINT_VERSION   := 0.63.2
# Pinned Sparkle version: the SPM dependency (project.yml) AND the release
# pipeline's signing tools (sign_update) must match. Single source of truth.
SPARKLE_VERSION     := 2.9.3

TOOLS_DIR   := .tools
SWIFTFORMAT := $(TOOLS_DIR)/swiftformat-$(SWIFTFORMAT_VERSION)/swiftformat
SWIFTLINT   := $(TOOLS_DIR)/swiftlint-$(SWIFTLINT_VERSION)/swiftlint
SPARKLE_DIR := $(TOOLS_DIR)/sparkle-$(SPARKLE_VERSION)
SIGN_UPDATE := $(SPARKLE_DIR)/bin/sign_update

.PHONY: all build test lint format format-lint tools sparkle-tools project js clean help install-tools

all: build

help:
	@echo "Targets:"
	@echo "  build          - xcodebuild build the Yggdrasil scheme"
	@echo "  test           - xcodebuild test the Yggdrasil scheme"
	@echo "  lint           - pinned SwiftLint --strict over Yggdrasil/ and Tests/"
	@echo "  format         - pinned SwiftFormat in-place over Yggdrasil/ and Tests/"
	@echo "  format-lint    - pinned SwiftFormat --lint (no writes); used by CI"
	@echo "  tools          - download pinned SwiftFormat + SwiftLint into .tools/"
	@echo "  sparkle-tools  - download pinned Sparkle CLI tools (sign_update) into .tools/"
	@echo "  project        - regenerate Yggdrasil.xcodeproj from project.yml"
	@echo "  js             - rebuild Web/Diff React bundle → Resources/diff2html/index.js"
	@echo "  install-tools  - brew-install required dev tooling (xcodegen, libgit2)"
	@echo "  clean          - xcodebuild clean + remove build/"

project:
	xcodegen generate

js:
	cd Web/Diff && npm install --silent && npm run build

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

# --- Pinned lint/format tooling -------------------------------------------
# Download the exact pinned release binaries into .tools/ on first use. The
# version is baked into the path, so bumping SWIFTFORMAT_VERSION / SWIFTLINT_VERSION
# transparently triggers a re-download.

$(SWIFTFORMAT):
	@mkdir -p $(dir $@)
	@echo "↓ SwiftFormat $(SWIFTFORMAT_VERSION)"
	@curl -fsSL -o $(TOOLS_DIR)/swiftformat.zip \
	  https://github.com/nicklockwood/SwiftFormat/releases/download/$(SWIFTFORMAT_VERSION)/swiftformat.zip
	@unzip -oq $(TOOLS_DIR)/swiftformat.zip -d $(dir $@)
	@chmod +x $@ && touch $@

$(SWIFTLINT):
	@mkdir -p $(dir $@)
	@echo "↓ SwiftLint $(SWIFTLINT_VERSION)"
	@curl -fsSL -o $(TOOLS_DIR)/swiftlint.zip \
	  https://github.com/realm/SwiftLint/releases/download/$(SWIFTLINT_VERSION)/portable_swiftlint.zip
	@unzip -oq $(TOOLS_DIR)/swiftlint.zip -d $(dir $@)
	@chmod +x $@ && touch $@

tools: $(SWIFTFORMAT) $(SWIFTLINT)

# Sparkle ships its CLI tools (sign_update, generate_appcast) in the release
# tarball. Used by the release pipeline to sign the DMG for the appcast.
$(SIGN_UPDATE):
	@mkdir -p $(SPARKLE_DIR)
	@echo "↓ Sparkle $(SPARKLE_VERSION) tools"
	@curl -fsSL -o $(TOOLS_DIR)/sparkle.tar.xz \
	  https://github.com/sparkle-project/Sparkle/releases/download/$(SPARKLE_VERSION)/Sparkle-$(SPARKLE_VERSION).tar.xz
	@tar -xf $(TOOLS_DIR)/sparkle.tar.xz -C $(SPARKLE_DIR)
	@touch $@

sparkle-tools: $(SIGN_UPDATE)

lint: $(SWIFTLINT)
	$(SWIFTLINT) --strict --quiet

format: $(SWIFTFORMAT)
	$(SWIFTFORMAT) . --config .swiftformat --cache $(TOOLS_DIR)/swiftformat.cache

format-lint: $(SWIFTFORMAT)
	$(SWIFTFORMAT) . --lint --config .swiftformat --cache $(TOOLS_DIR)/swiftformat.cache

install-tools:
	brew install xcodegen libgit2
	xcodebuild -runFirstLaunch
	xcodebuild -downloadComponent MetalToolchain

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
	rm -rf build/ DerivedData/
