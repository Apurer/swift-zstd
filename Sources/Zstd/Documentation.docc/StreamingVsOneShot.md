# Streaming vs One-Shot

Choose the right API based on payload size, memory constraints, and whether you know the total size up front.

## One-shot
- Use `Zstd.compress(_:)` and `Zstd.decompress(_:)`.
- Best for small/medium inputs or when you know the full payload size.
- Allocates buffers sized by `ZSTD_compressBound` or the advertised frame size (capped to avoid huge single allocations).

## Streaming
- Use `Zstd.Compressor` and `Zstd.Decompressor` for incremental processing.
- Reuse the same compressor to amortize context setup costs.
- `finish()` closes the frame; after finishing, reuse by calling `reset(options:)`.
- `flush()` lets you checkpoint compressed output without finishing the stream.

### File handles
- `compressStream(from:to:options:)` and `decompressStream(from:to:options:)` allow direct streaming between `FileHandle`s.
- Use the `writingTo:` variants to consume scratch buffers without intermediate `Data` allocations.

### Async sequences
- `compress(chunks:)` and `decompress(chunks:)` work with `AsyncSequence<Data>`.
- Use for server streaming or pipelines where chunks arrive over time.

## Performance notes
- Multi-threaded compression is available by setting `threads` > 0; tune `jobSize` for large payloads.
- For small inputs, single-threaded compression is typically faster due to reduced overhead.
- Dictionary compression reduces size for many similar payloads; see <doc:DictionaryUsage>.
