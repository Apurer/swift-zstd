# Dictionary Usage

Zstandard dictionaries improve compression ratios for many similar payloads. The library includes helpers for training, loading, and using dictionaries safely.

## Train a dictionary
```swift
let samples: [Data] = ... // representative payloads
let dictBytes = try Zstd.trainDictionary(from: samples, capacity: 4_096)
let dictionary = try Zstd.Dictionary(data: dictBytes)
```

## Compress with a dictionary
```swift
let compressed = try Zstd.compress(payload, options: .init(dictionary: dictionary))
```

## Decompress with a dictionary
```swift
let restored = try Zstd.decompress(
    compressed,
    options: .init(dictionary: dictionary, maxDecompressedSize: payload.count * 2)
)
```

## Safety defaults
- When `includeDictionaryID` is not set, the encoder emits the dictionary ID so decoders can reject mismatches.
- To omit the ID (e.g., for deterministic frames when both sides are tightly coupled), set `includeDictionaryID: false` and ensure the exact dictionary is provided by the consumer.

## Persisting dictionaries
- Save trained bytes to disk with `Data.write(to:)` and reload using `Zstd.Dictionary(contentsOf:)`.
- Pin the dictionary version used in releases to avoid accidental regressions.
