# Design notes — swift-pjsip-gen

Why this package is shaped the way it is. Several choices look odd from the
outside (duplicated sources, a `list-outputs` CLI verb the plugin no longer
calls); each traces back to a hard SwiftPM/Xcode plugin constraint that was hit,
diagnosed, and worked around during development. This file records the
constraints and the evidence, so future refactors don't re-learn them the
expensive way.

## Goals

- Generate Swift conveniences (debug-print conformances today, richer wrappers
  over time) for the C types vended by
  [`swift-pjsip`](https://github.com/laconicman/swift-pjsip), keyed off the
  *actual headers* of the PJSIP build being linked.
- Work as a reusable, standalone open-source package — not an in-tree tool.
- Support both plugin styles, modelled on
  [`apple/swift-openapi-generator`](https://github.com/apple/swift-openapi-generator):
  a **build-tool plugin** (regenerate transparently on every build) and a
  **command plugin** (generate on demand, commit the output). The consumer
  chooses.

## Naming

| Thing | Name |
|-------|------|
| Repository | `swift-pjsip-gen` (mirrors `swift-pjsip`) |
| Executable | `pjsip-swift-gen` |
| Library / plugins | `PJSIPSwiftGenCore`, `PJSIPSwiftGenPlugin`, `PJSIPSwiftGenCommand` |

## The plugin constraints that shaped the architecture

### 1. Plugin targets cannot import library targets

A SwiftPM `.plugin` target may depend on *executables* (to invoke) but cannot
`import` a library target ([SE-0303](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0303-swiftpm-extensible-build-tools.md)).
Any logic the plugin itself needs at build-planning time must live inside the
plugin directory.

### 2. Build-tool plugins must declare outputs at planning time

`createBuildCommands` returns `Command.buildCommand(... outputFiles:)` — the
build system needs the output list **before** anything runs. Our output list is
*dynamic*: it depends on which types are discovered in the PJSIP headers. So
discovery must run during planning.

### 3. In Xcode, the plugin cannot spawn its own executable during planning

The initial architecture avoided source duplication elegantly: the executable
had a `list-outputs` verb, and the plugin spawned it synchronously in
`createBuildCommands` to learn the output names. This worked perfectly under
`swift build` — SwiftPM pre-builds plugin tool dependencies before invoking the
plugin.

Under Xcode it failed:

```
Apply build tool plug-in "PJSIPSwiftGenPlugin" to target "…"
Error: The file "pjsip-swift-gen" doesn't exist.
NSFilePath=/${BUILD_DIR}/${CONFIGURATION}/pjsip-swift-gen
```

The literal, unresolved `${BUILD_DIR}` is the tell: in Xcode contexts,
`context.tool(named:).path` is a **deferred build-variable reference** — the
tool is built as part of the same build graph and does not exist on disk when
`createBuildCommands` runs. Spawning it at planning time is therefore
impossible in Xcode, even though it works in SwiftPM.

`prebuildCommand` is not an out either: prebuild commands may only use
*vendored binaries* (`binaryTarget` artifact bundles), not executables built
from package sources — and vendoring a prebuilt generator binary would defeat
the purpose of a source package.

**Consequence:** discovery runs *in-plugin*. Combined with constraint 1, the
discovery sources (`Config.swift`, `CHeaderParser.swift`, `TypeDiscoverer.swift`)
are **byte-identical duplicates** of the `PJSIPSwiftGenCore` versions, and
`scripts/check-duplicate-sources.sh --common Sources/PJSIPSwiftGenCore
Plugins/PJSIPSwiftGenPlugin` fails the moment they drift. The cost is ~3 files;
the benefit is correct behavior in both build systems.

The `list-outputs` verb stays on the CLI: it is still useful for humans and
tests, just no longer load-bearing for the plugin.

## Locating the PJSIP headers (three-way resolution)

The generator needs the headers of the exact PJSIP build the consumer links.
Resolution order, with a `Diagnostics.remark` trace at each branch:

1. **SwiftPM contexts** — walk `context.package.dependencies` recursively for
   the package whose manifest name is `PJSIP` (what `swift-pjsip/Package.swift`
   declares), then read
   `<checkout>/Binaries/PJSIP.xcframework/<first slice with Headers>/Headers`.
   The `<slice>/Headers` layout is the canonical, stable xcframework shape per
   Apple's ["Creating a multi-platform binary framework bundle"](https://developer.apple.com/documentation/xcode/creating-a-multi-platform-binary-framework-bundle).
2. **Xcode contexts** — `XcodePluginContext` exposes **no** dependency-graph
   API, so walk parent directories of the plugin work directory (which lives
   inside the project's DerivedData) looking for
   `SourcePackages/checkouts/swift-pjsip/Binaries/PJSIP.xcframework`. The
   `SourcePackages/` directory sits next to `Build/` in DerivedData, so the
   walk-up terminates quickly.
3. **Explicit escape hatch** — `pjprojectRoot` in `pjsip-swift-gen.json`,
   resolved relative to the config file. Also the way to point the generator at
   a raw `pjproject` source tree rather than the xcframework.

## Greedy `inputFiles` (stale-codegen prevention)

The build-tool plugin declares the JSON config **and every `.h` file under the
resolved headers root** as inputs of the generated build command. An undeclared
input means edits to it don't retrigger generation; the resulting stale-codegen
debugging session is brutal because the build "succeeds". Concretely: bumping
the `swift-pjsip` package version replaces the entire Headers tree — with greedy
inputs, that automatically invalidates the command and regenerates everything.

## Dependency pinning

`swift-pjsip` is pinned `from: "0.1.0"` rather than `branch: "main"`: header
drift becomes an explicit, reviewable version bump instead of a silent change.

## Open questions

1. **Is the source duplication actually forced?** The `${BUILD_DIR}` diagnosis
   came from a single noisy `xcodebuild` run that also involved stale workspace
   state. It matches the documented behavior difference (SwiftPM pre-builds
   plugin tools; Xcode defers them), but a minimal reproduction — a tiny
   build-tool plugin spawning its own executable in `createBuildCommands`,
   tested under both `swift build` and `xcodebuild` — has not been built. If
   Xcode handles it after all, the duplication can be dropped.
2. **The unused-dependency warning.** SwiftPM warns that the `swift-pjsip`
   dependency "is not used by any target" — true at the target-graph level: the
   plugin uses it only through the filesystem walk. Living with the warning,
   plus having consumers declare `swift-pjsip` directly (which a PJSIP app needs
   anyway), beats the alternative of making `PJSIPSwiftGenCore` nominally
   `import PJSIP` (which would drag a ~26 MB binary into the generator's own
   build).
3. **Plugin trust in CI.** The Xcode IDE prompts interactively to trust build
   plugins (and re-prompts when the plugin fingerprint changes); headless
   `xcodebuild` just fails with `Validate plug-in "…"`. CI must pass
   `-skipPackagePluginValidation`. Worth automating into any CI recipe that
   builds a consumer of this package.

## Preprocessor guards on discovered members (the G1 fix)

`CHeaderParser` records the innermost `#if` around each discovered enum case or
struct field as a **C macro name**. Emitting that name into a Swift `#if` looks
right and is not: Swift `#if` only knows conditions declared via `-D` /
`swiftSettings`, and an unknown identifier there evaluates to **false**. Every
guarded member was therefore deleted from the generated output — on every
platform, silently, because the result still compiles.

Measured against the shipped `swift-pjsip` headers: 4 guards across 156 generated
files, of which one — `PJ_HAS_FLOATING_POINT`, value **1** — was wrongly dropping
`pj_math_stat.fmean_` and `.mean_res_`, i.e. the mean of every jitter and RTT
statistic.

**The fix is to resolve the CONDITION, not to look up the macro.** Mapping macros to `os(iOS)`-style
conditions only works for platform macros, and none of the four real cases is one;
they are all build-configuration macros. But the value is knowable exactly: the
generated code is compiled against *one* prebuilt binary whose `config_site.h`
ships inside the same `Headers/` directory being parsed. `MacroResolver` runs
`clang -E -dM` over the PJSIP config headers once (~5000 macros, one invocation)
and the generators then **include or omit the member outright**. No `#if` appears
in generated output at all.

An earlier cut of this resolved the macro *name* and tested it for non-zero. Review caught that
this is wrong for every inverted or comparing guard — `#ifndef X`, `#if !X`, `#if X == 0`,
`#if X < 2` — where a truthy macro means the member is **absent**. Getting that backwards emits a
member the preprocessor removed, which is a hard compile error in the consumer and strictly worse
than the silent omission being fixed. It was not hypothetical: `pj_math_stat` puts `fmean_` under
`#if PJ_HAS_FLOATING_POINT` and `mean_res_` under its `#else`, so the name-based version emitted
both and produced code that would not compile.

So the parser records what the directive *means* (`normalizedCondition`: `#ifdef X` →
`defined(X)`, `#ifndef X` → `!defined(X)`, `#if EXPR` → `EXPR`), an `#else` arm records the
negation of its opening condition, and clang evaluates the whole expression verbatim. Handing the
condition to clang also disposes of non-integer macro values — `(1)`, hex, aliases — for free.

An `#elif` arm holds only when every earlier arm did not, which this single-condition model cannot
express; the rest of such a chain is marked unresolvable rather than guessed. None occur in the
headers today.

Rules that fell out, and are worth keeping:

- **Unresolvable guard ⇒ omit, and say so on stderr.** Omitting is the compiling
  direction (a member absent from the binary would be a consumer compile error);
  silence is what made the original defect survive. Never a `#warning` in
  generated source — that would fire on every consumer build forever for
  something only the generator can fix.
- **A guarded-out *type* still gets its file**, containing a comment explaining
  why it is empty. Build-tool plugins declare `outputFiles` at plan time, so a
  file that simply vanishes breaks the incremental contract (constraint 2 above).
- **Anything that must all hold, resolves together.** A count+array pair carries two guards
  (`CountArrayPair.ppCondition` and `.arrayPPCondition`); emitting on the count's alone can
  reference an array field that was compiled out. `resolveGuards(_:with:)` lets either side veto.
- **The unresolvable sentinel is refused before the preprocessor, not by it.** C treats an
  undefined identifier in `#if` as `0`, so handing a sentinel to clang returns a confident
  "false" and drops the member silently — the exact failure mode this work exists to end.
- **Never leave the child's stderr on an unread pipe.** `Process` with `standardError = Pipe()`
  and no reader deadlocks as soon as clang emits more diagnostics than the buffer holds: it blocks
  writing stderr, never closes stdout, and the stdout read waits forever. `FileHandle.nullDevice`.
- **The probe's include path covers both header layouts** — the xcframework's flat `Headers/` and
  a raw `pjproject` checkout's `<subproject>/include`, which is still a documented way to point
  the generator at sources. Without the latter the probe fails on a raw tree and *every* guarded
  member is omitted.

## Known defect: slice selection ignores the build platform (G2)

`firstSlice()` (`Plugins/PJSIPSwiftGenPlugin/Plugin.swift`) picks the
**alphabetically first** xcframework slice directory containing `Headers/`. Today
the artifact ships `ios-arm64` and `ios-arm64-simulator`, so that is correct **by
accident**.

The moment `swift-pjsip` adds the planned `macos-arm64` slice, `"ios-arm64"` still
sorts first — so **a macOS build would generate Swift from the iOS headers** and
look fine doing it. With G1 fixed this is now the *only* silent wrongness left in
the pipeline, and it is worse than it looks: `MacroResolver` would then resolve
guards against the iOS `config_site.h` while compiling against the macOS binary,
turning a header mismatch into member-level mismatches.

Not fixed here — this branch is deliberately scoped to G1, which is live on iOS
today and independently valuable. The fix, when the macOS slice lands: map
`PluginContext`'s target platform to the slice's `SupportedPlatform` /
`SupportedPlatformVariant` from the xcframework `Info.plist` rather than sorting
names. Do **not** vary the *output file set* by platform — outputs are declared at
plan time (constraint 2); vary the contents.

## Verification practices that proved out

- Run the executable end-to-end against the real `swift-pjsip` xcframework
  headers (`list-outputs` makes the discovered surface visible — dozens of
  enums/structs resolving to ~80 output files) before trusting plugin behavior.
- When debugging plugin output under Xcode, find the *live* DerivedData first
  (`ls -lat ~/Library/Developer/Xcode/DerivedData/`) — project hashes change
  when the project file is regenerated, and searching a stale directory wastes
  hours.
- Don't trust IDE-side "build succeeded" reports from wrappers; check that the
  generated files actually appeared in the plugin work directory.
