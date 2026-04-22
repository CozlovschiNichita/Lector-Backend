import Vapor

struct OllamaOptions: Content {
    var num_predict: Int?
    var temperature: Double?    
    var repeat_penalty: Double?
}

struct OllamaRequest: Content {
    let model: String
    let prompt: String
    let stream: Bool
    var options: OllamaOptions?
}

struct OllamaResponse: Content {
    let response: String
}
