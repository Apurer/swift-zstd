# swift-zstd

Swift package that embeds the Zstandard C library and exposes small, allocation-aware APIs for compressing and decompressing data, streams, and async sequences.

## Usage
- **One-shot**  
  ```swift
  let compressed = try Zstd.compress(Data("payload".utf8))
  let restored = try Zstd.decompress(compressed)
  ```
- **Streaming contexts** (reuse to avoid rebuilding C contexts):  
  ```swift
  let compressor = try Zstd.Compressor(options: .init(level: 5, threads: 2, checksum: true))
  var output = Data()
  for chunk in someChunks { output.append(try compressor.compress(chunk)) }
  output.append(try compressor.finish())

  let decompressor = try Zstd.Decompressor(options: .init(maxDecompressedSize: 1 << 24))
  for chunk in outputChunks {
      let (partial, finished) = try decompressor.decompress(chunk)
      // consume partial; stop when finished is true
  }
  ```
- **FileHandle streaming**  
  ```swift
  try Zstd.compressStream(from: inputHandle, to: compressedHandle, options: .init(windowLog: 20))
  try Zstd.decompressStream(from: compressedHandle, to: outputHandle, options: .init(maxDecompressedSize: 50_000_000))
  ```
- **AsyncSequence streaming**  
  ```swift
  let compressedStream = Zstd.compress(chunks: sourceChunks)
  for try await chunk in compressedStream { /* write chunk */ }

  let decompressedStream = Zstd.decompress(chunks: incomingChunks,
                                           options: .init(maxDecompressedSize: 5_000_000))
  for try await chunk in decompressedStream { /* consume */ }
  ```
- **Dictionaries**  
  ```swift
  let dictBytes = try Zstd.trainDictionary(from: samples, capacity: 4096)
  let dictionary = try Zstd.Dictionary(data: dictBytes)
  let compressed = try Zstd.compress(payload, options: .init(dictionary: dictionary,
                                                             includeDictionaryID: false))
  ```

## Tuning & safety
- Options expose checksum, window log, worker threads, and `includeDictionaryID` (ZSTD_c_dictIDFlag).
- `maxOutputSize` (compression) and `maxDecompressedSize` (decompression) guard untrusted or enormous inputs; overshoots throw `outputLimitExceeded`.
- Allocations are bounded using `ZSTD_compressBound`/`ZSTD_*StreamOutSize` with explicit `Int.max` checks before buffers are created.
- Empty frames round-trip correctly; invalid or truncated frames throw `invalidFrame`.
- Prefer streaming APIs for large payloads to reuse contexts and avoid building whole messages in memory.

## CI
GitHub Actions runs `swift test` on macOS and Linux to keep the bundled C target building.

## License
The bundled Zstandard sources are licensed under the BSD 3-Clause license (see `LICENSE`).
