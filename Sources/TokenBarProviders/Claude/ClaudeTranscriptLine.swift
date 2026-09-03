struct ClaudeTranscriptLine: Decodable {
    struct Message: Decodable {
        struct Usage: Decodable {
            var input_tokens: Int64?
            var output_tokens: Int64?
            var cache_read_input_tokens: Int64?
            var cache_creation_input_tokens: Int64?
        }
        var model: String?
        var usage: Usage?
    }
    var type: String?
    var timestamp: String?
    var cwd: String?
    var message: Message?
}
