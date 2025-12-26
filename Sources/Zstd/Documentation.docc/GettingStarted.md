# Getting Started

Use the `Zstd` module for one-shot compression, streaming pipelines, or async sequences. The library is vendored with Zstandard `v1.5.7` so you do not need external system dependencies.

## Requirements
- Swift 6.2 or newer
- macOS 13+, iOS 15+, tvOS 15+, watchOS 9+, or Linux

## Add the package
```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/Apurer/swift-zstd.git", from: "0.1.0")
],
targets: [
    .target(name: "YourTarget", dependencies: ["Zstd"])
]
```

When cloning locally include the submodule:

```bash
git clone --recurse-submodules git@github.com:Apurer/swift-zstd.git
```

## Basic round-trip
```swift
import Zstd

let payload = Data("payload".utf8)
let compressed = try Zstd.compress(payload)
let restored = try Zstd.decompress(compressed)
```

## Streaming reuse
Reuse contexts to reduce allocations and avoid rebuilding C state:

```swift
let compressor = try Zstd.Compressor(options: .init(level: 5, threads: 2))
var output = Data(), scratch = Data()

for chunk in someChunks {
    scratch.removeAll(keepingCapacity: true)
    try compressor.compress(chunk, into: &scratch)
    output.append(scratch)
}
try compressor.finish(into: &scratch)
output.append(scratch)
```

See <doc:StreamingVsOneShot> for detailed patterns.
