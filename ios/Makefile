.PHONY: build ipa clean help icons

PROJECT        = Grogu.xcodeproj
SCHEME         = Grogu
CONFIGURATION ?= Release
UNSIGNED      ?=

ifeq ($(UNSIGNED),1)
DERIVED_DATA   = build/unsigned
SIGNING_FLAGS  = CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DEVELOPMENT_TEAM=
else
DERIVED_DATA   = build
SIGNING_FLAGS  = -allowProvisioningUpdates
endif

BUILD_DIR      = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)-iphoneos
MAIN_APP       = GroguApp.app
MAIN_IPA       = GroguApp.ipa
RUNNER_APP     = GroguRunner-Runner.app
RUNNER_BIN     = GroguRunner-Runner
XCTEST_BUNDLE  = GroguRunner.xctest
RUNNER_IPA     = GroguRunner.ipa

Frameworks/IDevice.xcframework:
	@bash Scripts/fetch-idevice.sh

icons:
	@python3 Scripts/make-icons.py

$(PROJECT)/project.pbxproj: project.yml Config/Signing.xcconfig
	@command -v xcodegen >/dev/null || { echo "xcodegen not found — brew install xcodegen"; exit 1; }
	xcodegen generate --quiet

build: Frameworks/IDevice.xcframework $(PROJECT)/project.pbxproj
	xcodebuild build-for-testing \
		-project $(PROJECT) \
		-derivedDataPath $(DERIVED_DATA) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-destination "generic/platform=iOS" \
		$(SIGNING_FLAGS) \
		ARCHS=arm64
	@echo "Build completed in $(BUILD_DIR)"

ipa: build
	@set -e; \
	APP="$(BUILD_DIR)/$(RUNNER_APP)"; PLIST="$$APP/Info.plist"; PB=/usr/libexec/PlistBuddy; \
	rm -f "$$APP"/AppIcon*.png; \
	cp Config/RunnerIcon/*.png "$$APP/"; \
	$$PB -c "Delete :CFBundleIcons" "$$PLIST" 2>/dev/null || true; \
	$$PB -c "Delete :CFBundleIcons~ipad" "$$PLIST" 2>/dev/null || true; \
	$$PB -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles array" "$$PLIST"; \
	i=0; for n in AppIcon20x20 AppIcon29x29 AppIcon40x40 AppIcon60x60; do \
		$$PB -c "Add :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconFiles:$$i string $$n" "$$PLIST"; i=$$((i+1)); \
	done; \
	$$PB -c "Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles array" "$$PLIST"; \
	i=0; for n in AppIcon20x20 AppIcon29x29 AppIcon40x40 AppIcon76x76 AppIcon83.5x83.5; do \
		$$PB -c "Add :CFBundleIcons~ipad:CFBundlePrimaryIcon:CFBundleIconFiles:$$i string $$n" "$$PLIST"; i=$$((i+1)); \
	done
	rm -rf "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks/XCTAutomationSupport.framework" \
	       "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks/XCTest.framework" \
	       "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks/XCTestCore.framework" \
	       "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks/XCTestSupport.framework" \
	       "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks/XCUIAutomation.framework" \
	       "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks/XCUnit.framework" \
	       "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks/Testing.framework"
	rm -f  "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks/libXCTestSwiftSupport.dylib"
	@rmdir "$(BUILD_DIR)/$(RUNNER_APP)/Frameworks" 2>/dev/null || true
	@set -e; \
	APP="$(BUILD_DIR)/$(RUNNER_APP)"; \
	if nm -u "$$APP/$(RUNNER_BIN)" 2>/dev/null | grep -q '_OBJC_CLASS_$$_XCTCommandLineToolHelper' && \
	   ! otool -L "$$APP/$(RUNNER_BIN)" | grep -q libXCTCompatShim; then \
		SDK="$$(xcrun --sdk iphoneos --show-sdk-path)"; \
		mkdir -p "$$APP/Frameworks"; \
		xcrun -sdk iphoneos clang -dynamiclib -arch arm64 -isysroot "$$SDK" \
			-mios-version-min=17.0 -install_name "@rpath/libXCTCompatShim.dylib" \
			-framework Foundation -o "$$APP/Frameworks/libXCTCompatShim.dylib" \
			Compat/XCTCompatShim.m; \
		BIN="$$APP/$(RUNNER_BIN)"; TMP="$$BIN.patching"; \
		cp "$$BIN" "$$TMP"; \
		if python3 Scripts/insert-dylib.py "$$TMP" "@rpath/libXCTCompatShim.dylib" && \
		   ORD="$$(python3 Scripts/dylib-ordinal.py "$$TMP" libXCTCompatShim)" && \
		   python3 Scripts/retarget-bind-ordinal.py "$$TMP" '_OBJC_CLASS_$$_XCTCommandLineToolHelper' "$$ORD" && \
		   python3 Scripts/retarget-undef-symbol.py "$$TMP" '_OBJC_CLASS_$$_XCTCommandLineToolHelper' libXCTCompatShim; then \
			mv "$$TMP" "$$BIN"; \
		else \
			rm -f "$$TMP" "$$APP/Frameworks/libXCTCompatShim.dylib"; \
			rmdir "$$APP/Frameworks" 2>/dev/null || true; \
			echo "Skipping optional iOS 16 XCTCompatShim (not required for this XCTRunner stub)"; \
		fi; \
	fi
	find "$(BUILD_DIR)/$(RUNNER_APP)" -name "*.dSYM" -exec rm -rf {} + 2>/dev/null || true
	@PLIST="$(BUILD_DIR)/$(RUNNER_APP)/Info.plist"; \
	/usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$$PLIST" 2>/dev/null || true; \
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string dev.grogu.runner" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$$PLIST"; \
	/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string grogu-runner" "$$PLIST"
	@set -e; \
	RUNNER_PLIST="$(BUILD_DIR)/$(RUNNER_APP)/Info.plist"; \
	XCTEST_PLIST="$(BUILD_DIR)/$(RUNNER_APP)/PlugIns/$(XCTEST_BUNDLE)/Info.plist"; \
	RUNNER_ID="$$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$$RUNNER_PLIST")"; \
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $$RUNNER_ID" "$$XCTEST_PLIST"
	@rm -rf "$(BUILD_DIR)/Payload" && mkdir -p "$(BUILD_DIR)/Payload"
	cp -R "$(BUILD_DIR)/$(RUNNER_APP)" "$(BUILD_DIR)/Payload/"
	(cd "$(BUILD_DIR)" && zip -qry "$(CURDIR)/$(RUNNER_IPA)" Payload)
	@rm -rf "$(BUILD_DIR)/Payload" && mkdir -p "$(BUILD_DIR)/Payload"
	cp -R "$(BUILD_DIR)/$(MAIN_APP)" "$(BUILD_DIR)/Payload/"
	(cd "$(BUILD_DIR)" && zip -qry "$(CURDIR)/$(MAIN_IPA)" Payload)
	@rm -rf "$(BUILD_DIR)/Payload"
	@if [ "$(UNSIGNED)" = 1 ]; then \
		bash Scripts/package-ipas.sh release; \
	fi

clean:
	rm -rf build release $(PROJECT) $(MAIN_IPA) $(RUNNER_IPA)

help:
	@echo "make build UNSIGNED=1   # Unsigned Xcode build"
	@echo "make ipa   UNSIGNED=1   # Build + package release/{GroguApp,GroguRunner,GroguRunner-sideload}.ipa"
