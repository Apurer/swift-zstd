import Foundation
import Zstd

struct Sample {
    let name: String
    let data: Data
}

func timed<T>(_ clock: ContinuousClock, _ work: () throws -> T) rethrows -> (Duration, T) {
    let start = clock.now
    let value = try work()
    return (start.duration(to: clock.now), value)
}

func format(_ duration: Duration) -> String {
    let ms = Double(duration.components.seconds) * 1_000
        + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    return String(format: "%.2f ms", ms)
}

@main
enum Runner {
    static func main() throws {
        let clock = ContinuousClock()
        let samples = [
            Sample(name: "small (64 KB, repetitive)", data: Data(repeating: 0xAB, count: 64_000)),
            Sample(name: "medium (1 MB, patterned)", data: patterned(size: 1_000_000)),
        ]

        print("swift-zstd benchmarks (informal)\n")

        for sample in samples {
            print("One-shot compress/decompress - \(sample.name)")
            let (compressedDuration, compressed) = try timed(clock) {
                try Zstd.compress(sample.data, options: .init(level: 5, threads: 0))
            }

            let decompressDuration = try clock.measure {
                _ = try Zstd.decompress(compressed, options: .init(maxDecompressedSize: sample.data.count * 2))
            }

            let ratio = Double(compressed.count) / Double(sample.data.count)
            print("  compress:   \(format(compressedDuration))  ratio: \(String(format: "%.3f", ratio))")
            print("  decompress: \(format(decompressDuration))")
            print()
        }

        print("Streaming reuse (threaded)")
        var streamingCompressed = Data()
        let compressor = try Zstd.Compressor(options: .init(level: 3, threads: 2, jobSize: 128_000))
        let streamingDuration = try clock.measure {
            for chunk in chunkData(patterned(size: 2_000_000), size: 128_000) {
                streamingCompressed.append(try compressor.compress(chunk))
            }
            streamingCompressed.append(try compressor.finish())
        }

        print("  compressed bytes: \(streamingCompressed.count)")
        print("  compress time:    \(format(streamingDuration))\n")

        print("Dictionary compression")
        let training = (0..<40).map { index in
            Data("dict-sample-\(index)-\(String(repeating: "x", count: index % 5))".utf8)
        }
        let dictionary = try Zstd.Dictionary(data: Zstd.trainDictionary(from: training, capacity: 4_096))
        let dictSample = Sample(name: "structured (128 KB)", data: patterned(size: 128_000))
        let (dictCompressDuration, dictCompressed) = try timed(clock) {
            try Zstd.compress(dictSample.data, options: .init(dictionary: dictionary))
        }
        let dictDecompressDuration = try clock.measure {
            _ = try Zstd.decompress(dictCompressed, options: .init(dictionary: dictionary, maxDecompressedSize: dictSample.data.count * 2))
        }
        let dictRatio = Double(dictCompressed.count) / Double(dictSample.data.count)

        print("  compress:   \(format(dictCompressDuration))  ratio: \(String(format: "%.3f", dictRatio))")
        print("  decompress: \(format(dictDecompressDuration))")
        print("\nBenchmarks complete (results are indicative; measure on your workload).")
    }
}

private func patterned(size: Int) -> Data {
    guard size > 0 else { return Data() }
    var bytes: [UInt8] = []
    bytes.reserveCapacity(size)
    for index in 0..<size {
        bytes.append(UInt8((index * 31) & 0xFF))
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
