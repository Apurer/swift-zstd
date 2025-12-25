import Foundation
import Testing
@testable import Zstd

@Test func roundTripSmallPayload() throws {
    let input = Data("Swift zstd wrapper".utf8)
    let compressed = try Zstd.compress(input)
    #expect(!compressed.isEmpty)

    let decompressed = try Zstd.decompress(compressed)
    #expect(decompressed == input)
}

@Test func emptyFrameRoundTrip() throws {
    let compressed = try Zstd.compress(Data())
    #expect(!compressed.isEmpty)

    let decompressed = try Zstd.decompress(compressed)
    #expect(decompressed.isEmpty)
}

@Test func rejectsInvalidFrames() {
    #expect(throws: Zstd.ZstdError.self) {
        _ = try Zstd.decompress(Data([0x00, 0x01, 0x02, 0x03]))
    }
}

@Test func rejectsEmptyPayload() {
    #expect(throws: Zstd.ZstdError.invalidFrame) {
        _ = try Zstd.decompress(Data())
    }
}

@Test func enforcesCompressionLimit() {
    let payload = Data(repeating: 0xCD, count: 2_048)

    #expect(throws: Zstd.ZstdError.outputLimitExceeded) {
        _ = try Zstd.compress(payload, options: .init(maxOutputSize: 32))
    }
}

@Test func enforcesDecompressLimit() throws {
    let payload = Data(repeating: 0xAB, count: 1_024)
    let compressed = try Zstd.compress(payload)

    #expect(throws: Zstd.ZstdError.outputLimitExceeded) {
        _ = try Zstd.decompress(compressed, options: .init(maxDecompressedSize: 512))
    }
}

@Test func multithreadedCompressionEnabled() throws {
    let payload = Data(repeating: 0x55, count: 1 << 20)
    let compressed = try Zstd.compress(payload, options: .init(threads: 2))
    let decompressed = try Zstd.decompress(compressed)

    #expect(decompressed == payload)
}

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
