import Testing

// Entry point of the Swift Testing runner (the same thing `swift test` does in the Xcode toolchain).
// The variant that returns Never ends the process itself with the result code.
let entry: (Testing.__CommandLineArguments_v0?) async -> Never = Testing.__swiftPMEntryPoint(passing:)
await entry(nil)
