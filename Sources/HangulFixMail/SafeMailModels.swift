import Foundation

public struct MicrosoftGraphConfiguration: Sendable, Equatable, Hashable {
    public let clientID: String
    public let tenant: String

    public init(clientID: String, tenant: String = "organizations") {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTenant = tenant.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tenant = trimmedTenant.isEmpty ? "organizations" : trimmedTenant
    }

    public var isValid: Bool {
        !clientID.isEmpty && !tenant.isEmpty
    }
}

public struct DeviceCodePrompt: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String
    public let verificationURI: URL
    public let message: String
    public let expiresIn: Int
    public let interval: Int

    public init(
        deviceCode: String,
        userCode: String,
        verificationURI: URL,
        message: String,
        expiresIn: Int,
        interval: Int
    ) {
        self.deviceCode = deviceCode
        self.userCode = userCode
        self.verificationURI = verificationURI
        self.message = message
        self.expiresIn = expiresIn
        self.interval = interval
    }
}

public struct SafeMailAttachment: Sendable, Equatable {
    public let path: String
    public let name: String
    public let size: Int64
    public let contentType: String

    public init(path: String, name: String, size: Int64, contentType: String) {
        self.path = path
        self.name = name
        self.size = size
        self.contentType = contentType
    }
}

public struct SafeMailDraftRequest: Sendable, Equatable {
    public let recipients: [String]
    public let subject: String
    public let body: String
    public let attachmentPaths: [String]

    public init(
        recipients: [String],
        subject: String,
        body: String,
        attachmentPaths: [String]
    ) {
        self.recipients = recipients
        self.subject = subject
        self.body = body
        self.attachmentPaths = attachmentPaths
    }
}

public struct SafeMailDraftResult: Sendable, Equatable {
    public let messageID: String
    public let webLink: URL?
    public let verifiedAttachmentNames: [String]

    public init(messageID: String, webLink: URL?, verifiedAttachmentNames: [String]) {
        self.messageID = messageID
        self.webLink = webLink
        self.verifiedAttachmentNames = verifiedAttachmentNames
    }
}

public enum SafeMailError: LocalizedError, Sendable {
    case invalidConfiguration
    case signInRequired
    case invalidRecipient(String)
    case noAttachments
    case attachmentMissing(String)
    case folderNotSupported(String)
    case symbolicLinkNotSupported(String)
    case attachmentNotNFC(String)
    case windowsIncompatibleName(name: String, reason: String)
    case attachmentTooLarge(name: String, size: Int64)
    case authenticationFailed(String)
    case authenticationDeclined
    case authenticationExpired
    case graphRequestFailed(status: Int, message: String)
    case invalidServerResponse(String)
    case attachmentVerificationFailed(expected: String, actual: String?)
    case attachmentCountMismatch(expected: Int, actual: Int)
    case uploadFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Microsoft Entra Client ID와 Tenant 설정을 확인해 주세요."
        case .signInRequired:
            return "Microsoft 계정 로그인이 필요합니다."
        case .invalidRecipient(let address):
            return "받는 사람 이메일 주소를 확인해 주세요: \(address)"
        case .noAttachments:
            return "안전 메일에 첨부할 파일이 없습니다."
        case .attachmentMissing(let path):
            return "첨부 파일을 찾을 수 없습니다: \(path)"
        case .folderNotSupported(let name):
            return "폴더는 메일에 직접 첨부할 수 없습니다: \(name)"
        case .symbolicLinkNotSupported(let name):
            return "심볼릭 링크는 안전 메일 첨부에서 지원하지 않습니다: \(name)"
        case .attachmentNotNFC(let name):
            return "첨부 파일명이 NFC가 아닙니다. 먼저 변환해 주세요: \(name)"
        case .windowsIncompatibleName(let name, let reason):
            return "Windows에서 사용할 수 없는 파일명입니다: \(name) (\(reason))"
        case .attachmentTooLarge(let name, let size):
            let mb = Double(size) / 1_048_576.0
            return String(format: "첨부 파일이 Microsoft Graph 150 MB 제한을 초과합니다: %@ (%.1f MB)", name, mb)
        case .authenticationFailed(let message):
            return "Microsoft 로그인 실패: \(message)"
        case .authenticationDeclined:
            return "Microsoft 로그인 요청이 취소되었습니다."
        case .authenticationExpired:
            return "Microsoft 로그인 코드가 만료되었습니다. 다시 로그인해 주세요."
        case .graphRequestFailed(let status, let message):
            return "Microsoft Graph 요청 실패 (HTTP \(status)): \(message)"
        case .invalidServerResponse(let message):
            return "Microsoft 응답을 확인할 수 없습니다: \(message)"
        case .attachmentVerificationFailed(let expected, let actual):
            if let actual {
                return "메일 서버에 저장된 첨부 파일명이 달라 안전 검증에 실패했습니다. 예상: \(expected), 실제: \(actual)"
            }
            return "메일 서버에서 첨부 파일을 찾지 못해 안전 검증에 실패했습니다: \(expected)"
        case .attachmentCountMismatch(let expected, let actual):
            return "메일 서버의 첨부 파일 개수가 예상과 다릅니다. 예상 \(expected)개, 실제 \(actual)개"
        case .uploadFailed(let message):
            return "첨부 파일 업로드 실패: \(message)"
        }
    }
}
