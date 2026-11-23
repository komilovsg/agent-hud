import Testing

// Точка входа раннера Swift Testing (то же, что делает `swift test` в Xcode-тулчейне).
// Вариант, возвращающий Never, сам завершает процесс с кодом результата.
let entry: (Testing.__CommandLineArguments_v0?) async -> Never = Testing.__swiftPMEntryPoint(passing:)
await entry(nil)
