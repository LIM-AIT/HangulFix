import Foundation
import XCTest
@testable import HangulFixMail

final class MicrosoftGraphMailServiceTests: XCTestCase {
    func testCreatesDraftWithExactNFCNameAndVerifiesStoredAttachment() async throws {
        let fixture = try makeFixture(name: "K사번 채용 발령 인적정보.xlsx")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let transport = ScriptedTransport([
            .json(status: 201, object: [
                "id": "msg/1==",
                "webLink": "https://outlook.office.com/mail/deeplink/read/id/msg"
            ]),
            .json(status: 201, object: [
                "id": "att1",
                "name": fixture.name,
                "size": fixture.size
            ]),
            .json(status: 200, object: [
                "value": [[
                    "id": "att1",
                    "name": fixture.name,
                    "size": fixture.size
                ]]
            ])
        ])

        let service = MicrosoftGraphMailService(
            transport: transport,
            tokenProvider: StaticTokenProvider()
        )

        let result = try await service.createVerifiedDraft(
            configuration: MicrosoftGraphConfiguration(clientID: "client-id"),
            request: SafeMailDraftRequest(
                recipients: ["receiver@example.com"],
                subject: "테스트",
                body: "본문",
                attachmentPaths: [fixture.path]
            )
        )

        XCTAssertEqual(result.messageID, "msg/1==")
        XCTAssertEqual(result.verifiedAttachmentNames.count, 1)
        XCTAssertTrue(result.verifiedAttachmentNames[0].utf8.elementsEqual(fixture.name.utf8))

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[1].httpMethod, "POST")
        XCTAssertTrue(requests[1].url?.absoluteString.contains("msg%2F1%3D%3D/attachments") == true)
        XCTAssertEqual(requests[2].httpMethod, "GET")

        let body = try XCTUnwrap(requests[1].httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let sentName = try XCTUnwrap(json["name"] as? String)
        XCTAssertTrue(sentName.utf8.elementsEqual(fixture.name.utf8))
        XCTAssertFalse(FileNormalizerShim.needsNFCNormalization(sentName))
    }

    func testDeletesDraftWhenServerStoredNameIsCanonicallyDifferent() async throws {
        let fixture = try makeFixture(name: "한글 파일.xlsx")
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let nfd = fixture.name.decomposedStringWithCanonicalMapping
        XCTAssertFalse(nfd.utf8.elementsEqual(fixture.name.utf8))

        let transport = ScriptedTransport([
            .json(status: 201, object: ["id": "draft-1"]),
            .json(status: 201, object: [
                "id": "att1",
                "name": fixture.name,
                "size": fixture.size
            ]),
            .json(status: 200, object: [
                "value": [[
                    "id": "att1",
                    "name": nfd,
                    "size": fixture.size
                ]]
            ]),
            .empty(status: 204)
        ])

        let service = MicrosoftGraphMailService(
            transport: transport,
            tokenProvider: StaticTokenProvider()
        )

        do {
            _ = try await service.createVerifiedDraft(
                configuration: MicrosoftGraphConfiguration(clientID: "client-id"),
                request: SafeMailDraftRequest(
                    recipients: ["receiver@example.com"],
                    subject: "테스트",
                    body: "",
                    attachmentPaths: [fixture.path]
                )
            )
            XCTFail("Expected attachment verification to fail")
        } catch SafeMailError.attachmentVerificationFailed(let expected, let actual) {
            XCTAssertTrue(expected.utf8.elementsEqual(fixture.name.utf8))
            XCTAssertNotNil(actual)
            XCTAssertFalse(actual!.utf8.elementsEqual(expected.utf8))
        }

        let requests = await transport.capturedRequests()
        XCTAssertEqual(requests.last?.httpMethod, "DELETE")
        XCTAssertTrue(requests.last?.url?.absoluteString.contains("draft-1") == true)
    }

    private func makeFixture(name rawName: String) throws -> (root: URL, path: String, name: String, size: Int64) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HangulFixGraphMail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let name = rawName.precomposedStringWithCanonicalMapping
        let path = root.path + "/" + name
        let data = Data("graph-mail-fixture".utf8)
        try data.write(to: URL(fileURLWithPath: path))
        return (root, path, name, Int64(data.count))
    }
}

private struct StaticTokenProvider: MicrosoftAccessTokenProviding {
    func accessToken(for configuration: MicrosoftGraphConfiguration) async throws -> String {
        "test-access-token"
    }

    func invalidateAccessToken(for configuration: MicrosoftGraphConfiguration) async {}
}

private actor ScriptedTransport: HTTPTransport {
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
            throw NSError(domain: "ScriptedTransport", code: 1)
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

/// Keeps this test target independent of HangulFixCore's internal implementation details.
private enum FileNormalizerShim {
    static func needsNFCNormalization(_ name: String) -> Bool {
        !name.utf8.elementsEqual(name.precomposedStringWithCanonicalMapping.utf8)
    }
}
