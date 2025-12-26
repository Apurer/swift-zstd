# swift-zstd

[![CI](https://github.com/Apurer/swift-zstd/actions/workflows/ci.yml/badge.svg)](https://github.com/Apurer/swift-zstd/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Apurer/swift-zstd?display_name=tag)](https://github.com/Apurer/swift-zstd/releases)
[![Docs](https://img.shields.io/badge/docs-DocC-blue)](https://apurer.github.io/swift-zstd/documentation/swift_zstd)

Swift package that embeds the Zstandard C library and exposes allocation-aware one-shot, streaming, async sequence, and `FileHandle` APIs tailored for Swift.

## Features at a glance
- One-shot, streaming, async, and file-handle pipelines with reusable contexts to reduce allocations.
- Safety defaults: decompression caps, window log guard rails, explicit dictionary binding, and output limits.
- Multi-threaded compression compiled in; tune level, strategy, worker threads, job size, and window log.
- Pinned upstream Zstandard `v1.5.7` (vendored via submodule) for predictable behavior across platforms.
- Platforms: Swift 6.2+, macOS 13+, iOS 15+, tvOS 15+, watchOS 9+, Linux.

## Installation
Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/Apurer/swift-zstd.git", from: "0.1.0")
],
targets: [
    .target(name: "YourTarget", dependencies: ["Zstd"])
]
```

When cloning locally, include the submodule:

```bash
git clone --recurse-submodules git@github.com:Apurer/swift-zstd.git
# or if already cloned
git submodule update --init --recursive
```

## Quick start
- **One-shot**
  ```swift
  let compressed = try Zstd.compress(Data("payload".utf8))
  let restored = try Zstd.decompress(compressed)
  ```
- **Streaming contexts** (reuse to avoid rebuilding C contexts)
  ```swift
  let compressor = try Zstd.Compressor(options: .init(level: 5, threads: 2, checksum: true))
  var output = Data(), scratch = Data()
  for chunk in someChunks {
      scratch.removeAll(keepingCapacity: true)
      try compressor.compress(chunk, into: &scratch)
      output.append(scratch)
  }
  try compressor.finish(into: &scratch)
  output.append(scratch)
  ```
- **AsyncSequence streaming**
  ```swift
  let compressedStream = Zstd.compress(chunks: sourceChunks)
  for try await chunk in compressedStream { /* write chunk */ }

  let decompressed = Zstd.decompress(chunks: incoming,
                                     options: .init(maxDecompressedSize: 5_000_000))
  for try await chunk in decompressed { /* consume */ }
  ```
- **Dictionaries**
  ```swift
  let dictBytes = try Zstd.trainDictionary(from: samples, capacity: 4_096)
  let dictionary = try Zstd.Dictionary(data: dictBytes)
  let compressed = try Zstd.compress(payload, options: .init(dictionary: dictionary,
                                                             includeDictionaryID: false))
  ```

## Safety limits and FAQ
- Default decompression cap is 16 MB; raise or clear it for trusted inputs via `maxDecompressedSize`.
- `maxOutputSize` and `maxWindowLog` protect against oversized frames and sliding windows; exceeding limits throws `.outputLimitExceeded`.
- Streaming contexts throw `.streamFinished` after `finish()`; call `reset` to reuse.
- Dictionary safety: when a dictionary is present and `includeDictionaryID` is unset, the encoder includes the ID so decoders can reject mismatches. Set `includeDictionaryID: false` only if the reader guarantees the correct dictionary.
- Compatibility: frames produced here round-trip with the `zstd` CLI and other bindings using the same zstd major/minor version.

## Documentation
- Swift-DocC is enabled. Generate local docs with `swift package generate-documentation` (requires the DocC plugin).
- Planned published docs: https://apurer.github.io/swift-zstd/documentation/swift_zstd
- Narrative guides live under `Sources/Zstd/Documentation.docc` (getting started, streaming vs one-shot, safety limits, dictionary usage).

## Benchmarks and compatibility
- Run the informal benchmarks: `swift run Benchmarks` (checks one-shot, streaming, and dictionary compression with basic ratios).
- Supported toolchains/platforms: Swift 6.2+ on macOS 13+, iOS/tvOS 15+, watchOS 9+, Linux.
- Frames round-trip with the `zstd` CLI so long as the bundled zstd version is compatible; releases document the pinned version.

## Releases and stability
- Semantic Versioning starting at the first tagged release; see `CHANGELOG.md` for notes and upgrade guidance.
- Each release should include short notes and tag the vendored zstd version used.
- CI covers macOS and Linux with Swift 6.2; badges above surface current status.

## Submodule policy
- Zstandard is vendored as `Sources/CZstd/zstd` pinned to `v1.5.7` (`f8745da6`).
- Sync submodules before building: `git submodule update --init --recursive` or `./Scripts/sync-submodules.sh`.
- When updating zstd, prefer tagged releases, document the new version in `CHANGELOG.md`, and re-run tests on macOS and Linux.

## Development
- Run the test suite: `swift test --parallel`.
- Lint formatting: `swift format lint --recursive --configuration swift-format.json Sources Tests Benchmarks`.
- Fix formatting: `swift format --in-place --recursive --configuration swift-format.json Sources Tests Benchmarks`.
- Benchmarks: `swift run Benchmarks` (see above).
- Contributing guide: [`CONTRIBUTING.md`](CONTRIBUTING.md); Code of Conduct: [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md); Security: [`SECURITY.md`](SECURITY.md).
- License: BSD 3-Clause (see `LICENSE`).

## Practical checklist
- Metadata: set repository description, topics, and homepage.
- Badges: CI, release tag, docs.
- Docs: DocC enabled; publish docs (GitHub Pages) after tagging.
- Process: `CHANGELOG.md` maintained; releases tagged with SemVer; release notes mention pinned zstd version.
- Community: contributing guide, code of conduct, security policy, issue templates, PR template.
- Engineering: CI matrix (macOS + Linux), formatting enforced, benchmarks available, submodule policy documented.
