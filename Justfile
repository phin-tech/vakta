# Vakta dev tasks — run `just` to list.

# List available recipes
default:
    @just --list

# Build and run the app (quick, via SwiftPM). Needs a login shell so herdr is on PATH.
run:
    swift run Vakta

# Compile-check only
build:
    swift build

# Run with a plain shell instead of herdr (smoke test where herdr isn't installed)
run-shell:
    VAKTA_TERMINAL_COMMAND=/bin/zsh swift run Vakta

# Regenerate the Xcode project from project.yml
generate:
    xcodegen generate

# Build the .app bundle (Xcode) and open it
app: generate
    xcodebuild -project Vakta.xcodeproj -scheme Vakta -configuration Debug \
      -destination 'platform=macOS' -derivedDataPath .build/xcode build
    open .build/xcode/Build/Products/Debug/Vakta.app

# Build a Release .app and package a local (unsigned) .dmg
dmg: generate
    xcodebuild -project Vakta.xcodeproj -scheme Vakta -configuration Release \
      -destination 'platform=macOS' -derivedDataPath .build/xcode build
    rm -rf dmg-staging && mkdir -p dmg-staging
    cp -R .build/xcode/Build/Products/Release/Vakta.app dmg-staging/
    ln -s /Applications dmg-staging/Applications
    hdiutil create -volname Vakta -srcfolder dmg-staging -ov -format UDZO Vakta.dmg
    rm -rf dmg-staging
    @echo "Built Vakta.dmg"

# Build a Release .app and install it into /Applications (see scripts/install_app.sh)
install: generate
    xcodebuild -project Vakta.xcodeproj -scheme Vakta -configuration Release \
      -destination 'platform=macOS' -derivedDataPath .build/xcode build
    scripts/install_app.sh .build/xcode/Build/Products/Release/Vakta.app /Applications

# Cut a release: tag and push (CI builds + attaches the DMG). e.g. `just release 0.1.4`
release version:
    git tag v{{version}}
    git push origin v{{version}}

# Remove build artifacts
clean:
    rm -rf .build Vakta.xcodeproj dmg-staging Vakta.dmg
