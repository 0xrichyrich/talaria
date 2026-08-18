# Talaria — developer entry points. Run from app/.
#
# Requirements:
#   make verify — a Swift 5.10+ toolchain. Command Line Tools are enough; the
#                 package deliberately compiles for macOS 14 (docs/ARCHITECTURE.md).
#   make ios    — full Xcode 16+ *and* XcodeGen (brew install xcodegen): the
#                 Xcode project is generated from ios/project.yml, never
#                 committed, and simulator builds need the iOS SDK that only
#                 Xcode ships.

.PHONY: ios verify landing clean

## Generate ios/Talaria.xcodeproj and build the app for the iOS Simulator
## (unsigned, same flags as CI). Requires Xcode — see header.
ios:
	cd ios && xcodegen generate && xcodebuild build \
		-project Talaria.xcodeproj \
		-scheme Talaria \
		-destination 'generic/platform=iOS Simulator' \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO

## Build the Swift package and run the protocol conformance checks.
## No Xcode project needed; this is the fast inner loop for non-UI work.
verify:
	cd Packages/Talaria && swift build && swift run talaria-verify

## The landing page is static HTML with no build step; it lives in the
## sibling landing/ tree, not under app/.
landing:
	@echo "Nothing to build: the landing page is static HTML."
	@echo "It lives at ../landing/index.html — preview with:"
	@echo "    open ../landing/index.html"

## Drop regenerable state. The .xcodeproj always comes back via xcodegen.
clean:
	rm -rf ios/Talaria.xcodeproj Packages/Talaria/.build
