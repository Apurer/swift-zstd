import Foundation
import CZstd

public enum Zstd {
    public static let defaultCompressionLevel: Int32 = Int32(ZSTD_CLEVEL_DEFAULT)
    public static let defaultMaxDecompressedSize: Int = 16 * 1024 * 1024

    public struct CompressionOptions: Sendable {
        public var level: Int32
        public var checksum: Bool
        public var includeDictionaryID: Bool?
        public var threads: Int?
        public var windowLog: Int?
        public var dictionary: Dictionary?
        public var maxOutputSize: Int?

        public init(
            level: Int32 = Zstd.defaultCompressionLevel,
            checksum: Bool = false,
            includeDictionaryID: Bool? = nil,
            threads: Int? = nil,
            windowLog: Int? = nil,
            dictionary: Dictionary? = nil,
            maxOutputSize: Int? = nil
        ) {
            self.level = level
            self.checksum = checksum
            self.includeDictionaryID = includeDictionaryID
            self.threads = threads
            self.windowLog = windowLog
            self.dictionary = dictionary
            self.maxOutputSize = maxOutputSize
        }
    }

    public struct DecompressionOptions: Sendable {
        public var dictionary: Dictionary?
        public var maxDecompressedSize: Int?
        public var maxWindowLog: Int?

        public init(
            dictionary: Dictionary? = nil,
            maxDecompressedSize: Int? = Zstd.defaultMaxDecompressedSize,
            maxWindowLog: Int? = nil
        ) {
            self.dictionary = dictionary
            self.maxDecompressedSize = maxDecompressedSize
            self.maxWindowLog = maxWindowLog
        }
    }

    public enum ZstdError: Error, CustomStringConvertible {
        case library(code: Int, message: String)
        case invalidFrame
        case outputLimitExceeded
        case frameTooLarge

        public var description: String {
            switch self {
            case let .library(code, message):
                return "zstd error \(code): \(message)"
            case .invalidFrame:
                return "invalid or truncated zstd frame"
            case .outputLimitExceeded:
                return "decompressed data exceeds allowed limit"
            case .frameTooLarge:
                return "frame size is too large for this platform"
            }
        }
    }

    public final class Dictionary {
        fileprivate let compress: OpaquePointer
        fileprivate let decompress: OpaquePointer

        public init(data: Data, level: Int32 = Zstd.defaultCompressionLevel) throws {
            let compressHandle = data.withUnsafeBytes { buffer in
                ZSTD_createCDict(buffer.baseAddress, data.count, level)
            }

            let decompressHandle = data.withUnsafeBytes { buffer in
                ZSTD_createDDict(buffer.baseAddress, data.count)
            }

            guard let compressHandle, let decompressHandle else {
                throw ZstdError.library(code: -1, message: "Unable to create zstd dictionary")
            }

            self.compress = compressHandle
            self.decompress = decompressHandle
        }

        public convenience init(contentsOf url: URL, level: Int32 = Zstd.defaultCompressionLevel) throws {
            let data = try Data(contentsOf: url)
            try self.init(data: data, level: level)
        }

        deinit {
            ZSTD_freeCDict(compress)
            ZSTD_freeDDict(decompress)
        }
    }

    public final class Compressor {
        private let context: OpaquePointer
        private var scratch: [UInt8]
        private var finished = false
        private var maxOutputSize: Int?
        private var produced = 0
        private var options: CompressionOptions

        public init(options: CompressionOptions = CompressionOptions()) throws {
            guard let context = ZSTD_createCCtx() else {
                throw ZstdError.library(code: -1, message: "Unable to create compression context")
            }

            self.context = context
            self.maxOutputSize = options.maxOutputSize
            self.options = options
            if let limit = maxOutputSize, limit <= 0 {
                ZSTD_freeCCtx(context)
                throw ZstdError.outputLimitExceeded
            }
            self.scratch = Array(
                repeating: 0,
                count: try Zstd.checkedChunkSize(Int(ZSTD_CStreamOutSize()))
            )

            do {
                try Zstd.applyCompressionOptions(options, to: context)
            } catch {
                ZSTD_freeCCtx(context)
                throw error
            }
        }

        public var isFinished: Bool { finished }

        deinit {
            ZSTD_freeCCtx(context)
        }

        public func reset(options: CompressionOptions? = nil) throws {
            let nextOptions = options ?? self.options
            _ = try Zstd.validate(code: Int(ZSTD_CCtx_reset(context, ZSTD_reset_session_and_parameters)))
            try Zstd.applyCompressionOptions(nextOptions, to: context)
            self.options = nextOptions
            self.maxOutputSize = nextOptions.maxOutputSize
            if let limit = maxOutputSize, limit <= 0 {
                throw ZstdError.outputLimitExceeded
            }
            self.finished = false
            self.produced = 0
        }

        public func compress(_ data: Data) throws -> Data {
            guard !finished else { return Data() }

            var output = Data()
            reserveCompressedCapacity(for: data.count, into: &output)
            try compress(data, into: &output)
            return output
        }

        public func compress(_ data: Data, into output: inout Data) throws {
            guard !finished else { return }

            reserveCompressedCapacity(for: data.count, into: &output)
            try data.withUnsafeBytes { srcBuffer in
                var input = ZSTD_inBuffer(src: srcBuffer.baseAddress, size: srcBuffer.count, pos: 0)
                try scratch.withUnsafeMutableBytes { scratchBuffer in
                    guard let scratchBase = scratchBuffer.baseAddress else { return }

                    while input.pos < input.size {
                        var out = ZSTD_outBuffer(dst: scratchBase, size: scratchBuffer.count, pos: 0)
                        let code = ZSTD_compressStream2(context, &out, &input, ZSTD_e_continue)
                        _ = try Zstd.validate(code: Int(code))

                        if out.pos > 0 {
                            if let limit = maxOutputSize {
                                let remaining = limit - produced
                                if remaining <= 0 || out.pos > remaining {
                                    throw ZstdError.outputLimitExceeded
                                }
                            }
                            produced += out.pos
                            output.append(contentsOf: UnsafeRawBufferPointer(start: scratchBase, count: out.pos))
                        }
                    }
                }
            }

        }

        public func finish() throws -> Data {
            guard !finished else { return Data() }

            var output = Data()
            Zstd.reserveCapacity(for: &output, additional: scratch.count)
            try finish(into: &output)
            return output
        }

        public func finish(into output: inout Data) throws {
            guard !finished else { return }

            Zstd.reserveCapacity(for: &output, additional: scratch.count)
            var input = ZSTD_inBuffer(src: nil, size: 0, pos: 0)

            try scratch.withUnsafeMutableBytes { scratchBuffer in
                guard let scratchBase = scratchBuffer.baseAddress else { return }

                while true {
                    var out = ZSTD_outBuffer(dst: scratchBase, size: scratchBuffer.count, pos: 0)
                    let code = ZSTD_compressStream2(context, &out, &input, ZSTD_e_end)
                    _ = try Zstd.validate(code: Int(code))

                    if out.pos > 0 {
                        if let limit = maxOutputSize {
                            let remaining = limit - produced
                            if remaining <= 0 || out.pos > remaining {
                                throw ZstdError.outputLimitExceeded
                            }
                        }
                        produced += out.pos
                        output.append(contentsOf: UnsafeRawBufferPointer(start: scratchBase, count: out.pos))
                    }

                    if code == 0 {
                        finished = true
                        break
                    }
                }
            }
        }

        private func reserveCompressedCapacity(for inputSize: Int, into output: inout Data) {
            let paddedInput = min(inputSize, Int.max - scratch.count)
            let estimatedBound = max(1, Int(ZSTD_compressBound(inputSize)))
            let heuristic = max(scratch.count, min(estimatedBound, paddedInput + scratch.count))
            let remaining = maxOutputSize.map { max(0, $0 - produced) }
            Zstd.reserveCapacity(for: &output, additional: min(heuristic, remaining ?? heuristic))
        }
    }

    public final class Decompressor {
        private let context: OpaquePointer
        private var scratch: [UInt8]
        private var finished = false
        private var limit: Int?
        private var produced = 0
        private var options: DecompressionOptions

        public init(options: DecompressionOptions = DecompressionOptions()) throws {
            guard let context = ZSTD_createDCtx() else {
                throw ZstdError.library(code: -1, message: "Unable to create decompression context")
            }

            self.context = context
            self.limit = options.maxDecompressedSize
            self.options = options
            if let limit = limit, limit <= 0 {
                ZSTD_freeDCtx(context)
                throw ZstdError.outputLimitExceeded
            }
            self.scratch = Array(
                repeating: 0,
                count: try Zstd.checkedChunkSize(Int(ZSTD_DStreamOutSize()))
            )

            do {
                try Zstd.applyDecompressionOptions(options, to: context)
            } catch {
                ZSTD_freeDCtx(context)
                throw error
            }
        }

        public var isFinished: Bool { finished }

        deinit {
            ZSTD_freeDCtx(context)
        }

        public func reset(options: DecompressionOptions? = nil) throws {
            let nextOptions = options ?? self.options
            _ = try Zstd.validate(code: Int(ZSTD_DCtx_reset(context, ZSTD_reset_session_and_parameters)))
            try Zstd.applyDecompressionOptions(nextOptions, to: context)
            self.limit = nextOptions.maxDecompressedSize
            self.options = nextOptions
            if let limit = limit, limit <= 0 {
                throw ZstdError.outputLimitExceeded
            }
            self.finished = false
            self.produced = 0
        }

        public func decompress(_ data: Data) throws -> (Data, finished: Bool) {
            guard !finished else { return (Data(), true) }

            var output = Data()
            reserveDecompressedCapacity(for: data.count, into: &output)
            let isFinished = try decompress(data, into: &output)
            return (output, isFinished)
        }

        public func decompress(_ data: Data, into output: inout Data) throws -> Bool {
            guard !finished else { return true }

            reserveDecompressedCapacity(for: data.count, into: &output)
            try data.withUnsafeBytes { srcBuffer in
                var input = ZSTD_inBuffer(src: srcBuffer.baseAddress, size: srcBuffer.count, pos: 0)

                try scratch.withUnsafeMutableBytes { scratchBuffer in
                    guard let scratchBase = scratchBuffer.baseAddress else { return }

                    while input.pos < input.size {
                        var out = ZSTD_outBuffer(dst: scratchBase, size: scratchBuffer.count, pos: 0)
                        let result = ZSTD_decompressStream(context, &out, &input)
                        _ = try Zstd.validate(code: Int(result))

                        if out.pos > 0 {
                            if let limit = limit {
                                let remaining = limit - produced
                                if remaining <= 0 || out.pos > remaining {
                                    throw ZstdError.outputLimitExceeded
                                }
                            }
                            produced += out.pos
                            output.append(contentsOf: UnsafeRawBufferPointer(start: scratchBase, count: out.pos))
                        }

                        if result == 0 && input.pos == input.size {
                            finished = true
                            break
                        }
                    }
                }
            }

            return finished
        }

        private func reserveDecompressedCapacity(for inputSize: Int, into output: inout Data) {
            let remaining = limit.map { max(0, $0 - produced) }
            let cappedInput = min(inputSize, Int.max / 4)
            let guess = max(scratch.count, cappedInput * 4)
            Zstd.reserveCapacity(for: &output, additional: min(remaining ?? guess, guess))
        }
    }

    public static func compress(_ data: Data, level: Int32 = defaultCompressionLevel) throws -> Data {
        try compress(data, options: CompressionOptions(level: level))
    }

    public static func compress(_ data: Data, options: CompressionOptions) throws -> Data {
        let boundSize = try checkedPositiveSize(ZSTD_compressBound(data.count))
        if let limit = options.maxOutputSize {
            if limit <= 0 {
                throw ZstdError.outputLimitExceeded
            }
            if boundSize > limit {
                throw ZstdError.outputLimitExceeded
            }
        }

        guard let context = ZSTD_createCCtx() else {
            throw ZstdError.library(code: -1, message: "Unable to create compression context")
        }
        defer { ZSTD_freeCCtx(context) }

        try applyCompressionOptions(options, to: context)

        let bufferCapacity = options.maxOutputSize.map { min(boundSize, $0) } ?? boundSize
        var compressed = Data(count: bufferCapacity)
        let written = compressed.withUnsafeMutableBytes { dstBuffer -> Int in
            data.withUnsafeBytes { srcBuffer in
                Int(ZSTD_compress2(context, dstBuffer.baseAddress, bufferCapacity, srcBuffer.baseAddress, data.count))
            }
        }

        let size = try validateCompressionResult(code: written, limit: options.maxOutputSize)
        if size > bufferCapacity {
            throw ZstdError.outputLimitExceeded
        }
        compressed.removeSubrange(size..<compressed.count)
        return compressed
    }

    @_disfavoredOverload
    public static func decompress(
        _ data: Data,
        maxDecompressedSize: Int? = Zstd.defaultMaxDecompressedSize
    ) throws -> Data {
        try decompress(data, options: DecompressionOptions(maxDecompressedSize: maxDecompressedSize))
    }

    public static func decompress(_ data: Data, options: DecompressionOptions = DecompressionOptions()) throws -> Data {
        guard !data.isEmpty else { throw ZstdError.invalidFrame }
        if let limit = options.maxDecompressedSize, limit <= 0 {
            throw ZstdError.outputLimitExceeded
        }

        let frameSize = data.withUnsafeBytes { buffer -> UInt64 in
            ZSTD_getFrameContentSize(buffer.baseAddress, buffer.count)
        }

        if frameSize == ZSTD_CONTENTSIZE_ERROR {
            throw ZstdError.invalidFrame
        }

        if frameSize != ZSTD_CONTENTSIZE_UNKNOWN {
            let expectedSize = try size(fromFrameContentSize: frameSize)
            if let limit = options.maxDecompressedSize, expectedSize > limit {
                throw ZstdError.outputLimitExceeded
            }

            return try decompressKnownSize(data, expectedSize: expectedSize, options: options)
        }

        return try decompressStreaming(data, options: options)
    }

    public static func compressStream(
        from input: FileHandle,
        to output: FileHandle,
        options: CompressionOptions = CompressionOptions(),
        chunkSize: Int = 64 * 1024
    ) throws {
        let readSize = try checkedPositiveSize(chunkSize)
        let compressor = try Compressor(options: options)
        let reserveSize = readSize <= Int.max / 2 ? readSize * 2 : Int.max
        var compressed = Data()
        reserveCapacity(for: &compressed, additional: reserveSize)

        while let chunk = try input.read(upToCount: readSize), !chunk.isEmpty {
            compressed.removeAll(keepingCapacity: true)
            try compressor.compress(chunk, into: &compressed)
            if !compressed.isEmpty {
                try output.write(contentsOf: compressed)
            }
        }

        compressed.removeAll(keepingCapacity: true)
        try compressor.finish(into: &compressed)
        if !compressed.isEmpty {
            try output.write(contentsOf: compressed)
        }
    }

    public static func decompressStream(
        from input: FileHandle,
        to output: FileHandle,
        options: DecompressionOptions = DecompressionOptions(),
        chunkSize: Int = 64 * 1024
    ) throws {
        let readSize = try checkedPositiveSize(chunkSize)
        let decompressor = try Decompressor(options: options)
        var partial = Data()
        let reserveSize = readSize <= Int.max / 3 ? readSize * 3 : Int.max
        let cappedReserve = options.maxDecompressedSize.map { min($0, reserveSize) } ?? reserveSize
        reserveCapacity(for: &partial, additional: cappedReserve)

        while let chunk = try input.read(upToCount: readSize), !chunk.isEmpty {
            partial.removeAll(keepingCapacity: true)
            let finished = try decompressor.decompress(chunk, into: &partial)
            if !partial.isEmpty {
                try output.write(contentsOf: partial)
            }
            if finished {
                break
            }
        }

        if !decompressor.isFinished {
            throw ZstdError.invalidFrame
        }
    }

    public static func compress<S: AsyncSequence>(
        chunks: S,
        options: CompressionOptions = CompressionOptions()
    ) -> AsyncThrowingStream<Data, Error> where S.Element == Data, S: Sendable {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let compressor = try Compressor(options: options)
                    for try await chunk in chunks {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }

                        let compressed = try compressor.compress(chunk)
                        if !compressed.isEmpty {
                            continuation.yield(compressed)
                        }
                    }

                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    let tail = try compressor.finish()
                    if !tail.isEmpty {
                        continuation.yield(tail)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public static func decompress<S: AsyncSequence>(
        chunks: S,
        options: DecompressionOptions = DecompressionOptions()
    ) -> AsyncThrowingStream<Data, Error> where S.Element == Data, S: Sendable {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let decompressor = try Decompressor(options: options)
                    for try await chunk in chunks {
                        if Task.isCancelled {
                            continuation.finish()
                            return
                        }

                        let (partial, finished) = try decompressor.decompress(chunk)
                        if !partial.isEmpty {
                            continuation.yield(partial)
                        }

                        if finished {
                            break
                        }
                    }

                    if Task.isCancelled {
                        continuation.finish()
                        return
                    }

                    if !decompressor.isFinished {
                        throw ZstdError.invalidFrame
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public static func trainDictionary(from samples: [Data], capacity: Int = 8_192) throws -> Data {
        guard !samples.isEmpty else { return Data() }
        guard capacity > 0 else { throw ZstdError.library(code: -1, message: "Dictionary capacity must be positive") }

        let totalSize = samples.reduce(0) { $0 + $1.count }
        var combined = Data()
        combined.reserveCapacity(totalSize)
        for sample in samples {
            combined.append(sample)
        }

        var sampleSizes = samples.map { $0.count }
        guard let sampleCount = UInt32(exactly: samples.count) else {
            throw ZstdError.library(code: -1, message: "Too many samples to train dictionary")
        }
        var dictionary = Data(count: capacity)

        let written = dictionary.withUnsafeMutableBytes { dictBuffer -> Int in
            combined.withUnsafeBytes { samplesBuffer in
                sampleSizes.withUnsafeMutableBufferPointer { sizesPointer in
                    Int(
                        ZDICT_trainFromBuffer(
                            dictBuffer.baseAddress,
                            capacity,
                            samplesBuffer.baseAddress,
                            sizesPointer.baseAddress,
                            sampleCount
                        )
                    )
                }
            }
        }

        let size = try validateDictionary(code: written)
        dictionary.removeSubrange(size..<dictionary.count)
        return dictionary
    }

    public static func trainDictionaryObject(
        from samples: [Data],
        capacity: Int = 8_192,
        level: Int32 = Zstd.defaultCompressionLevel
    ) throws -> Dictionary {
        let bytes = try trainDictionary(from: samples, capacity: capacity)
        return try Dictionary(data: bytes, level: level)
    }

    private static func decompressKnownSize(_ data: Data, expectedSize: Int, options: DecompressionOptions) throws -> Data {
        guard let context = ZSTD_createDCtx() else {
            throw ZstdError.library(code: -1, message: "Unable to create decompression context")
        }
        defer { ZSTD_freeDCtx(context) }

        try applyDecompressionOptions(options, to: context)

        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { dstBuffer -> Int in
            data.withUnsafeBytes { srcBuffer in
                Int(ZSTD_decompressDCtx(context, dstBuffer.baseAddress, expectedSize, srcBuffer.baseAddress, srcBuffer.count))
            }
        }

        let size = try validate(code: written)
        output.removeSubrange(size..<output.count)
        return output
    }

    private static func decompressStreaming(_ data: Data, options: DecompressionOptions) throws -> Data {
        guard let context = ZSTD_createDCtx() else {
            throw ZstdError.library(code: -1, message: "Unable to create decompression context")
        }
        defer { ZSTD_freeDCtx(context) }

        try applyDecompressionOptions(options, to: context)

        let chunkSize = try checkedChunkSize(Int(ZSTD_DStreamOutSize()))
        var output = Data()
        let streamingReserve = chunkSize <= Int.max / 2 ? chunkSize * 2 : Int.max
        let cappedStreamingReserve = options.maxDecompressedSize.map { min($0, streamingReserve) } ?? streamingReserve
        reserveCapacity(for: &output, additional: cappedStreamingReserve)
        var lastResult = 0

        try data.withUnsafeBytes { srcBuffer in
            var input = ZSTD_inBuffer(src: srcBuffer.baseAddress, size: srcBuffer.count, pos: 0)
            var scratch = Array<UInt8>(repeating: 0, count: chunkSize)

            try scratch.withUnsafeMutableBytes { scratchBuffer in
                guard let scratchBase = scratchBuffer.baseAddress else { return }

                while input.pos < input.size {
                    var out = ZSTD_outBuffer(dst: scratchBase, size: scratchBuffer.count, pos: 0)
                    let result = ZSTD_decompressStream(context, &out, &input)
                    lastResult = Int(result)
                    _ = try validate(code: lastResult)

                    if out.pos > 0 {
                        if let limit = options.maxDecompressedSize {
                            let remaining = limit - output.count
                            if remaining <= 0 || out.pos > remaining {
                                throw ZstdError.outputLimitExceeded
                            }
                        }
                        output.append(contentsOf: UnsafeRawBufferPointer(start: scratchBase, count: out.pos))
                    }

                    if lastResult == 0 && input.pos == input.size {
                        break
                    }
                }
            }
        }

        if lastResult != 0 {
            throw ZstdError.invalidFrame
        }

        return output
    }

    @inline(__always)
    private static func validateCompressionResult(code: Int, limit: Int?) throws -> Int {
        if ZSTD_isError(code) != 0 {
            if ZSTD_getErrorCode(code) == ZSTD_error_dstSize_tooSmall {
                throw ZstdError.outputLimitExceeded
            }

            let message = String(cString: ZSTD_getErrorName(code))
            throw ZstdError.library(code: code, message: message)
        }

        if let limit, code > limit {
            throw ZstdError.outputLimitExceeded
        }

        return code
    }

    @inline(__always)
    private static func validate(code: Int) throws -> Int {
        if ZSTD_isError(code) != 0 {
            let message = String(cString: ZSTD_getErrorName(code))
            throw ZstdError.library(code: code, message: message)
        }
        return code
    }

    @inline(__always)
    private static func validateDictionary(code: Int) throws -> Int {
        if ZDICT_isError(code) != 0 {
            let message = String(cString: ZDICT_getErrorName(code))
            throw ZstdError.library(code: code, message: message)
        }
        return code
    }

    @inline(__always)
    private static func size(fromFrameContentSize value: UInt64) throws -> Int {
        guard value <= UInt64(Int.max) else {
            throw ZstdError.frameTooLarge
        }
        return Int(value)
    }

    @inline(__always)
    private static func checkedPositiveSize(_ value: Int) throws -> Int {
        guard value > 0, value < Int.max else {
            throw ZstdError.frameTooLarge
        }
        return value
    }

    @inline(__always)
    private static func checkedChunkSize(_ value: Int) throws -> Int {
        let checked = try checkedPositiveSize(value)
        return max(64, checked)
    }

    @inline(__always)
    private static func reserveCapacity(for output: inout Data, additional: Int) {
        guard additional > 0 else { return }
        let target = output.count > Int.max - additional ? Int.max : output.count + additional
        output.reserveCapacity(target)
    }

    @inline(__always)
    private static func applyDecompressionOptions(_ options: DecompressionOptions, to context: OpaquePointer) throws {
        try apply(dictionary: options.dictionary, to: context)

        if let maxWindowLog = options.maxWindowLog {
            let minLog = 10
            let maxLog = MemoryLayout<Int>.size == 4 ? 30 : 31
            if maxWindowLog < minLog || maxWindowLog > maxLog {
                throw ZstdError.outputLimitExceeded
            }
            _ = try validate(code: Int(ZSTD_DCtx_setParameter(context, ZSTD_d_windowLogMax, Int32(maxWindowLog))))
        }
    }

    @inline(__always)
    private static func applyCompressionOptions(_ options: CompressionOptions, to context: OpaquePointer) throws {
        _ = try validate(code: Int(ZSTD_CCtx_setParameter(context, ZSTD_c_compressionLevel, options.level)))
        _ = try validate(code: Int(ZSTD_CCtx_setParameter(context, ZSTD_c_checksumFlag, options.checksum ? 1 : 0)))

        if let includeDictionaryID = options.includeDictionaryID {
            _ = try validate(code: Int(ZSTD_CCtx_setParameter(context, ZSTD_c_dictIDFlag, includeDictionaryID ? 1 : 0)))
        }

        if let windowLog = options.windowLog {
            _ = try validate(code: Int(ZSTD_CCtx_setParameter(context, ZSTD_c_windowLog, Int32(windowLog))))
        }

        if let threads = options.threads {
            _ = try validate(code: Int(ZSTD_CCtx_setParameter(context, ZSTD_c_nbWorkers, Int32(threads))))
        }

        if let dictionary = options.dictionary {
            _ = try validate(code: Int(ZSTD_CCtx_refCDict(context, dictionary.compress)))
        }
    }

    @inline(__always)
    private static func apply(dictionary: Dictionary?, to context: OpaquePointer) throws {
        if let dictionary {
            _ = try validate(code: Int(ZSTD_DCtx_refDDict(context, dictionary.decompress)))
        }
    }
}

extension Zstd.Dictionary: @unchecked Sendable {}

extension Zstd.ZstdError: Equatable {
    public static func == (lhs: Zstd.ZstdError, rhs: Zstd.ZstdError) -> Bool {
        switch (lhs, rhs) {
        case let (.library(codeA, _), .library(codeB, _)):
            return codeA == codeB
        case (.invalidFrame, .invalidFrame),
             (.outputLimitExceeded, .outputLimitExceeded),
             (.frameTooLarge, .frameTooLarge):
            return true
        default:
            return false
        }
    }
}
