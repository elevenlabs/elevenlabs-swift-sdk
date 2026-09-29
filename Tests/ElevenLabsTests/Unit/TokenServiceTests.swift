@testable import ElevenLabs
import XCTest

final class TokenServiceTests: XCTestCase {
    private let service: TokenService = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return TokenService(urlSession: URLSession(configuration: configuration))
    }()

    func testSuccessReturnsToken() async throws {
        for status in [200, 201] {
            StubURLProtocol.status = status
            let token = try await service.fetchToken(for: .publicAgent(id: "agent"), environment: nil)
            XCTAssertEqual(token, "stub-token")
        }
    }

    func testRefusalsAreAuthenticationFailures() async {
        for status in [401, 403, 404] {
            StubURLProtocol.status = status
            guard case .authenticationFailed = await publicAgentError() else {
                return XCTFail("Expected authenticationFailed for HTTP \(status)")
            }
        }
    }

    func testRetryableFailuresAreConnectionFailures() async {
        let cases: [(Int?, ConversationError.ConnectionFailure)] = [
            (429, .tokenServiceUnavailable), (500, .tokenServiceUnavailable), (503, .tokenServiceUnavailable),
            (nil, .tokenRequestFailed)
        ]
        for (status, failure) in cases {
            StubURLProtocol.status = status
            guard case .connectionFailed(failure, _) = await publicAgentError() else {
                return XCTFail("Expected connectionFailed(.\(failure)) for \(status.map { "HTTP \($0)" } ?? "a network failure")")
            }
        }
    }

    func testMintFailuresAreAuthenticationFailuresUnlessTheyAreConversationErrors() async {
        let passedThrough = ConversationError.connectionFailed(.tokenRequestFailed, "backend unreachable")
        let mintErrors: [(Error, ConversationError?)] = [(URLError(.badServerResponse), nil), (passedThrough, passedThrough)]
        for (thrown, expected) in mintErrors {
            do {
                _ = try await service.fetchToken(for: .conversationToken { throw thrown }, environment: nil)
                XCTFail("Expected an error")
            } catch let error as ConversationError {
                if let expected {
                    XCTAssertEqual(error, expected)
                } else if case .authenticationFailed = error {} else {
                    XCTFail("Expected authenticationFailed, got \(error)")
                }
            } catch {
                XCTFail("Expected a ConversationError, got \(error)")
            }
        }
    }

    private func publicAgentError() async -> ConversationError? {
        do {
            _ = try await service.fetchToken(for: .publicAgent(id: "agent"), environment: nil)
            return nil
        } catch {
            return error as? ConversationError
        }
    }
}

/// Answers every request with `status`, or fails like a dropped network when `status` is nil.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var status: Int? = 200

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let status = Self.status, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"token":"stub-token"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
