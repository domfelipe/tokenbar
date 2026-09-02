import Foundation

struct SeededRandom: Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
    }
}

@main
struct GenFixtures {
    static func main() {
        do {
            try run()
        } catch {
            FileHandle.standardError.write(Data("genfixtures error: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        var out = URL(filePath: "corpus")
        var sessions = 5
        var lines = 200
        var seed: UInt64 = 42
        var poison = false

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--out": out = URL(filePath: args[i + 1]); i += 2
            case "--sessions": sessions = Int(args[i + 1])!; i += 2
            case "--lines": lines = Int(args[i + 1])!; i += 2
            case "--seed": seed = UInt64(args[i + 1])!; i += 2
            case "--poison": poison = true; i += 1
            default: i += 1
            }
        }

        var rng = SeededRandom(seed: seed)
        let fm = FileManager.default
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        var input: Int64 = 0, output: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0
        var events = 0, fileCount = 0
        let now = Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        for s in 0..<sessions {
            let dir = out.appendingPathComponent("session-\(s)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
            var body = ""
            body.reserveCapacity(lines * 240)
            for _ in 0..<lines {
                let ts = iso.string(from: now.addingTimeInterval(TimeInterval(-rng.int(0...86_400))))
                let i = Int64(rng.int(0...5_000)), o = Int64(rng.int(0...2_000))
                let cr = Int64(rng.int(0...20_000)), cw = Int64(rng.int(0...1_000))
                if poison && rng.int(0...20) == 0 {
                    // linha inválida (JSON truncado): não conta nos totais
                    body += "{\"type\":\"assistant\",\"timestamp\":\"\(ts)\",\"message\":{\"usage\":{\"input_tok\n"
                } else {
                    input += i; output += o; cacheRead += cr; cacheWrite += cw
                    events += 1
                    body += #"{"type":"assistant","timestamp":"\#(ts)","cwd":"/tmp/fixture","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":\#(i),"output_tokens":\#(o),"cache_read_input_tokens":\#(cr),"cache_creation_input_tokens":\#(cw)}}}"# + "\n"
                }
                if poison && rng.int(0...40) == 0 { body += "\u{00}\u{01}garbage\n" }
            }
            try body.write(to: file, atomically: true, encoding: .utf8)
            fileCount += 1
        }

        let summary: [String: Any] = [
            "input": input, "output": output, "cacheRead": cacheRead,
            "cacheWrite": cacheWrite, "events": events, "files": fileCount,
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
