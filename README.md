# Docxer

A fast native macOS viewer and editor for Word `.docx` files. See [CONTEXT.md](CONTEXT.md) for the vocabulary and [docs/adr](docs/adr) for the two decisions that shape the code.

Saving never drops content: parts and paragraphs the user did not touch are copied byte for byte, and anything the app does not understand is kept as a sealed object.

## Build

```sh
xcodegen generate
xcodebuild -project Docxer.xcodeproj -scheme Docxer -configuration Release -derivedDataPath build/dd build
open build/dd/Build/Products/Release/Docxer.app
```

Install to /Applications with `tools/install.sh`.

## Test

```sh
cd DocxCore && swift test
swift build -c release
# From the folder the paths are relative to:
.build/release/docx-bench roundtrip FILES...   # unedited save is identical; verbatim and full rewrites keep the text
.build/release/docx-bench edits --out DIR FILES...   # scripted edits re-open with the same text
tools/validate.sh --json DIR/*.docx   # Open XML SDK validator; compare N.docx against N.orig.docx
```

The app accepts `-DocxerTiming YES` (startup and save times on stderr) and, for tests that must not take focus, `-DocxerBackgroundTest YES -DocxerScript FILE` (see `App/TestScript.swift`).

## Release

Forgejo is the source; https://github.com/alexander-pecheny/docxer is a push mirror, which deletes refs that exist only on GitHub. So tag on Forgejo, then publish the release on GitHub:

```sh
git tag v0.2 && git push origin v0.2
gh release create v0.2 --repo alexander-pecheny/docxer --verify-tag --generate-notes
```

Publishing runs `.github/workflows/release.yml`, which tests the core, builds a universal app versioned from the tag and attaches `Docxer-0.2.zip`. The build is ad-hoc signed, so on another Mac the first launch needs right-click › Open.
