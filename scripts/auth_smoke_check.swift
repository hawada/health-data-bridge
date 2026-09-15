import Foundation

@main
struct AuthSmokeCheck {
    static func main() async throws {
        let tokenStore = InMemoryTokenStore()
        MockCognitoURLProtocol.reset()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCognitoURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let auth = WhoopAuthService(tokenStore: tokenStore, session: session)
        expect(auth.currentStatus() == .disconnected, "Fresh auth service should start disconnected.")

        let firstStep = try await auth.signIn(email: "jose@example.com", password: "secret-password")
        guard case let .challenge(challenge) = firstStep else {
            fatalError("Expected MFA challenge from first sign-in step.")
        }
        expect(challenge.challengeName == "SMS_MFA", "Challenge name should parse from Cognito response.")
        expect(challenge.destination == "+***1234", "Challenge destination should parse from Cognito response.")
        expect(tokenStore.bundle == nil, "Token store should remain empty until MFA succeeds.")

        let tokenBundle = try await auth.respondToChallenge(code: " 123456 ")
        expect(tokenBundle.email == "jose@example.com", "MFA response should persist account email.")
        expect(tokenBundle.accessToken == "access-after-mfa", "MFA response should save returned access token.")
        expect(tokenBundle.refreshToken == "refresh-after-mfa", "MFA response should save returned refresh token.")
        expect(tokenStore.bundle == tokenBundle, "MFA response should save tokens.")
        expect(auth.currentStatus() == .authenticated(email: "jose@example.com"), "Saved refresh token should mark auth as authenticated.")

        tokenStore.bundle?.expiresAt = Date().addingTimeInterval(-10)
        let refreshedToken = try await auth.validAccessToken()
        expect(refreshedToken == "access-after-refresh", "Expired access token should trigger refresh.")
        expect(tokenStore.bundle?.refreshToken == "refresh-after-mfa", "Refresh flow should retain old refresh token when Cognito omits a new one.")

        try auth.disconnect()
        expect(tokenStore.bundle == nil, "Disconnect should remove saved tokens.")
        expect(auth.currentStatus() == .disconnected, "Disconnect should return to disconnected status.")

        let requests = MockCognitoURLProtocol.requests
        expect(requests.count == 3, "Auth smoke should perform sign-in, MFA and refresh requests.")
        expect(requests[0].body["AuthFlow"] as? String == "USER_PASSWORD_AUTH", "First request should use USER_PASSWORD_AUTH.")
        expect(requests[0].body["ClientId"] as? String == "", "Default WHOOP proxy request should intentionally send an empty ClientId.")
        expect((requests[1].body["ChallengeResponses"] as? [String: String])?["SMS_MFA_CODE"] == "123456", "MFA request should trim and send the SMS code.")
        expect(requests[2].body["AuthFlow"] as? String == "REFRESH_TOKEN_AUTH", "Refresh request should use REFRESH_TOKEN_AUTH.")

        MockCognitoURLProtocol.reset()
        let explicitAuth = WhoopAuthService(
            tokenStore: InMemoryTokenStore(),
            session: session,
            configuration: WhoopAuthConfiguration(clientIDMode: .explicit(" explicit-client "))
        )
        _ = try await explicitAuth.signIn(email: "jose@example.com", password: "secret-password")
        expect(MockCognitoURLProtocol.requests.first?.body["ClientId"] as? String == "explicit-client", "Auth configuration should allow an explicit Cognito ClientId override.")

        MockCognitoURLProtocol.reset()
        MockCognitoURLProtocol.overrideStatusCode = 400
        MockCognitoURLProtocol.overrideResponseBody = [
            "__type": "NotAuthorizedException",
            "message": "Rejected jose@example.com Authorization: Bearer secret-token password=secret-password refreshToken=refresh-secret jwt=header.payload.signature"
        ]
        let rejectedAuth = WhoopAuthService(
            tokenStore: InMemoryTokenStore(),
            session: session
        )
        do {
            _ = try await rejectedAuth.signIn(email: "jose@example.com", password: "secret-password")
            fatalError("Rejected Cognito responses should throw.")
        } catch {
            let message = error.localizedDescription
            expect(!message.contains("jose@example.com"), "Rejected Cognito error should redact emails.")
            expect(!message.contains("secret-token"), "Rejected Cognito error should redact bearer token material.")
            expect(!message.contains("secret-password"), "Rejected Cognito error should redact password material.")
            expect(!message.contains("refresh-secret"), "Rejected Cognito error should redact refresh token material.")
            expect(!message.contains("header.payload.signature"), "Rejected Cognito error should redact JWT-like values.")
            expect(message.contains("[redacted-email]"), "Rejected Cognito error should include the email redaction marker.")
            expect(message.contains("Bearer [redacted-token]"), "Rejected Cognito error should include the bearer redaction marker.")
        }

        print("WhoopAuthService smoke check passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError(message)
        }
    }
}

private final class InMemoryTokenStore: TokenStoring {
    var bundle: TokenBundle?

    func load() throws -> TokenBundle? {
        bundle
    }

    func save(_ bundle: TokenBundle) throws {
        self.bundle = bundle
    }

    func delete() throws {
        bundle = nil
    }
}

private final class MockCognitoURLProtocol: URLProtocol {
    struct RecordedRequest {
        var headers: [String: String]
        var body: [String: Any]
    }

    static var requests: [RecordedRequest] = []
    static var overrideStatusCode: Int?
    static var overrideResponseBody: [String: Any]?

    static func reset() {
        requests.removeAll()
        overrideStatusCode = nil
        overrideResponseBody = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.absoluteString == "https://api.prod.whoop.com/auth-service/v3/whoop/"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let bodyData = try requestBodyData()
            let body = try JSONSerialization.jsonObject(with: bodyData, options: []) as? [String: Any] ?? [:]
            MockCognitoURLProtocol.requests.append(
                RecordedRequest(
                    headers: request.allHTTPHeaderFields ?? [:],
                    body: body
                )
            )

            let statusCode = MockCognitoURLProtocol.overrideStatusCode ?? 200
            let responseBody = try MockCognitoURLProtocol.overrideResponseBody ?? response(for: body)
            let responseData = try JSONSerialization.data(withJSONObject: responseBody, options: [])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func response(for body: [String: Any]) throws -> [String: Any] {
        if body["ChallengeName"] as? String == "SMS_MFA" {
            return [
                "AuthenticationResult": [
                    "AccessToken": "access-after-mfa",
                    "RefreshToken": "refresh-after-mfa",
                    "IdToken": "id-after-mfa",
                    "ExpiresIn": 3600,
                    "TokenType": "Bearer"
                ]
            ]
        }

        switch body["AuthFlow"] as? String {
        case "USER_PASSWORD_AUTH":
            return [
                "ChallengeName": "SMS_MFA",
                "Session": "temporary-session",
                "ChallengeParameters": [
                    "CODE_DELIVERY_DESTINATION": "+***1234"
                ]
            ]
        case "REFRESH_TOKEN_AUTH":
            return [
                "AuthenticationResult": [
                    "AccessToken": "access-after-refresh",
                    "IdToken": "id-after-refresh",
                    "ExpiresIn": 3600,
                    "TokenType": "Bearer"
                ]
            ]
        default:
            return [:]
        }
    }

    private func requestBodyData() throws -> Data {
        if let data = request.httpBody {
            return data
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 {
                throw stream.streamError ?? CocoaError(.fileReadUnknown)
            }
            if read == 0 {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }
}
