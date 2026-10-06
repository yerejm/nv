.DEFAULT_GOAL := debug
.PHONY: debug release test clean
.NOTPARALLEL:

XCODEBUILD ?= /usr/bin/xcodebuild
CODE_SIGNING_ALLOWED ?= NO

debug: CONFIGURATION := Development
release: CONFIGURATION := Deployment
debug release:
	"$(XCODEBUILD)" -project Notation.xcodeproj -scheme Notation \
		-configuration "$(CONFIGURATION)" -derivedDataPath build/app \
		CODE_SIGNING_ALLOWED="$(CODE_SIGNING_ALLOWED)" build
	rm -rf -- "build/Notational Velocity.app"
	/usr/bin/ditto "build/app/Build/Products/$(CONFIGURATION)/Notational Velocity.app" \
		"build/Notational Velocity.app"

test:
	./script/test.sh
	./script/test_native.sh
	/usr/bin/python3 Tests/Build/test_build_policy.py

clean:
	rm -rf -- build
