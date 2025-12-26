# Safety Limits

APIs include guard rails for untrusted or unexpectedly large inputs. Tune these values deliberately when relaxing them.

## Decompression caps
- `Zstd.DecompressionOptions.maxDecompressedSize` defaults to 16 MB.
- If the frame advertises a larger size or the streaming output exceeds the cap, `.outputLimitExceeded` is thrown.
- Set `maxDecompressedSize` to `nil` or a larger number when the payload is trusted and size is known.

## Window log guard
- `maxWindowLog` limits the sliding window size accepted during streaming decompression.
- Use a smaller window when handling untrusted streams to limit memory usage; overshoots throw `.outputLimitExceeded`.

## Compression output limits
- `CompressionOptions.maxOutputSize` caps emitted bytes for compressors and streaming compressors.
- Useful for bounded buffers or to fail fast on pathological inputs.

## Dictionary handling
- When a dictionary is supplied and `includeDictionaryID` is `nil`, the encoder includes the dictionary ID so decoders can reject mismatches by default.
- Set `includeDictionaryID: false` only when both sides are pinned to the same dictionary out-of-band.

## Finished streams
- After `finish()` completes, `compress` and `flush` throw `.streamFinished` until you call `reset`.
- The same rule applies to `Decompressor` after reaching the end of a frame.

## Platform constraints
- Very large known-size frames fall back to streaming to avoid a single giant allocation.
- Supported platforms: macOS 13+, iOS/tvOS 15+, watchOS 9+, Linux; architectures supported by the Swift toolchain and bundled zstd.
