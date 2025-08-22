//
//  Copyright © 2023 Dennis Müller and all collaborators
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Base
import Foundation
import GPTSwiftSharedTypes
import Get

extension ChatGPT {
    public class StreamedAnswer {
        private let client: APIClient
        private let apiKey: String
        private let defaultModel: ChatGPTModel

        init(client: APIClient, apiKey: String, defaultModel: ChatGPTModel) {
            self.client = client
            self.apiKey = apiKey
            self.defaultModel = defaultModel
        }

        /// Ask ChatGPT a single prompt without any special configuration.
        /// - Parameter userPrompt: The prompt to send
        /// - Parameter systemPrompt: An optional system prompt to give GPT instructions on how to answer.
        /// - Parameter model: The model that should be used.
        /// - Returns: The response.
        /// - Throws: A `GPTSwiftError`.
        @available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
        public func ask(
            _ userPrompt: String,
            withSystemPrompt systemPrompt: String? = nil,
            model: ChatGPTModel = .default
        ) async throws -> AsyncThrowingStream<String, Swift.Error> {
            var messages: [ChatMessage] = []

            if let systemPrompt {
                messages.insert(.init(role: .system, content: systemPrompt), at: 0)
            }

            messages.append(.init(role: .user, content: userPrompt))
            let usingModel = model is DefaultChatGPTModel ? defaultModel : model
            let chatRequest = ChatRequest.streamed(
                model: usingModel,
                messages: messages
            )

            return try await ask(request: chatRequest)
        }

        /// Ask ChatGPT something by sending multiple messages without any special configuration.
        /// - Parameter messages: The chat messages.
        /// - Parameter model: The model that should be used.
        /// - Returns: The response.
        /// - Throws: A `GPTSwiftError`.
        @available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
        public func ask(
            messages: [ChatMessage],
            model: ChatGPTModel = .default
        ) async throws -> AsyncThrowingStream<String, Swift.Error> {
            let usingModel = model is DefaultChatGPTModel ? defaultModel : model
            let chatRequest = ChatRequest.streamed(model: usingModel, messages: messages)
            return try await ask(request: chatRequest)
        }

        /// Ask ChatGPT something by providing a chat request object, giving you full control over the request's configuration.
        /// - Parameter chatRequest: The request.
        /// - Returns: The response.
        /// - Throws: A `GPTSwiftError`.
        @available(macOS 12.0, iOS 15.0, watchOS 8.0, tvOS 15.0, *)
        public func ask(request chatRequest: ChatRequest) async throws -> AsyncThrowingStream<
            String, Swift.Error
        > {

            var chatRequest = chatRequest
            chatRequest.stream = true

            let request = Request(path: API.v1ChatCompletion, method: .post, body: chatRequest)
            var urlRequest = try await client.makeURLRequest(for: request)
            _addHeaders(to: &urlRequest, apiKey: apiKey)

            do {
                let (result, response) = try await client.session.bytes(for: urlRequest)

                guard let response = response as? HTTPURLResponse else {
                    throw GPTSwiftError.responseParsingFailed
                }

                guard response.statusCode.isStatusCodeOkay else {
                    throw GPTSwiftError.requestFailed(
                        message: "Response status code was unacceptable: \(response.statusCode)")
                }

                return AsyncThrowingStream { continuation in
                    Task {
                        var linesProcessed = 0
                        do {
                            for try await line in result.lines {
                                linesProcessed += 1
                                print("GPTSwift DEBUG: Received line \(linesProcessed): \(line)")  // <-- LOGGING

                                if line == "data: [DONE]" {
                                    print("GPTSwift DEBUG: End of stream detected.")  // <-- LOGGING
                                    break
                                }

                                guard line.hasPrefix("data: "),
                                    let data = line.dropFirst(6).data(using: .utf8)
                                else {
                                    continue
                                }

                                do {
                                    let chatResponse = try decoder.decode(
                                        ChatStreamedResponse.self, from: data)
                                    if let message = chatResponse.choices.first?.delta.content {
                                        continuation.yield(message)
                                    }
                                } catch {
                                    // This is the most important log! It will tell us if the JSON is wrong.
                                    print(
                                        "GPTSwift DEBUG: JSON DECODING FAILED. Error: \(error). Data: \(String(data: data, encoding: .utf8) ?? "corrupt")"
                                    )  // <-- LOGGING
                                }
                            }
                        } catch {
                            print("GPTSwift DEBUG: Error while reading stream lines: \(error)")  // <-- LOGGING
                            continuation.finish(throwing: GPTSwiftError.responseParsingFailed)
                            return
                        }

                        print(
                            "GPTSwift DEBUG: Stream processing finished. Processed \(linesProcessed) lines."
                        )  // <-- LOGGING
                        continuation.finish()
                    }
                }
            } catch {
                throw _errorToGPTSwiftError(error)
            }
        }

        /// Turns a chat request into a curl prompt that you can paste into a terminal.
        ///
        /// This method will change the provided chat request to include a `stream: true` argument.
        /// The rest of the request will not be changed.
        ///
        /// This might be useful for debugging to experimenting.
        /// Taken from [Abhishek Maurya](https://gist.github.com/abhi21git/3dc611aab9e1cf5e5343ba4b58573596) and slightly adjusted.
        /// - Parameters:
        ///   - chatRequest: The request.
        ///   - pretty: An option to make the curl prompt pretty.
        /// - Returns: The curl prompt.
        public func curl(for chatRequest: ChatRequest, pretty: Bool = true) async throws -> String {
            var chatRequest = chatRequest
            chatRequest.stream = true
            let request = Request(path: API.v1ChatCompletion, method: .post, body: chatRequest)
            var urlRequest = try await client.makeURLRequest(for: request)
            _addHeaders(to: &urlRequest, apiKey: apiKey)
            return urlRequest.curl(pretty: pretty, formatOutput: false)
        }
    }
}

private let decoder = JSONDecoder()
extension String {
    fileprivate var asStreamedResponse: ChatStreamedResponse? {
        guard hasPrefix("data: "),
            let data = dropFirst(6).data(using: .utf8)
        else {
            return nil
        }
        return try? decoder.decode(ChatStreamedResponse.self, from: data)
    }
}

extension Int {
    fileprivate var isStatusCodeOkay: Bool {
        (200...299).contains(self)
    }
}
