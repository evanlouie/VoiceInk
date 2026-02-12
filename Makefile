# Define a directory for dependencies in the user's home folder
DEPS_DIR := $(HOME)/VoiceInk-Dependencies
WHISPER_CPP_DIR := $(DEPS_DIR)/whisper.cpp
FRAMEWORK_PATH := $(WHISPER_CPP_DIR)/build-apple/whisper.xcframework

.PHONY: all clean whisper setup build local check healthcheck help dev run

# Default target
all: check build

# Development workflow
dev: build run

# Prerequisites
check:
	@echo "Checking prerequisites..."
	@command -v git >/dev/null 2>&1 || { echo "git is not installed"; exit 1; }
	@command -v xcodebuild >/dev/null 2>&1 || { echo "xcodebuild is not installed (need Xcode)"; exit 1; }
	@command -v swift >/dev/null 2>&1 || { echo "swift is not installed"; exit 1; }
	@echo "Prerequisites OK"

healthcheck: check

# Build process — macOS-only whisper.xcframework (skips iOS/visionOS/tvOS)
whisper:
	@mkdir -p $(DEPS_DIR)
	@if [ ! -d "$(FRAMEWORK_PATH)" ]; then \
		echo "Building whisper.xcframework (macOS only) in $(DEPS_DIR)..."; \
		if [ ! -d "$(WHISPER_CPP_DIR)" ]; then \
			git clone https://github.com/ggerganov/whisper.cpp.git $(WHISPER_CPP_DIR); \
		else \
			(cd $(WHISPER_CPP_DIR) && git pull); \
		fi; \
		cd $(WHISPER_CPP_DIR) && $(MAKE) -f $(CURDIR)/Makefile _whisper-macos-only; \
	else \
		echo "whisper.xcframework already built in $(DEPS_DIR), skipping build"; \
	fi

# Internal target: builds whisper.cpp for macOS only and packages as xcframework.
# Runs inside $(WHISPER_CPP_DIR).
_whisper-macos-only:
	@echo "==> Cleaning previous macOS build..."
	rm -rf build-macos build-apple
	@echo "==> Configuring cmake for macOS (arm64 + x86_64)..."
	cmake -B build-macos -G Xcode \
		-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO \
		-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY="" \
		-DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
		-DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT="dwarf-with-dsym" \
		-DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=YES \
		-DCMAKE_XCODE_ATTRIBUTE_COPY_PHASE_STRIP=NO \
		-DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO \
		-DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM=ggml \
		-DBUILD_SHARED_LIBS=OFF \
		-DWHISPER_BUILD_EXAMPLES=OFF \
		-DWHISPER_BUILD_TESTS=OFF \
		-DWHISPER_BUILD_SERVER=OFF \
		-DGGML_METAL_EMBED_LIBRARY=ON \
		-DGGML_BLAS_DEFAULT=ON \
		-DGGML_METAL=ON \
		-DGGML_METAL_USE_BF16=ON \
		-DGGML_NATIVE=OFF \
		-DGGML_OPENMP=OFF \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=13.3 \
		-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
		-DCMAKE_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g" \
		-DCMAKE_CXX_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g" \
		-DWHISPER_COREML=ON \
		-DWHISPER_COREML_ALLOW_FALLBACK=ON \
		-S .
	@echo "==> Building whisper for macOS..."
	cmake --build build-macos --config Release -- -quiet
	@echo "==> Creating macOS framework structure..."
	@# Create versioned framework structure (macOS style)
	mkdir -p build-macos/framework/whisper.framework/Versions/A/Headers
	mkdir -p build-macos/framework/whisper.framework/Versions/A/Modules
	mkdir -p build-macos/framework/whisper.framework/Versions/A/Resources
	ln -sf A build-macos/framework/whisper.framework/Versions/Current
	ln -sf Versions/Current/Headers build-macos/framework/whisper.framework/Headers
	ln -sf Versions/Current/Modules build-macos/framework/whisper.framework/Modules
	ln -sf Versions/Current/Resources build-macos/framework/whisper.framework/Resources
	ln -sf Versions/Current/whisper build-macos/framework/whisper.framework/whisper
	@# Copy headers
	cp include/whisper.h           build-macos/framework/whisper.framework/Versions/A/Headers/
	cp ggml/include/ggml.h         build-macos/framework/whisper.framework/Versions/A/Headers/
	cp ggml/include/ggml-alloc.h   build-macos/framework/whisper.framework/Versions/A/Headers/
	cp ggml/include/ggml-backend.h build-macos/framework/whisper.framework/Versions/A/Headers/
	cp ggml/include/ggml-metal.h   build-macos/framework/whisper.framework/Versions/A/Headers/
	cp ggml/include/ggml-cpu.h     build-macos/framework/whisper.framework/Versions/A/Headers/
	cp ggml/include/ggml-blas.h    build-macos/framework/whisper.framework/Versions/A/Headers/
	cp ggml/include/gguf.h         build-macos/framework/whisper.framework/Versions/A/Headers/
	@# Create module map
	@printf 'framework module whisper {\n\
	    header "whisper.h"\n\
	    header "ggml.h"\n\
	    header "ggml-alloc.h"\n\
	    header "ggml-backend.h"\n\
	    header "ggml-metal.h"\n\
	    header "ggml-cpu.h"\n\
	    header "ggml-blas.h"\n\
	    header "gguf.h"\n\
	    link "c++"\n\
	    link framework "Accelerate"\n\
	    link framework "Metal"\n\
	    link framework "Foundation"\n\
	    export *\n\
	}\n' > build-macos/framework/whisper.framework/Versions/A/Modules/module.modulemap
	@# Create Info.plist
	@printf '<?xml version="1.0" encoding="UTF-8"?>\n\
	<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n\
	<plist version="1.0">\n\
	<dict>\n\
	    <key>CFBundleDevelopmentRegion</key><string>en</string>\n\
	    <key>CFBundleExecutable</key><string>whisper</string>\n\
	    <key>CFBundleIdentifier</key><string>org.ggml.whisper</string>\n\
	    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>\n\
	    <key>CFBundleName</key><string>whisper</string>\n\
	    <key>CFBundlePackageType</key><string>FMWK</string>\n\
	    <key>CFBundleShortVersionString</key><string>1.0</string>\n\
	    <key>CFBundleVersion</key><string>1</string>\n\
	    <key>MinimumOSVersion</key><string>13.3</string>\n\
	    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>\n\
	    <key>DTPlatformName</key><string>macosx</string>\n\
	    <key>DTSDKName</key><string>macosx13.3</string>\n\
	</dict>\n\
	</plist>\n' > build-macos/framework/whisper.framework/Versions/A/Resources/Info.plist
	@echo "==> Combining static libraries into dynamic framework..."
	@# Combine all static libs into one
	mkdir -p build-macos/temp
	libtool -static -o build-macos/temp/combined.a \
		build-macos/src/Release/libwhisper.a \
		build-macos/ggml/src/Release/libggml.a \
		build-macos/ggml/src/Release/libggml-base.a \
		build-macos/ggml/src/Release/libggml-cpu.a \
		build-macos/ggml/src/ggml-metal/Release/libggml-metal.a \
		build-macos/ggml/src/ggml-blas/Release/libggml-blas.a \
		build-macos/src/Release/libwhisper.coreml.a \
		2>/dev/null
	@# Create dynamic library
	xcrun -sdk macosx clang++ -dynamiclib \
		-isysroot $$(xcrun --sdk macosx --show-sdk-path) \
		-arch arm64 -arch x86_64 \
		-mmacosx-version-min=13.3 \
		-Wl,-force_load,build-macos/temp/combined.a \
		-framework Foundation -framework Metal -framework Accelerate -framework CoreML \
		-install_name "@rpath/whisper.framework/Versions/Current/whisper" \
		-o build-macos/framework/whisper.framework/Versions/A/whisper
	@echo "==> Creating dSYM..."
	mkdir -p build-macos/dSYMs
	xcrun strip -S build-macos/framework/whisper.framework/Versions/A/whisper \
		-o build-macos/temp/stripped_lib
	xcrun dsymutil build-macos/framework/whisper.framework/Versions/A/whisper \
		-o build-macos/dSYMs/whisper.dSYM
	mv build-macos/temp/stripped_lib build-macos/framework/whisper.framework/Versions/A/whisper
	rm -rf build-macos/temp
	@echo "==> Packaging xcframework (macOS only)..."
	xcodebuild -create-xcframework \
		-framework $$(pwd)/build-macos/framework/whisper.framework \
		-debug-symbols $$(pwd)/build-macos/dSYMs/whisper.dSYM \
		-output $$(pwd)/build-apple/whisper.xcframework
	@echo "==> Done! whisper.xcframework built for macOS only."

setup: whisper
	@echo "Whisper framework is ready at $(FRAMEWORK_PATH)"
	@echo "Please ensure your Xcode project references the framework from this new location."

build: setup
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug CODE_SIGN_IDENTITY="" build

# Build for local use without Apple Developer certificate
local: check setup
	@echo "Building VoiceInk for local use (no Apple Developer certificate required)..."
	xcodebuild -project VoiceInk.xcodeproj -scheme VoiceInk -configuration Debug \
		-xcconfig LocalBuild.xcconfig \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGNING_REQUIRED=NO \
		CODE_SIGNING_ALLOWED=YES \
		DEVELOPMENT_TEAM="" \
		CODE_SIGN_ENTITLEMENTS=$(CURDIR)/VoiceInk/VoiceInk.local.entitlements \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) LOCAL_BUILD' \
		build
	@APP_PATH=$$(find "$$HOME/Library/Developer/Xcode/DerivedData" -name "VoiceInk.app" -path "*/Debug/*" -type d | head -1) && \
	if [ -n "$$APP_PATH" ]; then \
		echo "Copying VoiceInk.app to ~/Downloads..."; \
		rm -rf "$$HOME/Downloads/VoiceInk.app"; \
		ditto "$$APP_PATH" "$$HOME/Downloads/VoiceInk.app"; \
		xattr -cr "$$HOME/Downloads/VoiceInk.app"; \
		echo ""; \
		echo "Build complete! App saved to: ~/Downloads/VoiceInk.app"; \
		echo "Run with: open ~/Downloads/VoiceInk.app"; \
		echo ""; \
		echo "Limitations of local builds:"; \
		echo "  - No iCloud dictionary sync"; \
		echo "  - No automatic updates (pull new code and rebuild to update)"; \
	else \
		echo "Error: Could not find built VoiceInk.app in DerivedData."; \
		exit 1; \
	fi

# Run application
run:
	@if [ -d "$$HOME/Downloads/VoiceInk.app" ]; then \
		echo "Opening ~/Downloads/VoiceInk.app..."; \
		open "$$HOME/Downloads/VoiceInk.app"; \
	else \
		echo "Looking for VoiceInk.app in DerivedData..."; \
		APP_PATH=$$(find "$$HOME/Library/Developer/Xcode/DerivedData" -name "VoiceInk.app" -type d | head -1) && \
		if [ -n "$$APP_PATH" ]; then \
			echo "Found app at: $$APP_PATH"; \
			open "$$APP_PATH"; \
		else \
			echo "VoiceInk.app not found. Please run 'make build' or 'make local' first."; \
			exit 1; \
		fi; \
	fi

# Cleanup
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf $(DEPS_DIR)
	@echo "Clean complete"

# Help
help:
	@echo "Available targets:"
	@echo "  check/healthcheck  Check if required CLI tools are installed"
	@echo "  whisper            Clone and build whisper.cpp XCFramework"
	@echo "  setup              Copy whisper XCFramework to VoiceInk project"
	@echo "  build              Build the VoiceInk Xcode project"
	@echo "  local              Build for local use (no Apple Developer certificate needed)"
	@echo "  run                Launch the built VoiceInk app"
	@echo "  dev                Build and run the app (for development)"
	@echo "  all                Run full build process (default)"
	@echo "  clean              Remove build artifacts"
	@echo "  help               Show this help message"