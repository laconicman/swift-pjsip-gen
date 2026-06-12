# swift-pjsip-gen

[![Swift Versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Flaconicman%2Fswift-pjsip-gen%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/laconicman/swift-pjsip-gen)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Flaconicman%2Fswift-pjsip-gen%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/laconicman/swift-pjsip-gen)
[![Latest tag](https://img.shields.io/github/v/tag/laconicman/swift-pjsip-gen?label=release&sort=semver)](https://github.com/laconicman/swift-pjsip-gen/tags)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Swift code generation for PJSIP's C API.** SwiftPM plugins that parse the PJSIP
headers your app actually builds against — sourced from
[`swift-pjsip`](https://github.com/laconicman/swift-pjsip) — and generate the Swift
ergonomics the C importer doesn't give you.

## Why this exists

`import PJSIP` hands you PJSIP's C types verbatim, and the rough edges show up
immediately:

- Printing a `pjsua_acc_config` or a `pjsip_status_code` in a debugger or log gives
  you nothing useful — no case names, no field summaries.
- The PJSIP API surface is **huge** (dozens of config structs, enums with hundreds
  of cases) and **changes between releases**. Hand-written `CustomStringConvertible`
  extensions rot silently the moment you bump the binary.

So the extensions are *generated*, not written: the generator walks the real headers
shipped inside the `swift-pjsip` xcframework, discovers the types transitively from
the roots you name, and emits `@retroactive CustomStringConvertible` /
`CustomDebugStringConvertible` conformances that match the exact PJSIP version you
link. Bump `swift-pjsip`, rebuild, and the helpers regenerate to match.

The package shape follows
[`apple/swift-openapi-generator`](https://github.com/apple/swift-openapi-generator):
a core library, a thin CLI, a **build-tool plugin** (regenerate on every build) and a
**command plugin** (generate on demand, commit the output) — use either or both.

## Products

| Product                | Kind       | Purpose                                                     |
|------------------------|------------|-------------------------------------------------------------|
| `PJSIPSwiftGenCore`    | library    | Header parsing, type discovery, code generation primitives. |
| `pjsip-swift-gen`      | executable | Thin CLI wrapping the core library.                         |
| `PJSIPSwiftGenPlugin`  | build tool | Runs the generator on every build of the consuming target.  |
| `PJSIPSwiftGenCommand` | command    | Runs the generator on demand (`swift package plugin …`).    |

## Usage

### 1. Add both packages

Declare `swift-pjsip-gen` **and** `swift-pjsip` in the consumer. (The plugin finds
PJSIP's headers by walking your dependency graph for the `swift-pjsip` checkout, so
the consumer must depend on it directly — which a PJSIP app does anyway.)

```swift
dependencies: [
    .package(url: "https://github.com/laconicman/swift-pjsip", from: "0.1.0"),
    .package(url: "https://github.com/laconicman/swift-pjsip-gen", from: "0.1.0"),
]
```

### 2. Configure the target

Drop a `pjsip-swift-gen.json` into the target's source directory (for Xcode app
targets: add it to the target, so the plugin sees it among the input files):

```json
{
    "searchRoots": [""],
    "rootTypes": ["pjsua_acc_config", "pjsua_call_info", "pjsip_status_code"],
    "skipTypes": ["pj_str_t", "pjsip_hdr"],
    "manualTypes": [],
    "imports": ["PJSIP"]
}
```

| Key | Meaning |
|-----|---------|
| `searchRoots` | Subdirectories of the headers root to scan. `[""]` scans the whole tree — right for the xcframework's flat `Headers/`. |
| `rootTypes` | Seed types; their struct fields are walked transitively to discover more. |
| `skipTypes` | Never discover/generate these. |
| `manualTypes` | Discovered but not generated — you maintain a hand-written extension. |
| `imports` | Modules to import at the top of every generated file (e.g. `["PJSIP"]`). |
| `pjprojectRoot` | *(optional)* Explicit headers path; only needed when auto-discovery can't run (see below). |

### 3a. Attach the build-tool plugin (regenerate every build)

```swift
.target(
    name: "MySipFeature",
    dependencies: [.product(name: "PJSIP", package: "swift-pjsip")],
    plugins: [.plugin(name: "PJSIPSwiftGenPlugin", package: "swift-pjsip-gen")]
)
```

Generated files land in the plugin work directory and compile into the target
automatically — nothing to commit.

### 3b. …or run the command plugin (generate once, commit)

```bash
swift package plugin --allow-writing-to-package-directory \
    generate-pjsip-helpers [--target MySipFeature] [--output-dir Sources/MySipFeature/Generated]
```

Defaults: every target containing a `pjsip-swift-gen.json`, output to
`<target>/Generated`.

### What gets generated

For an enum, a `debugDescription`/`description` that names the case; for a struct, a
`description` summarizing its fields (with PJSIP's `count` + fixed-size-array pairs
rendered as real collections — that path expects a small `tupleToArray(_:count:as:)`
helper in the consuming module). Every file is marked auto-generated and
`#if`-guarded to mirror preprocessor conditions found in the headers.

```swift
// Auto-generated from pjsua.h. DO NOT EDIT MANUALLY.

import PJSIP

extension pjsua_state: @retroactive CustomDebugStringConvertible {
    public var debugDescription: String { ... }
}
```

### How the plugin finds PJSIP's headers

In order:

1. **SwiftPM builds:** walks the consumer's dependency graph for the `swift-pjsip`
   package and reads `Binaries/PJSIP.xcframework/<slice>/Headers` directly.
2. **Xcode builds:** Xcode's plugin API exposes no dependency graph, so the plugin
   walks up from its work directory inside DerivedData to
   `SourcePackages/checkouts/swift-pjsip/…`.
3. **Escape hatch:** `pjprojectRoot` in the JSON config (resolved relative to the
   config file) — also how you point the generator at a raw `pjproject` source tree
   instead of the xcframework.

### CI note

`xcodebuild` refuses to run unvalidated plugins non-interactively. In CI, pass:

```bash
xcodebuild ... -skipPackagePluginValidation
```

## Architecture

```
Sources/PJSIPSwiftGenCore/      parsing + discovery + generation (the only logic home)
Sources/pjsip-swift-gen/        CLI: `generate`, `list-outputs`
Plugins/PJSIPSwiftGenPlugin/    build-tool plugin (+ duplicated discovery sources, see below)
Plugins/PJSIPSwiftGenCommand/   command plugin
Tests/                          core tests
scripts/check-duplicate-sources.sh
```

Two SwiftPM plugin constraints shape the design, and both are documented in detail
in [`docs/DESIGN.md`](docs/DESIGN.md):

- **Plugin targets cannot import library targets**, and in Xcode the plugin cannot
  spawn its own executable during build planning (the tool path is still an
  unresolved `${BUILD_DIR}` placeholder at that point). The discovery sources are
  therefore **deliberately duplicated** into the build-tool plugin;
  `scripts/check-duplicate-sources.sh --common Sources/PJSIPSwiftGenCore
  Plugins/PJSIPSwiftGenPlugin` guards byte-equality.
- **Outputs must be declared at build-planning time**, so the plugin re-runs
  discovery itself and declares the config file *and every PJSIP header* as inputs —
  bumping `swift-pjsip` invalidates the build commands and regeneration happens
  exactly when it should.

## Roadmap

Ideas under consideration — issues and PRs welcome:

- Import C enums as real Swift `enum`s (instead of the importer's `static let`s),
  with `OptionSet` generation for flag-style enums.
- Ergonomic `pj_str_t` ⇄ `String` bridging helpers.
- Carry Doxygen comments from the headers into the generated declarations.
- Ship the `tupleToArray` helper instead of expecting it from the consumer.
- A minimal reproduction to retest whether the source duplication is still forced
  (see [`docs/DESIGN.md`](docs/DESIGN.md#open-questions)).

## Sister projects

- [`swift-pjsip`](https://github.com/laconicman/swift-pjsip) — PJSIP as a single
  SPM binary package (the headers this generator consumes), including the
  reproducible xcframework build scripts.

## License

[MIT](LICENSE).
