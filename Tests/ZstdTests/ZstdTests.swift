import Foundation
import Testing
@testable import Zstd

@MainActor
@Test func roundTripSmallPayload() throws {
    let input = Data("Swift zstd wrapper".utf8)
    let compressed = try Zstd.compress(input)
    #expect(!compressed.isEmpty)

    let decompressed = try Zstd.decompress(compressed)
    #expect(decompressed == input)
}

@MainActor
@Test func emptyFrameRoundTrip() throws {
    let compressed = try Zstd.compress(Data())
    #expect(!compressed.isEmpty)

    let decompressed = try Zstd.decompress(compressed)
    #expect(decompressed.isEmpty)
}

@MainActor
@Test func rejectsInvalidFrames() {
    #expect(throws: Zstd.ZstdError.self) {
        _ = try Zstd.decompress(Data([0x00, 0x01, 0x02, 0x03]))
    }
}

@MainActor
@Test func rejectsEmptyPayload() {
    #expect(throws: Zstd.ZstdError.invalidFrame) {
        _ = try Zstd.decompress(Data())
    }
}

@MainActor
@Test func enforcesCompressionLimit() {
    let payload = Data(repeating: 0xCD, count: 2_048)

    #expect(throws: Zstd.ZstdError.outputLimitExceeded) {
        _ = try Zstd.compress(payload, options: .init(maxOutputSize: 32))
    }
}

@MainActor
@Test func enforcesDecompressLimit() throws {
    let payload = Data(repeating: 0xAB, count: 1_024)
    let compressed = try Zstd.compress(payload)

    #expect(throws: Zstd.ZstdError.outputLimitExceeded) {
        _ = try Zstd.decompress(compressed, options: .init(maxDecompressedSize: 512))
    }
}

@MainActor
@Test func multithreadedCompressionEnabled() throws {
    let payload = Data(repeating: 0x55, count: 1 << 20)
    let compressed = try Zstd.compress(payload, options: .init(threads: 2))
    let decompressed = try Zstd.decompress(compressed)

    #expect(decompressed == payload)
}

@MainActor
@Test func multithreadedStreamingCompressionRoundTrip() throws {
    let payload = Data(repeating: 0x37, count: 2 << 20)
    let compressor = try Zstd.Compressor(options: .init(threads: 2))
    var compressed = Data()
    var scratch = Data()
    scratch.reserveCapacity(64 * 1024)

    for chunk in chunkData(payload, size: 64_000) {
        scratch.removeAll(keepingCapacity: true)
        try compressor.compress(chunk, into: &scratch)
        compressed.append(scratch)
    }

    scratch.removeAll(keepingCapacity: true)
    try compressor.finish(into: &scratch)
    compressed.append(scratch)

    let decompressor = try Zstd.Decompressor(options: .init(maxDecompressedSize: payload.count * 2))
    var decompressed = Data()
    decompressed.reserveCapacity(payload.count)

    for chunk in chunkData(compressed, size: 48_000) {
        let finished = try decompressor.decompress(chunk, into: &decompressed)
        if finished {
            break
        }
    }

    #expect(decompressed == payload)
    #expect(decompressor.isFinished)
}

@MainActor
@Test func defaultDecompressLimitAppliesToKnownSizeFrames() throws {
    let targetSize = Zstd.defaultMaxDecompressedSize + 4 * 1024
    let payload = Data(repeating: 0xEF, count: targetSize)
    let compressed = try Zstd.compress(payload)

    #expect(throws: Zstd.ZstdError.outputLimitExceeded) {
        _ = try Zstd.decompress(compressed)
    }

    let decompressed = try Zstd.decompress(compressed, options: .init(maxDecompressedSize: targetSize))
    #expect(decompressed == payload)
}

@MainActor
@Test func defaultDecompressLimitAppliesToStreamingFrames() async throws {
    let targetSize = Zstd.defaultMaxDecompressedSize + 8 * 1024
    let payload = Data(repeating: 0x42, count: targetSize)

    let compressor = try Zstd.Compressor()
    var compressed = Data()
    for chunk in chunkData(payload, size: 32_768) {
        compressed.append(try compressor.compress(chunk))
    }
    compressed.append(try compressor.finish())

    let stream = Zstd.decompress(chunks: asyncChunks(compressed, size: 8_192))

    var hitLimit = false
    do {
        for try await _ in stream {}
    } catch let error as Zstd.ZstdError {
        if case .outputLimitExceeded = error {
            hitLimit = true
        }
    } catch {}

    #expect(hitLimit)
}

@MainActor
@Test func enforcesMaxWindowLog() throws {
    let payload = Data(repeating: 0x33, count: 32_768)
    let compressed = try Zstd.compress(payload, options: .init(windowLog: 22))

    var hitWindowGuard = false
    do {
        _ = try Zstd.decompress(
            compressed,
            options: .init(maxDecompressedSize: payload.count * 2, maxWindowLog: 9)
        )
    } catch let error as Zstd.ZstdError {
        if case .outputLimitExceeded = error {
            hitWindowGuard = true
        }
    } catch {
        hitWindowGuard = true
    }
    #expect(hitWindowGuard)

    let decompressed = try Zstd.decompress(
        compressed,
        options: .init(maxDecompressedSize: payload.count * 2, maxWindowLog: 30)
    )
    #expect(decompressed == payload)
}

@MainActor
@Test func streamingUnknownSizeRoundTrip() async throws {
    let payload = Data((0..<64_000).map { UInt8($0 & 0xFF) })

    let compressor = try Zstd.Compressor()
    var compressed = Data()
    for chunk in chunkData(payload, size: 2_048) {
        compressed.append(try compressor.compress(chunk))
    }
    compressed.append(try compressor.finish())

    var decompressed = Data()
    for try await chunk in Zstd.decompress(
        chunks: asyncChunks(compressed, size: 3_000),
        options: .init(maxDecompressedSize: payload.count * 2)
    ) {
        decompressed.append(chunk)
    }
    #expect(decompressed == payload)
}

@MainActor
@Test func streamingUnknownSizeLimitIsHonored() async throws {
    let payload = Data(repeating: 0xEF, count: 16_384)

    let compressor = try Zstd.Compressor()
    var compressed = Data()
    for chunk in chunkData(payload, size: 1_024) {
        compressed.append(try compressor.compress(chunk))
    }
    compressed.append(try compressor.finish())

    let stream = Zstd.decompress(
        chunks: asyncChunks(compressed, size: 256),
        options: .init(maxDecompressedSize: 2_048)
    )

    var hitLimit = false
    var unexpectedError: String?
    do {
        for try await _ in stream {}
    } catch let error as Zstd.ZstdError {
        if case .outputLimitExceeded = error {
            hitLimit = true
        } else {
            unexpectedError = "\(error)"
        }
    } catch {
        unexpectedError = "\(error)"
    }

    #expect(unexpectedError == nil)
    #expect(hitLimit)
}

@MainActor
@Test func streamingCompressorTracksOutputLimit() throws {
    let payload = noiseData(length: 1_024)
    let compressor = try Zstd.Compressor(options: .init(maxOutputSize: 64))
    var scratch = Data()

    #expect(throws: Zstd.ZstdError.outputLimitExceeded) {
        try compressor.compress(payload, into: &scratch)
        try compressor.finish(into: &scratch)
    }
}

@MainActor
@Test func streamingDecompressorTracksLimitAcrossChunks() throws {
    let payload = noiseData(length: 1_200)
    let compressed = try Zstd.compress(payload)
    let decompressor = try Zstd.Decompressor(options: .init(maxDecompressedSize: 800))
    var output = Data()
    var hitLimit = false

    do {
        for chunk in chunkData(compressed, size: 96) {
            _ = try decompressor.decompress(chunk, into: &output)
        }
    } catch let error as Zstd.ZstdError {
        if case .outputLimitExceeded = error {
            hitLimit = true
        } else {
            throw error
        }
    }

    #expect(hitLimit)
}

@MainActor
@Test func compressorResetRebindsOptions() throws {
    let payload = noiseData(length: 240)
    let referenceSize = try Zstd.compress(payload).count
    let relaxedLimit = referenceSize * 2
    let tightLimit = max(1, referenceSize / 2)

    let compressor = try Zstd.Compressor(options: .init(maxOutputSize: relaxedLimit))
    var buffer = Data()

    try compressor.compress(payload, into: &buffer)
    try compressor.finish(into: &buffer)

    try compressor.reset(options: .init(maxOutputSize: tightLimit))
    buffer.removeAll(keepingCapacity: true)
    #expect(throws: Zstd.ZstdError.outputLimitExceeded) {
        try compressor.compress(payload, into: &buffer)
        try compressor.finish(into: &buffer)
    }

    try compressor.reset(options: .init(maxOutputSize: relaxedLimit))
    buffer.removeAll(keepingCapacity: true)
    try compressor.compress(payload, into: &buffer)
    try compressor.finish(into: &buffer)
    #expect(!buffer.isEmpty)
}

@MainActor
@Test func decompressorResetRestoresLimits() throws {
    let payload = noiseData(length: 720)
    let compressed = try Zstd.compress(payload)
    let decompressor = try Zstd.Decompressor(options: .init(maxDecompressedSize: 1_000))

    var output = Data()
    for chunk in chunkData(compressed, size: 150) {
        let finished = try decompressor.decompress(chunk, into: &output)
        if finished {
            break
        }
    }
    #expect(output == payload)

    try decompressor.reset(options: .init(maxDecompressedSize: 400))
    output.removeAll(keepingCapacity: true)
    #expect(throws: Zstd.ZstdError.outputLimitExceeded) {
        for chunk in chunkData(compressed, size: 150) {
            _ = try decompressor.decompress(chunk, into: &output)
        }
    }

    try decompressor.reset(options: .init(maxDecompressedSize: 1_000))
    output.removeAll(keepingCapacity: true)
    for chunk in chunkData(compressed, size: 150) {
        let finished = try decompressor.decompress(chunk, into: &output)
        if finished {
            break
        }
    }
    #expect(output == payload)
}

@MainActor
@Test func incrementalDecompressorHandlesChunks() throws {
    let payload = Data((0..<20_000).map { UInt8($0 & 0x7F) })
    let compressed = try Zstd.compress(payload)

    let decompressor = try Zstd.Decompressor()
    var output = Data()

    for chunk in chunkData(compressed, size: 512) {
        let (partial, finished) = try decompressor.decompress(chunk)
        output.append(partial)
        if finished {
            break
        }
    }

    #expect(output == payload)
}

@MainActor
@Test func dictionaryRoundTrip() throws {
    let training = (0..<20).map { index in
        Data("sample-\(index)-\(String(repeating: "x", count: index % 7))".utf8)
    }

    let dictionaryBytes = try Zstd.trainDictionary(from: training, capacity: 2_048)
    let dictionary = try Zstd.Dictionary(data: dictionaryBytes)

    let payload = Data("payload that benefits from a dictionary payload that benefits from a dictionary".utf8)
    let compressed = try Zstd.compress(payload, options: .init(dictionary: dictionary))
    let decompressed = try Zstd.decompress(compressed, options: .init(dictionary: dictionary))

    #expect(decompressed == payload)
}

@MainActor
@Test func dictionaryRoundTripFromDisk() throws {
    let training = (0..<12).map { index in
        Data("training-\(index)-\(String(repeating: "a", count: index % 5))".utf8)
    }

    let dictionaryBytes = try Zstd.trainDictionary(from: training, capacity: 1_024)
    let dictionaryURL = uniqueTempURL(".dict")
    defer { try? FileManager.default.removeItem(at: dictionaryURL) }
    try dictionaryBytes.write(to: dictionaryURL)

    let dictionary = try Zstd.Dictionary(contentsOf: dictionaryURL)

    let payload = Data(repeating: 0xAC, count: 5_000)
    let compressor = try Zstd.Compressor(options: .init(includeDictionaryID: false, dictionary: dictionary))

    var compressed = Data()
    for chunk in chunkData(payload, size: 257) {
        compressed.append(try compressor.compress(chunk))
    }
    compressed.append(try compressor.finish())

    let decompressed = try Zstd.decompress(compressed, options: .init(dictionary: dictionary))
    #expect(decompressed == payload)
}

@MainActor
@Test func rejectsWrongDictionaryWhenDictionaryIDIncluded() throws {
    let primaryTraining = (0..<16).map { index in
        Data("primary-\(index)-\(String(repeating: "x", count: index % 3))".utf8)
    }
    let secondaryTraining = (0..<16).map { index in
        Data("secondary-\(index)-\(String(repeating: "y", count: index % 4))".utf8)
    }

    let primaryDictionary = try Zstd.Dictionary(
        data: Zstd.trainDictionary(from: primaryTraining, capacity: 2_048)
    )
    let secondaryDictionary = try Zstd.Dictionary(
        data: Zstd.trainDictionary(from: secondaryTraining, capacity: 2_048)
    )

    let payload = Data(repeating: 0x5A, count: 6_144)
    let compressed = try Zstd.compress(
        payload,
        options: .init(includeDictionaryID: true, dictionary: primaryDictionary)
    )

    var rejectedWrongDictionary = false
    do {
        _ = try Zstd.decompress(
            compressed,
            options: .init(dictionary: secondaryDictionary, maxDecompressedSize: payload.count * 2)
        )
    } catch let error as Zstd.ZstdError {
        if case .library = error {
            rejectedWrongDictionary = true
        }
    } catch {}
    #expect(rejectedWrongDictionary)

    let decompressed = try Zstd.decompress(
        compressed,
        options: .init(dictionary: primaryDictionary, maxDecompressedSize: payload.count * 2)
    )
    #expect(decompressed == payload)
}

@MainActor
@Test func fileHandleStreamingRoundTrip() throws {
    let payload = Data((0..<25_000).map { UInt8($0 % 199) })
    let inputURL = uniqueTempURL(".input")
    let compressedURL = uniqueTempURL(".zst")
    let outputURL = uniqueTempURL(".out")
    let manager = FileManager.default

    defer {
        try? manager.removeItem(at: inputURL)
        try? manager.removeItem(at: compressedURL)
        try? manager.removeItem(at: outputURL)
    }

    try payload.write(to: inputURL)
    manager.createFile(atPath: compressedURL.path, contents: nil)
    manager.createFile(atPath: outputURL.path, contents: nil)

    do {
        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        let compressedHandle = try FileHandle(forWritingTo: compressedURL)
        defer {
            try? inputHandle.close()
            try? compressedHandle.close()
        }

        try Zstd.compressStream(
            from: inputHandle,
            to: compressedHandle,
            options: .init(checksum: true, windowLog: 20),
            chunkSize: 1_024
        )
    }

    do {
        let compressedReader = try FileHandle(forReadingFrom: compressedURL)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? compressedReader.close()
            try? outputHandle.close()
        }

        try Zstd.decompressStream(
            from: compressedReader,
            to: outputHandle,
            options: .init(maxDecompressedSize: payload.count * 2),
            chunkSize: 900
        )
    }

    let roundTripped = try Data(contentsOf: outputURL)
    #expect(roundTripped == payload)
}

@MainActor
@Test func streamingDecompressionRejectsTruncatedFrame() throws {
    let payload = Data(repeating: 0xA5, count: 12_000)
    let compressed = try Zstd.compress(payload)
    let truncated = Data(compressed.dropLast(max(1, compressed.count / 5)))

    let compressedURL = uniqueTempURL(".truncated")
    let outputURL = uniqueTempURL(".out")
    let manager = FileManager.default

    defer {
        try? manager.removeItem(at: compressedURL)
        try? manager.removeItem(at: outputURL)
    }

    manager.createFile(atPath: compressedURL.path, contents: truncated)
    manager.createFile(atPath: outputURL.path, contents: nil)

    #expect(throws: Zstd.ZstdError.invalidFrame) {
        let inputHandle = try FileHandle(forReadingFrom: compressedURL)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
        }

        try Zstd.decompressStream(
            from: inputHandle,
            to: outputHandle,
            options: .init(maxDecompressedSize: payload.count * 2),
            chunkSize: 512
        )
    }
}

@MainActor
@Test func asyncStreamingRejectsTruncatedFrame() async throws {
    let payload = Data(repeating: 0xB6, count: 18_000)
    let compressed = try Zstd.compress(payload)
    let truncated = Data(compressed.dropLast(max(1, compressed.count / 6)))

    let stream = Zstd.decompress(
        chunks: asyncChunks(truncated, size: 500),
        options: .init(maxDecompressedSize: payload.count * 2)
    )

    var hitInvalidFrame = false
    do {
        for try await _ in stream {}
    } catch let error as Zstd.ZstdError {
        if case .invalidFrame = error {
            hitInvalidFrame = true
        }
    } catch {}

    #expect(hitInvalidFrame)
}

@MainActor
@Test func handlesConcatenatedFramesInStreaming() async throws {
    let first = Data(repeating: 0x11, count: 10_000)
    let second = Data(repeating: 0x22, count: 8_000)

    var concatenated = Data()
    concatenated.append(try Zstd.compress(first))
    concatenated.append(try Zstd.compress(second))

    var decompressed = Data()
    for try await chunk in Zstd.decompress(
        chunks: asyncChunks(concatenated, size: 1_024),
        options: .init(maxDecompressedSize: first.count + second.count + 1_024)
    ) {
        decompressed.append(chunk)
    }

    var expected = Data()
    expected.append(first)
    expected.append(second)

    #expect(decompressed == expected)
}

@MainActor
@Test func cancelsAsyncCompressionStreamWhenConsumerStops() async throws {
    let tracker = StreamTracker()
    var producerHandle: Task<Void, Never>?

    var compressedStream: AsyncThrowingStream<Data, Error>? = Zstd.compress(
        chunks: AsyncStream { continuation in
            let handle = Task {
                for _ in 0..<10 {
                    if Task.isCancelled { break }
                    await tracker.incrementProduced()
                    continuation.yield(Data(repeating: 0xCC, count: 2_048))
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                continuation.finish()
            }
            producerHandle = handle

            continuation.onTermination = { @Sendable _ in
                Task { await tracker.markCancelled() }
            }
        }
    )

    if var iterator = compressedStream?.makeAsyncIterator() {
        _ = try await iterator.next()
    }
    producerHandle?.cancel()
    compressedStream = nil
    try await Task.sleep(nanoseconds: 10_000_000)

    let snapshot = await tracker.snapshot()
    #expect(snapshot.cancelled)
    #expect(snapshot.produced >= 1 && snapshot.produced <= 10)
}

private actor StreamTracker {
    private var produced = 0
    private var cancelled = false

    func incrementProduced() {
        produced += 1
    }

    func markCancelled() {
        cancelled = true
    }

    func snapshot() -> (produced: Int, cancelled: Bool) {
        (produced, cancelled)
    }
}

private func noiseData(length: Int) -> Data {
    guard length > 0 else { return Data() }
    var state: UInt64 = 0x1234_5678_9ABC_DEF0
    var bytes: [UInt8] = []
    bytes.reserveCapacity(length)

    for _ in 0..<length {
        state = state &* 2862933555777941757 &+ 3037000493
        bytes.append(UInt8(truncatingIfNeeded: state >> 24))
    }

    return Data(bytes)
}

private func chunkData(_ data: Data, size: Int) -> [Data] {
    guard size > 0 else { return [] }
    var chunks: [Data] = []
    var offset = 0

    while offset < data.count {
        let end = min(offset + size, data.count)
        chunks.append(data.subdata(in: offset..<end))
        offset = end
    }

    return chunks
}

private func asyncChunks(_ data: Data, size: Int) -> AsyncStream<Data> {
    AsyncStream { continuation in
        let chunks = chunkData(data, size: size)
        Task {
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

private func uniqueTempURL(_ suffix: String = "") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + suffix)
}
