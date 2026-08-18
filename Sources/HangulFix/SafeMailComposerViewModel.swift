import Foundation
import HangulFixMail

@MainActor
final class SafeMailComposerViewModel: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var isWaitingForSignIn = false
    @Published private(set) var isSignedIn = false
    @Published private(set) var devicePrompt: DeviceCodePrompt?
    @Published private(set) var errorText: String?
    @Published private(set) var draftResult: SafeMailDraftResult?
    @Published private(set) var statusText = "Microsoft 연결 설정 후 안전한 Outlook 초안을 만들 수 있습니다."

    private let authenticator: MicrosoftDeviceCodeAuthenticator
    private let mailService: MicrosoftGraphMailService
    private var signInTask: Task<Void, Never>?

    init() {
        let authenticator = MicrosoftDeviceCodeAuthenticator()
        self.authenticator = authenticator
        self.mailService = MicrosoftGraphMailService(tokenProvider: authenticator)
    }

    deinit {
        signInTask?.cancel()
    }

    func refreshSession(clientID: String, tenant: String) {
        let configuration = MicrosoftGraphConfiguration(clientID: clientID, tenant: tenant)
        guard configuration.isValid else {
            isSignedIn = false
            return
        }

        Task {
            isSignedIn = await authenticator.hasSavedSession(for: configuration)
            if isSignedIn {
                statusText = "Microsoft 로그인 정보가 준비되었습니다."
            }
        }
    }

    func startSignIn(clientID: String, tenant: String) {
        let configuration = MicrosoftGraphConfiguration(clientID: clientID, tenant: tenant)
        guard configuration.isValid else {
            errorText = SafeMailError.invalidConfiguration.localizedDescription
            return
        }

        signInTask?.cancel()
        errorText = nil
        draftResult = nil
        devicePrompt = nil
        isSignedIn = false
        isWaitingForSignIn = false
        isBusy = true
        statusText = "Microsoft 로그인 코드를 요청하는 중…"

        signInTask = Task {
            do {
                let prompt = try await authenticator.beginSignIn(configuration: configuration)
                guard !Task.isCancelled else { return }

                devicePrompt = prompt
                isBusy = false
                isWaitingForSignIn = true
                statusText = "브라우저에서 Microsoft 로그인과 코드 입력을 완료해 주세요."

                try await authenticator.completeSignIn(
                    configuration: configuration,
                    prompt: prompt
                )
                guard !Task.isCancelled else { return }

                isWaitingForSignIn = false
                isSignedIn = true
                devicePrompt = nil
                statusText = "Microsoft 로그인이 완료되었습니다."
            } catch is CancellationError {
                isBusy = false
                isWaitingForSignIn = false
            } catch {
                isBusy = false
                isWaitingForSignIn = false
                isSignedIn = false
                errorText = error.localizedDescription
                statusText = "Microsoft 로그인에 실패했습니다."
            }
        }
    }

    func signOut(clientID: String, tenant: String) {
        let configuration = MicrosoftGraphConfiguration(clientID: clientID, tenant: tenant)
        signInTask?.cancel()
        signInTask = nil
        isBusy = true

        Task {
            do {
                try await authenticator.signOut(configuration: configuration)
                isSignedIn = false
                isWaitingForSignIn = false
                devicePrompt = nil
                draftResult = nil
                errorText = nil
                statusText = "Microsoft 로그아웃이 완료되었습니다."
            } catch {
                errorText = error.localizedDescription
            }
            isBusy = false
        }
    }

    func createDraft(
        clientID: String,
        tenant: String,
        recipientsText: String,
        subject: String,
        body: String,
        attachmentPaths: [String]
    ) {
        guard !isBusy, isSignedIn else { return }

        let configuration = MicrosoftGraphConfiguration(clientID: clientID, tenant: tenant)
        let recipients = recipientsText
            .split(whereSeparator: { $0 == ";" || $0 == "," || $0 == "\n" })
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        isBusy = true
        errorText = nil
        draftResult = nil
        statusText = "Outlook 초안을 만들고 첨부 파일명을 서버에서 재검증하는 중…"

        Task {
            do {
                let result = try await mailService.createVerifiedDraft(
                    configuration: configuration,
                    request: SafeMailDraftRequest(
                        recipients: recipients,
                        subject: subject,
                        body: body,
                        attachmentPaths: attachmentPaths
                    )
                )
                draftResult = result
                statusText = "완료: Outlook 초안에 저장된 첨부 파일명이 NFC와 정확히 일치합니다."
            } catch SafeMailError.signInRequired {
                isSignedIn = false
                errorText = SafeMailError.signInRequired.localizedDescription
                statusText = "Microsoft 로그인이 다시 필요합니다."
            } catch {
                errorText = error.localizedDescription
                statusText = "안전 메일 초안 생성에 실패했습니다. 검증되지 않은 초안은 자동 삭제합니다."
            }
            isBusy = false
        }
    }
}
