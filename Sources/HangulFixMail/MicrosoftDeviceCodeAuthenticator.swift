import Foundation
import Security

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SafeMailError.invalidServerResponse("HTTP 응답이 아닙니다.")
        }
        return (data, http)
    }
}

public protocol RefreshTokenStoring: Sendable {
    func load(configuration: MicrosoftGraphConfiguration) throws -> String?
    func save(_ token: String, configuration: MicrosoftGraphConfiguration) throws
    func delete(configuration: MicrosoftGraphConfiguration) throws
}

public struct KeychainRefreshTokenStore: RefreshTokenStoring, Sendable {
    private let service = "com.limait.HangulFix.microsoftgraph"

    public init() {}

    public func load(configuration: MicrosoftGraphConfiguration) throws -> String? {
        var query = baseQuery(configuration: configuration)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw keychainError(status)
        }
        guard let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else {
            throw SafeMailError.authenticationFailed("Keychain refresh token을 읽을 수 없습니다.")
        }
        return token
    }

    public func save(_ token: String, configuration: MicrosoftGraphConfiguration) throws {
        guard let data = token.data(using: .utf8) else {
            throw SafeMailError.authenticationFailed("refresh token 인코딩 실패")
        }

        let query = baseQuery(configuration: configuration)
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw keychainError(addStatus)
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw keychainError(updateStatus)
        }
    }

    public func delete(configuration: MicrosoftGraphConfiguration) throws {
        let status = SecItemDelete(baseQuery(configuration: configuration) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func baseQuery(configuration: MicrosoftGraphConfiguration) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(configuration.tenant)|\(configuration.clientID)"
        ]
    }

    private func keychainError(_ status: OSStatus) -> SafeMailError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .authenticationFailed("Keychain 오류: \(message)")
    }
}

public protocol MicrosoftAccessTokenProviding: Sendable {
    func accessToken(for configuration: MicrosoftGraphConfiguration) async throws -> String
    func invalidateAccessToken(for configuration: MicrosoftGraphConfiguration) async
}

public actor MicrosoftDeviceCodeAuthenticator: MicrosoftAccessTokenProviding {
    private struct CachedToken: Sendable {
        let accessToken: String
        let expiresAt: Date
    }

    private struct DeviceCodeResponse: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let expiresIn: Int
        let interval: Int?
        let message: String?
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
    }

    private struct OAuthErrorResponse: Decodable {
        let error: String
        let errorDescription: String?
    }

    private let transport: HTTPTransport
    private let tokenStore: RefreshTokenStoring
    private let scopes = "offline_access Mail.ReadWrite"
    private var cache: [MicrosoftGraphConfiguration: CachedToken] = [:]

    public init(
        transport: HTTPTransport = URLSessionHTTPTransport(),
        tokenStore: RefreshTokenStoring = KeychainRefreshTokenStore()
    ) {
        self.transport = transport
        self.tokenStore = tokenStore
    }

    public func hasSavedSession(for configuration: MicrosoftGraphConfiguration) -> Bool {
        guard configuration.isValid else { return false }
        return (try? tokenStore.load(configuration: configuration)) != nil
    }

    public func beginSignIn(configuration: MicrosoftGraphConfiguration) async throws -> DeviceCodePrompt {
        guard configuration.isValid else {
            throw SafeMailError.invalidConfiguration
        }

        let url = try endpoint(configuration: configuration, path: "devicecode")
        let (data, response) = try await postForm(
            url: url,
            fields: [
                "client_id": configuration.clientID,
                "scope": scopes
            ]
        )

        guard response.statusCode == 200 else {
            throw authenticationError(data: data, status: response.statusCode)
        }

        let decoded = try decode(DeviceCodeResponse.self, from: data)
        guard let verificationURL = URL(string: decoded.verificationUri) else {
            throw SafeMailError.invalidServerResponse("verification_uri가 올바르지 않습니다.")
        }

        return DeviceCodePrompt(
            deviceCode: decoded.deviceCode,
            userCode: decoded.userCode,
            verificationURI: verificationURL,
            message: decoded.message ?? "브라우저에서 Microsoft 로그인 후 코드를 입력해 주세요.",
            expiresIn: decoded.expiresIn,
            interval: max(decoded.interval ?? 5, 1)
        )
    }

    public func completeSignIn(
        configuration: MicrosoftGraphConfiguration,
        prompt: DeviceCodePrompt
    ) async throws {
        guard configuration.isValid else {
            throw SafeMailError.invalidConfiguration
        }

        let deadline = Date().addingTimeInterval(TimeInterval(prompt.expiresIn))
        var interval = prompt.interval
        let url = try endpoint(configuration: configuration, path: "token")

        while Date() < deadline {
            try await sleep(seconds: interval)

            let (data, response) = try await postForm(
                url: url,
                fields: [
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "client_id": configuration.clientID,
                    "device_code": prompt.deviceCode
                ]
            )

            if response.statusCode == 200 {
                let token = try decode(TokenResponse.self, from: data)
                guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
                    throw SafeMailError.authenticationFailed("refresh token이 반환되지 않았습니다. offline_access 설정을 확인해 주세요.")
                }
                try tokenStore.save(refreshToken, configuration: configuration)
                cache[configuration] = CachedToken(
                    accessToken: token.accessToken,
                    expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn))
                )
                return
            }

            let oauthError = try? decode(OAuthErrorResponse.self, from: data)
            switch oauthError?.error {
            case "authorization_pending":
                continue
            case "slow_down":
                interval += 5
                continue
            case "authorization_declined":
                throw SafeMailError.authenticationDeclined
            case "expired_token", "bad_verification_code":
                throw SafeMailError.authenticationExpired
            default:
                throw authenticationError(data: data, status: response.statusCode)
            }
        }

        throw SafeMailError.authenticationExpired
    }

    public func accessToken(for configuration: MicrosoftGraphConfiguration) async throws -> String {
        guard configuration.isValid else {
            throw SafeMailError.invalidConfiguration
        }

        if let cached = cache[configuration],
           cached.expiresAt.timeIntervalSinceNow > 60 {
            return cached.accessToken
        }

        guard let refreshToken = try tokenStore.load(configuration: configuration) else {
            throw SafeMailError.signInRequired
        }

        let url = try endpoint(configuration: configuration, path: "token")
        let (data, response) = try await postForm(
            url: url,
            fields: [
                "grant_type": "refresh_token",
                "client_id": configuration.clientID,
                "refresh_token": refreshToken,
                "scope": scopes
            ]
        )

        guard response.statusCode == 200 else {
            cache[configuration] = nil
            if response.statusCode == 400 || response.statusCode == 401 {
                try? tokenStore.delete(configuration: configuration)
            }
            throw authenticationError(data: data, status: response.statusCode)
        }

        let token = try decode(TokenResponse.self, from: data)
        if let newRefreshToken = token.refreshToken, !newRefreshToken.isEmpty {
            try tokenStore.save(newRefreshToken, configuration: configuration)
        }

        cache[configuration] = CachedToken(
            accessToken: token.accessToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn))
        )
        return token.accessToken
    }

    public func invalidateAccessToken(for configuration: MicrosoftGraphConfiguration) async {
        cache[configuration] = nil
    }

    public func signOut(configuration: MicrosoftGraphConfiguration) throws {
        cache[configuration] = nil
        try tokenStore.delete(configuration: configuration)
    }

    private func endpoint(configuration: MicrosoftGraphConfiguration, path: String) throws -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let tenant = configuration.tenant.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/\(path)") else {
            throw SafeMailError.invalidConfiguration
        }
        return url
    }

    private func postForm(
        url: URL,
        fields: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(fields)

        var attempt = 0
        while true {
            do {
                let result = try await transport.data(for: request)
                if shouldRetry(status: result.1.statusCode), attempt < 3 {
                    attempt += 1
                    try await sleep(seconds: retryDelay(response: result.1, attempt: attempt))
                    continue
                }
                return result
            } catch {
                guard attempt < 3 else { throw error }
                attempt += 1
                try await sleep(seconds: min(1 << attempt, 8))
            }
        }
    }

    private func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        let encoded = fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private func authenticationError(data: Data, status: Int) -> SafeMailError {
        if let oauth = try? decode(OAuthErrorResponse.self, from: data) {
            return .authenticationFailed(oauth.errorDescription ?? oauth.error)
        }
        let message = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
        return .authenticationFailed(message)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw SafeMailError.invalidServerResponse(error.localizedDescription)
        }
    }

    private func shouldRetry(status: Int) -> Bool {
        status == 429 || status == 500 || status == 502 || status == 503 || status == 504
    }

    private func retryDelay(response: HTTPURLResponse, attempt: Int) -> Int {
        if let raw = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Int(raw) {
            return max(seconds, 1)
        }
        return min(1 << attempt, 8)
    }

    private func sleep(seconds: Int) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(seconds, 0)) * 1_000_000_000)
    }
}
