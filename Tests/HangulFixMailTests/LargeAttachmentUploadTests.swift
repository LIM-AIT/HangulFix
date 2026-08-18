import Darwin
import Foundation
import XCTest
@testable import HangulFixMail

final class LargeAttachmentUploadTests: XCTestCase {
    func testLargeAttachmentUsesUploadSessionWithoutAuthorizationOnChunkPUTs() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HangulFixLargeMail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let name = "대용량 자료.bin".precomposedStringWithCanonicalMapping
        let path = root.path + "/" + name
        let descriptor = path.withCString { pointer in
            Darwin.creat(pointer, mode_t(S_IRUSR | S_IWUSR))
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        Darwin.close(descriptor)

        let size = Int64(3 * 1_048_576 + 1)
        XCTAssertEqual(path.withCString { Darwin.truncate($0, off_t(size)) }, 0)

        let transport = LargeScriptedTransport([
            .json(status: 201, object: ["id": "large-draft"]),
            .json(status: 201, object: [
                "uploadUrl": "https://outlook.office.com/upload/session-token",
                "nextExpectedRanges": ["0-"]
            ]),
            .empty(status: 200),
            .empty(status: 201),
            .json(status: 200, object: [
                "value": [[
                    "id": "large-att",
                    "name": name,
                    "size": size
                ]]
            ])
        ])

        let service = MicrosoftGraphMailService(
            transport: transport,
            tokenProvider: LargeStaticTokenProvider()
        )

        let result = try await service.createVerifiedDraft(
            configuration: MicrosoftGraphConfiguration(clientID: "client-id"),
            request: SafeMailDraftRequest(
                recipients: ["receiver@example.com"],
                subject: "large",
                body: "",
                attachmentPaths: [path]
            )
        )

        XCTAssertEqual(result.verifiedAttachmentNames, [name])

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 5)
        XCTAssertTrue(requests[1].url?.absoluteString.contains("createUploadSession") == true)

        let puts = requests.filter { $0.httpMethod == "PUT" }
        XCTAssertEqual(puts.count, 2)
        XCTAssertNil(puts[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(puts[1].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(puts[0].value(forHTTPHeaderField: "Content-Range"), "bytes 0-2097151/3145729")
        XCTAssertEqual(puts[1].value(forHTTPHeaderField: "Content-Range"), "bytes 2097152-3145728/3145729")
    }
}

private struct LargeStaticTokenProvider: MicrosoftAccessTokenProviding {
    func accessToken(for configuration: MicrosoftGraphConfiguration) async throws -> String {
        "test-access-token"
    }

    func invalidateAccessToken(for configuration: MicrosoftGraphConfiguration) async {}
}

private actor LargeScriptedTransport: HTTPTransport {
    struct Response: Sendable {
        let status: Int
        let data: Data
        let headers: [String: String]

        static func json(status: Int, object: Any) -> Response {
            Response(
                status: status,
                data: try! JSONSerialization.data(withJSONObject: object),
                headers: ["Content-Type": "application/json"]
            )
        }

        static func empty(status: Int) -> Response {
            Response(status: status, data: Data(), headers: [:])
        }
    }

    private var responses: [Response]
    private var requests: [URLRequest] = []

    init(_ responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw NSError(domain: "LargeScriptedTransport", code: 1)
        }
        let scripted = responses.removeFirst()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: scripted.status,
            httpVersion: "HTTP/1.1",
            headerFields: scripted.headers
        )!
        return (scripted.data, response)
    }

    func capturedRequests() -> [URLRequest] {
        requests
    }
}
