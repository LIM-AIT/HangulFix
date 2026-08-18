import Foundation

public struct MicrosoftGraphMailService: Sendable {
    private struct CreatedMessage: Decodable {
        let id: String
        let webLink: String?
    }

    private struct UploadedAttachment: Decodable {
        let id: String?
        let name: String
        let size: Int64?
    }

    private struct AttachmentList: Decodable {
        let value: [UploadedAttachment]
        let nextLink: String?

        private enum CodingKeys: String, CodingKey {
            case value
            case nextLink = "@odata.nextLink"
        }
    }

    private struct UploadSession: Decodable {
        let uploadUrl: String
        let nextExpectedRanges: [String]?
    }

    private struct GraphErrorEnvelope: Decodable {
        struct GraphError: Decodable {
            let code: String?
            let message: String?
        }
        let error: GraphError
    }

    private let transport: HTTPTransport
    private let tokenProvider: MicrosoftAccessTokenProviding

    public init(
        transport: HTTPTransport = URLSessionHTTPTransport(),
        tokenProvider: MicrosoftAccessTokenProviding = MicrosoftDeviceCodeAuthenticator()
    ) {
        self.transport = transport
        self.tokenProvider = tokenProvider
    }

    public func createVerifiedDraft(
        configuration: MicrosoftGraphConfiguration,
        request: SafeMailDraftRequest
    ) async throws -> SafeMailDraftResult {
        guard configuration.isValid else {
            throw SafeMailError.invalidConfiguration
        }

        let recipients = request.recipients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !recipients.isEmpty else {
            throw SafeMailError.invalidRecipient("")
        }
        for recipient in recipients where !SafeMailAttachmentValidator.isPlausibleEmailAddress(recipient) {
            throw SafeMailError.invalidRecipient(recipient)
        }

        let attachments = try SafeMailAttachmentValidator.validate(paths: request.attachmentPaths)
        let message = try await createDraft(
            configuration: configuration,
            recipients: recipients,
            subject: request.subject,
            body: request.body
        )

        do {
            for attachment in attachments {
                if attachment.size < SafeMailAttachmentValidator.directUploadThreshold {
                    try await uploadSmallAttachment(
                        configuration: configuration,
                        messageID: message.id,
                        attachment: attachment
                    )
                } else {
                    try await uploadLargeAttachment(
                        configuration: configuration,
                        messageID: message.id,
                        attachment: attachment
                    )
                }
            }

            let stored = try await listAttachments(
                configuration: configuration,
                messageID: message.id
            )
            try verifyStoredAttachments(expected: attachments, actual: stored)

            let webLink = message.webLink.flatMap(URL.init(string:))
            return SafeMailDraftResult(
                messageID: message.id,
                webLink: webLink,
                verifiedAttachmentNames: attachments.map(\.name)
            )
        } catch {
            await deleteDraftBestEffort(
                configuration: configuration,
                messageID: message.id
            )
            throw error
        }
    }

    private func createDraft(
        configuration: MicrosoftGraphConfiguration,
        recipients: [String],
        subject: String,
        body: String
    ) async throws -> CreatedMessage {
        let url = try graphURL(["me", "messages"])
        let payload: [String: Any] = [
            "subject": subject,
            "body": [
                "contentType": "Text",
                "content": body
            ],
            "toRecipients": recipients.map { address in
                ["emailAddress": ["address": address]]
            }
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await authorizedData(
            for: request,
            configuration: configuration
        )
        guard (200..<300).contains(response.statusCode) else {
            throw graphError(data: data, status: response.statusCode)
        }
        return try decode(CreatedMessage.self, from: data)
    }

    private func uploadSmallAttachment(
        configuration: MicrosoftGraphConfiguration,
        messageID: String,
        attachment: SafeMailAttachment
    ) async throws {
        let fileData: Data
        do {
            fileData = try Data(contentsOf: URL(fileURLWithPath: attachment.path), options: [.mappedIfSafe])
        } catch {
            throw SafeMailError.uploadFailed(error.localizedDescription)
        }

        guard Int64(fileData.count) == attachment.size else {
            throw SafeMailError.uploadFailed("업로드 직전에 파일 크기가 변경되었습니다: \(attachment.name)")
        }

        let url = try graphURL(["me", "messages", messageID, "attachments"])
        let payload: [String: Any] = [
            "@odata.type": "#microsoft.graph.fileAttachment",
            "name": attachment.name,
            "contentType": attachment.contentType,
            "isInline": false,
            "contentBytes": fileData.base64EncodedString()
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await authorizedData(
            for: request,
            configuration: configuration
        )
        guard response.statusCode == 201 else {
            throw graphError(data: data, status: response.statusCode)
        }

        let uploaded = try decode(UploadedAttachment.self, from: data)
        guard uploaded.name.utf8.elementsEqual(attachment.name.utf8) else {
            throw SafeMailError.attachmentVerificationFailed(
                expected: attachment.name,
                actual: uploaded.name
            )
        }
    }

    private func uploadLargeAttachment(
        configuration: MicrosoftGraphConfiguration,
        messageID: String,
        attachment: SafeMailAttachment
    ) async throws {
        let sessionURL = try graphURL([
            "me", "messages", messageID, "attachments", "createUploadSession"
        ])
        let payload: [String: Any] = [
            "AttachmentItem": [
                "attachmentType": "file",
                "name": attachment.name,
                "size": attachment.size
            ]
        ]

        var createRequest = URLRequest(url: sessionURL)
        createRequest.httpMethod = "POST"
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createRequest.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (sessionData, sessionResponse) = try await authorizedData(
            for: createRequest,
            configuration: configuration
        )
        guard sessionResponse.statusCode == 201 else {
            throw graphError(data: sessionData, status: sessionResponse.statusCode)
        }

        let session = try decode(UploadSession.self, from: sessionData)
        guard let uploadURL = URL(string: session.uploadUrl),
              uploadURL.scheme?.lowercased() == "https" else {
            throw SafeMailError.invalidServerResponse("대용량 첨부 uploadUrl이 올바르지 않습니다.")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: attachment.path))
        } catch {
            throw SafeMailError.uploadFailed(error.localizedDescription)
        }
        defer { try? handle.close() }

        let chunkSize = 2 * 1_048_576
        var offset: Int64 = 0

        while offset < attachment.size {
            let remaining = attachment.size - offset
            let requested = Int(min(Int64(chunkSize), remaining))
            let chunk = try handle.read(upToCount: requested) ?? Data()
            guard !chunk.isEmpty, chunk.count == requested else {
                throw SafeMailError.uploadFailed("파일을 끝까지 읽지 못했습니다: \(attachment.name)")
            }

            let end = offset + Int64(chunk.count) - 1
            var uploadRequest = URLRequest(url: uploadURL)
            uploadRequest.httpMethod = "PUT"
            uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            uploadRequest.setValue(String(chunk.count), forHTTPHeaderField: "Content-Length")
            uploadRequest.setValue(
                "bytes \(offset)-\(end)/\(attachment.size)",
                forHTTPHeaderField: "Content-Range"
            )
            uploadRequest.httpBody = chunk

            let (responseData, response) = try await unauthenticatedUploadData(for: uploadRequest)
            guard response.statusCode == 200
                    || response.statusCode == 201
                    || response.statusCode == 202 else {
                throw graphError(data: responseData, status: response.statusCode)
            }
            offset = end + 1
        }
    }

    private func listAttachments(
        configuration: MicrosoftGraphConfiguration,
        messageID: String
    ) async throws -> [UploadedAttachment] {
        var nextURL = try graphURL(
            ["me", "messages", messageID, "attachments"],
            queryItems: [URLQueryItem(name: "$select", value: "id,name,size")]
        )
        var all: [UploadedAttachment] = []

        while true {
            var request = URLRequest(url: nextURL)
            request.httpMethod = "GET"

            let (data, response) = try await authorizedData(
                for: request,
                configuration: configuration
            )
            guard (200..<300).contains(response.statusCode) else {
                throw graphError(data: data, status: response.statusCode)
            }

            let page = try decode(AttachmentList.self, from: data)
            all.append(contentsOf: page.value)
            guard let rawNext = page.nextLink else { break }
            guard let parsed = URL(string: rawNext), parsed.scheme?.lowercased() == "https" else {
                throw SafeMailError.invalidServerResponse("첨부 파일 목록 nextLink가 올바르지 않습니다.")
            }
            nextURL = parsed
        }

        return all
    }

    private func verifyStoredAttachments(
        expected: [SafeMailAttachment],
        actual: [UploadedAttachment]
    ) throws {
        guard expected.count == actual.count else {
            throw SafeMailError.attachmentCountMismatch(
                expected: expected.count,
                actual: actual.count
            )
        }

        var unmatched = actual
        for item in expected {
            if let index = unmatched.firstIndex(where: { stored in
                stored.name.utf8.elementsEqual(item.name.utf8)
                    && (stored.size == nil || stored.size == item.size)
            }) {
                let stored = unmatched.remove(at: index)
                guard !stored.name.precomposedStringWithCanonicalMapping.utf8.elementsEqual(stored.name.utf8)
                        == false else {
                    throw SafeMailError.attachmentVerificationFailed(
                        expected: item.name,
                        actual: stored.name
                    )
                }
                continue
            }

            let canonicalEquivalent = unmatched.first(where: {
                $0.name.precomposedStringWithCanonicalMapping.utf8.elementsEqual(item.name.utf8)
            })?.name
            throw SafeMailError.attachmentVerificationFailed(
                expected: item.name,
                actual: canonicalEquivalent
            )
        }
    }

    private func authorizedData(
        for originalRequest: URLRequest,
        configuration: MicrosoftGraphConfiguration
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        var refreshedAfterUnauthorized = false

        while true {
            var request = originalRequest
            let token = try await tokenProvider.accessToken(for: configuration)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            do {
                let result = try await transport.data(for: request)

                if result.1.statusCode == 401, !refreshedAfterUnauthorized {
                    refreshedAfterUnauthorized = true
                    await tokenProvider.invalidateAccessToken(for: configuration)
                    continue
                }

                if shouldRetry(status: result.1.statusCode), attempt < 4 {
                    attempt += 1
                    try await sleep(seconds: retryDelay(response: result.1, attempt: attempt))
                    continue
                }
                return result
            } catch {
                guard attempt < 4 else { throw error }
                attempt += 1
                try await sleep(seconds: min(1 << attempt, 8))
            }
        }
    }

    private func unauthenticatedUploadData(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            do {
                let result = try await transport.data(for: request)
                if shouldRetry(status: result.1.statusCode), attempt < 4 {
                    attempt += 1
                    try await sleep(seconds: retryDelay(response: result.1, attempt: attempt))
                    continue
                }
                return result
            } catch {
                guard attempt < 4 else { throw error }
                attempt += 1
                try await sleep(seconds: min(1 << attempt, 8))
            }
        }
    }

    private func deleteDraftBestEffort(
        configuration: MicrosoftGraphConfiguration,
        messageID: String
    ) async {
        guard let url = try? graphURL(["me", "messages", messageID]) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        _ = try? await authorizedData(for: request, configuration: configuration)
    }

    private func graphURL(
        _ segments: [String],
        queryItems: [URLQueryItem] = []
    ) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "graph.microsoft.com"
        components.percentEncodedPath = "/v1.0/" + segments.map(encodePathSegment).joined(separator: "/")
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw SafeMailError.invalidServerResponse("Microsoft Graph URL 생성 실패")
        }
        return url
    }

    private func encodePathSegment(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw SafeMailError.invalidServerResponse(error.localizedDescription)
        }
    }

    private func graphError(data: Data, status: Int) -> SafeMailError {
        if let envelope = try? JSONDecoder().decode(GraphErrorEnvelope.self, from: data) {
            let code = envelope.error.code ?? "GraphError"
            let message = envelope.error.message ?? "요청 실패"
            return .graphRequestFailed(status: status, message: "\(code): \(message)")
        }
        let message = String(data: data, encoding: .utf8) ?? "응답 본문 없음"
        return .graphRequestFailed(status: status, message: message)
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
