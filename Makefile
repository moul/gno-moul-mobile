# gno-moul-mobile: a native iOS app on the gno core.
#
# `make run` is the whole story: it builds the Go core if it is missing,
# generates the Xcode project, builds the app and puts it on a simulator.

GNOMOBILE_REPO ?= https://github.com/gnolang/gnomobile
GNOMOBILE_REF  ?= eddca68
GNOMOBILE_DIR  ?= .cache/gnomobile
# Two failures, one knob, pulling in opposite directions.
#
# `gomobile bind` shells out to `go` in a generated module with no `go`
# directive, so GOTOOLCHAIN=auto leaves it on the host's base toolchain and the
# build dies with "requires go >= 1.24.0 (running go 1.23.8)" while `go version`
# says 1.25.9. But `gomobile init` runs `go install ...cmd/gobind@latest`, whose
# current version wants go >= 1.26, so a hard pin fails there instead.
#
# `<version>+auto` is the pair: a floor, not a ceiling. It raises the generated
# module off the base toolchain and still lets `@latest` pull a newer one.
GO_TOOLCHAIN   ?= go1.25.9+auto

# Whatever iPhone this machine actually has, so the same command works on a
# laptop and on a runner with a different Xcode.
SIMULATOR ?= $(shell ./scripts/pick-simulator.sh)
SCHEME    ?= MoulApp
BUNDLE_ID ?= land.gno.moul.app
DERIVED   ?= .cache/derived

.PHONY: all
all: MoulApp.xcodeproj

## project: regenerate the Xcode project from project.yml
.PHONY: project
project:
	xcodegen generate

MoulApp.xcodeproj: project.yml
	xcodegen generate

## framework: build GnoCore.xcframework from gnomobile
.PHONY: framework
framework: Frameworks/GnoCore.xcframework

Frameworks/GnoCore.xcframework:
	@mkdir -p $(dir $(GNOMOBILE_DIR)) Frameworks
	@test -d $(GNOMOBILE_DIR) || git clone $(GNOMOBILE_REPO) $(GNOMOBILE_DIR)
	cd $(GNOMOBILE_DIR) && git fetch --all --quiet && git checkout --quiet $(GNOMOBILE_REF)
	cd $(GNOMOBILE_DIR) && GOTOOLCHAIN=$(GO_TOOLCHAIN) $(MAKE) framework.ios
	rm -rf $@
	cp -R $(GNOMOBILE_DIR)/framework/ios/GnoCore.xcframework $@
	./scripts/flatten-xcframework.sh $@

## test: run the unit tests on a simulator
.PHONY: test
test: Frameworks/GnoCore.xcframework MoulApp.xcodeproj
	xcodebuild test \
		-project MoulApp.xcodeproj \
		-scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		-derivedDataPath $(DERIVED)

## build: compile the app for the simulator
.PHONY: build
build: Frameworks/GnoCore.xcframework MoulApp.xcodeproj
	xcodebuild build \
		-project MoulApp.xcodeproj \
		-scheme $(SCHEME) \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		-derivedDataPath $(DERIVED)

## run: build, install and launch on a booted simulator
.PHONY: run
run: build
	xcrun simctl boot '$(SIMULATOR)' 2>/dev/null || true
	open -a Simulator
	xcrun simctl install booted $(DERIVED)/Build/Products/Debug-iphonesimulator/MoulApp.app
	xcrun simctl launch booted $(BUNDLE_ID)

## install: same as run, kept for muscle memory
.PHONY: install
install: run

## clean: drop build output, keep the framework
.PHONY: clean
clean:
	rm -rf $(DERIVED) MoulApp.xcodeproj

## clean.all: also drop the framework and its gnomobile checkout
.PHONY: clean.all
clean.all: clean
	rm -rf Frameworks/GnoCore.xcframework .cache

## list: the targets
.PHONY: list
list:
	@grep -E '^## ' Makefile | sed 's/^## /  /'
