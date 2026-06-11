# swift-pjsip-gen

Swift code generator for PJSIP. Produces Swift extensions, conformances, and
helpers for the C types exposed by [`swift-pjsip`](https://github.com/laconicman/swift-pjsip).

Status: **work in progress**. Initial milestone is a port of the original
`PJSIPDebugGen` (debug-print conformances) into a reusable, dual-mode Swift
package.

## Products

| Product                  | Kind         | Purpose                                                        |
|--------------------------|--------------|----------------------------------------------------------------|
| `PJSIPSwiftGenCore`      | library      | Header parsing, type discovery, code generation primitives.    |
| `pjsip-swift-gen`        | executable   | Thin CLI wrapping the core library.                            |
| `PJSIPSwiftGenPlugin`    | build-tool   | Runs the generator on every build of the consuming target.     |
| `PJSIPSwiftGenCommand`   | command      | Runs the generator on demand (`swift package plugin …`).       |

The two plugins are independent — a consumer can attach the build-tool plugin
for automatic regeneration, invoke the command plugin manually, or wire up
both.

## Dependencies

- [`swift-pjsip`](https://github.com/laconicman/swift-pjsip) — the C headers
  parsed by the generator are sourced from this package's xcframework.

## Configuration

A JSON config file describes which root types to discover, which to skip, and
which modules to import in generated files:

```json
{
    "rootTypes": ["pjsua_acc_config", "pjsip_hdr_e"],
    "skipTypes": ["pj_str_t", "pjsip_hdr"],
    "manualTypes": [],
    "imports": ["PJSIP"]
}
```

## License

[MIT](LICENSE).
