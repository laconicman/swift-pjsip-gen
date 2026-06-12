# ``PJSIPSwiftGenCore``

Header parsing, type discovery, and Swift code generation for PJSIP's C API.

## Overview

`PJSIPSwiftGenCore` is the engine behind the `pjsip-swift-gen` CLI and the
SwiftPM plugins of the
[swift-pjsip-gen](https://github.com/laconicman/swift-pjsip-gen) package.

Given a ``PJSIPSwiftGenConfig`` (typically loaded from a `pjsip-swift-gen.json`
file) and the path to a PJSIP headers tree — either the `Headers/` directory of
the [swift-pjsip](https://github.com/laconicman/swift-pjsip) xcframework or a
raw `pjproject` source checkout — it:

1. **Discovers** the C enums and structs reachable from the configured
   `rootTypes`, walking struct fields transitively
   (``discoverTypes(config:pjprojectRoot:)``).
2. **Predicts** the generated file names without generating, so build-tool
   plugins can declare their outputs up front
   (``expectedOutputFilenames(for:manualSet:)``).
3. **Generates** `@retroactive CustomStringConvertible` /
   `CustomDebugStringConvertible` conformances for the discovered types
   (``generateEnumConformances(enumName:headerPath:outputDir:imports:ppCondition:)``,
   ``generateStructConformance(structName:headerPath:outputDir:imports:ppCondition:)``),
   preserving `#if` preprocessor conditions found in the headers.

The parser is a purpose-built, lightweight C header scanner — not a full Clang
frontend — tuned to PJSIP's header conventions. Design rationale and the
SwiftPM plugin constraints that shaped the package live in the repository's
`docs/DESIGN.md`.

## Topics

### Configuration

- ``PJSIPSwiftGenConfig``
- ``resolvePath(_:relativeTo:)``

### Type discovery

- ``discoverTypes(config:pjprojectRoot:)``
- ``DiscoveryResult``
- ``DiscoveredType``
- ``TypeKind``
- ``expectedOutputFilenames(for:manualSet:)``

### Code generation

- ``generateEnumConformances(enumName:headerPath:outputDir:imports:ppCondition:)``
- ``generateStructConformance(structName:headerPath:outputDir:imports:ppCondition:)``
