import Vapor
import FoundationModels

struct ChatMessage: Content {
    let role: String
    let content: String
    
    enum CodingKeys: String, CodingKey {
        case role, content
    }
    
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(String.self, forKey: .role)
        
        if let stringContent = try? container.decode(String.self, forKey: .content) {
            self.content = stringContent
        } else {
            struct ContentPart: Decodable { let text: String? }
            let arrayContent = try container.decode([ContentPart].self, forKey: .content)
            self.content = arrayContent.compactMap { $0.text }.joined(separator: " ")
        }
    }
}

struct ChatRequest: Content {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool?
}

struct StreamResponse: Content {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [StreamChoice]
}

struct StreamChoice: Content {
    let index: Int
    let delta: StreamDelta
    let finish_reason: String?
}

struct StreamDelta: Content {
    let role: String?
    let content: String?
}

struct ChatResponse: Content {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [ChatChoice]
}

struct ChatChoice: Content {
    let index: Int
    let message: ChatMessageResponse
    let finish_reason: String
}

struct ChatMessageResponse: Content {
    let role: String
    let content: String
}

struct ModelListResponse: Content {
    let object: String
    let data: [ModelData]
}

struct ModelData: Content {
    let id: String
    let object: String
}

func routes(_ app: Application) throws {
    let session = LanguageModelSession()

    app.get("v1", "models") { req async -> ModelListResponse in
        return ModelListResponse(
            object: "list",
            data: [ModelData(id: "foundation-model", object: "model")]
        )
    }

    app.post("v1", "chat", "completions") { req async throws -> Response in
        let input = try req.content.decode(ChatRequest.self)
        let lastUserMessage = input.messages.last(where: { $0.role == "user" })?.content ?? ""
        
        if input.stream == true {
            let response = Response(body: .init(stream: { writer in
                let reqId = "chatcmpl-\(UUID().uuidString)"
                let created = Int(Date().timeIntervalSince1970)
                let encoder = JSONEncoder()
                
                Task {
                    do {
                        let stream = session.streamResponse(to: lastUserMessage)
                        var previousContent = ""
                        
                        for try await partialResult in stream {
                            let currentContent = partialResult.content
                            
                            let deltaString: String
                            if currentContent.count > previousContent.count {
                                let index = currentContent.index(currentContent.startIndex, offsetBy: previousContent.count)
                                deltaString = String(currentContent[index...])
                            } else {
                                deltaString = ""
                            }
                            
                            previousContent = currentContent
                            
                            if !deltaString.isEmpty {
                                let chunk = StreamResponse(
                                    id: reqId,
                                    object: "chat.completion.chunk",
                                    created: created,
                                    model: input.model,
                                    choices: [
                                        StreamChoice(
                                            index: 0,
                                            delta: StreamDelta(role: nil, content: deltaString),
                                            finish_reason: nil
                                        )
                                    ]
                                )
                                
                                if let data = try? encoder.encode(chunk),
                                   let jsonString = String(data: data, encoding: .utf8) {
                                    _ = writer.write(.buffer(ByteBuffer(string: "data: \(jsonString)\n\n")))
                                }
                            }
                        }
                        
                        let finishChunk = StreamResponse(
                            id: reqId,
                            object: "chat.completion.chunk",
                            created: created,
                            model: input.model,
                            choices: [
                                StreamChoice(
                                    index: 0,
                                    delta: StreamDelta(role: nil, content: nil),
                                    finish_reason: "stop"
                                )
                            ]
                        )
                        
                        if let data = try? encoder.encode(finishChunk),
                           let jsonString = String(data: data, encoding: .utf8) {
                            _ = writer.write(.buffer(ByteBuffer(string: "data: \(jsonString)\n\n")))
                        }
                        
                        _ = writer.write(.buffer(ByteBuffer(string: "data: [DONE]\n\n")))
                        _ = writer.write(.end)
                        
                    } catch {
                        _ = writer.write(.end)
                    }
                }
            }))
            
            response.headers.replaceOrAdd(name: .contentType, value: "text/event-stream")
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
            response.headers.replaceOrAdd(name: .connection, value: "keep-alive")
            return response
            
        } else {
            let result = try await session.respond(to: lastUserMessage)
            let responseContent = result.content
            
            let jsonResponse = ChatResponse(
                id: "chatcmpl-\(UUID().uuidString)",
                object: "chat.completion",
                created: Int(Date().timeIntervalSince1970),
                model: input.model,
                choices: [
                    ChatChoice(
                        index: 0,
                        message: ChatMessageResponse(role: "assistant", content: responseContent),
                        finish_reason: "stop"
                    )
                ]
            )
            
            let data = try JSONEncoder().encode(jsonResponse)
            var headers = HTTPHeaders()
            headers.add(name: .contentType, value: "application/json")
            return Response(status: .ok, headers: headers, body: .init(data: data))
        }
    }
}
