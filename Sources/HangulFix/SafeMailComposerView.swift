import AppKit
import HangulFixMail
import SwiftUI

struct SafeMailComposerView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel = SafeMailComposerViewModel()

    @AppStorage("safeMail.clientID") private var clientID = ""
    @AppStorage("safeMail.tenant") private var tenant = "organizations"
    @AppStorage("safeMail.lastRecipients") private var recipients = ""

    @State private var subject = ""
    @State private var bodyText = ""

    let attachmentPaths: [String]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    attachmentSection
                    connectionSection
                    messageSection
                    resultSection
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(minWidth: 660, minHeight: 640)
        .onAppear {
            viewModel.refreshSession(clientID: clientID, tenant: tenant)
        }
        .onChange(of: clientID) { _, _ in
            viewModel.refreshSession(clientID: clientID, tenant: tenant)
        }
        .onChange(of: tenant) { _, _ in
            viewModel.refreshSession(clientID: clientID, tenant: tenant)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text("Outlook 안전 첨부")
                    .font(.title2.bold())
                Text("ZIP 없이 원래 한글 파일명을 유지한 Outlook 초안을 생성하고 서버 저장 이름까지 검증합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("닫기") { dismiss() }
                .disabled(viewModel.isBusy)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var attachmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("안전 첨부 파일", systemImage: "paperclip")
                .font(.headline)

            ForEach(attachmentPaths, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(systemName: "doc")
                        .foregroundStyle(.secondary)
                    Text(rawLeafName(path))
                        .lineLimit(1)
                    Spacer()
                    Text("NFC 재검증")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                .padding(9)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }

            Text("초안 생성 직전에 실제 APFS 파일명, NFC 여부, Windows 파일명 규칙을 다시 검사합니다. Microsoft 365에 저장된 첨부 이름이 한 글자라도 다르면 초안을 성공으로 처리하지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Microsoft 연결", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                Spacer()
                if viewModel.isSignedIn {
                    Label("로그인됨", systemImage: "checkmark.circle.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.green)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Client ID")
                        .foregroundStyle(.secondary)
                    TextField("Microsoft Entra Application (client) ID", text: $clientID)
                        .textFieldStyle(.roundedBorder)
                }

                GridRow {
                    Text("Tenant")
                        .foregroundStyle(.secondary)
                    TextField("organizations 또는 Tenant ID", text: $tenant)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Text("Entra 앱은 Public client flow와 Microsoft Graph delegated Mail.ReadWrite 권한이 필요합니다. Client secret은 HangulFix에 저장하지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if viewModel.isSignedIn {
                    Button("로그아웃") {
                        viewModel.signOut(clientID: clientID, tenant: tenant)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        viewModel.startSignIn(clientID: clientID, tenant: tenant)
                    } label: {
                        Label("Microsoft 로그인", systemImage: "person.badge.key")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.isBusy || viewModel.isWaitingForSignIn || clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if let prompt = viewModel.devicePrompt {
                VStack(alignment: .leading, spacing: 8) {
                    Text("로그인 코드")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(prompt.userCode)
                        .font(.system(.title3, design: .monospaced).bold())
                        .textSelection(.enabled)

                    HStack {
                        Button {
                            NSWorkspace.shared.open(prompt.verificationURI)
                        } label: {
                            Label("Microsoft 로그인 페이지 열기", systemImage: "safari")
                        }
                        .buttonStyle(.borderedProminent)

                        if viewModel.isWaitingForSignIn {
                            ProgressView()
                                .controlSize(.small)
                            Text("로그인 완료 대기 중")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("브라우저에서 위 코드를 입력하면 HangulFix가 로그인 완료를 자동 확인합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("메일 초안", systemImage: "square.and.pencil")
                .font(.headline)

            TextField("받는 사람 (여러 명은 ; 또는 , 로 구분)", text: $recipients)
                .textFieldStyle(.roundedBorder)

            TextField("제목", text: $subject)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $bodyText)
                .font(.body)
                .frame(minHeight: 100)
                .padding(6)
                .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.18))
                }
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        if let error = viewModel.errorText {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }

        if let result = viewModel.draftResult {
            VStack(alignment: .leading, spacing: 10) {
                Label("서버 검증 완료", systemImage: "checkmark.shield.fill")
                    .font(.headline)
                    .foregroundStyle(.green)

                Text("Microsoft 365 초안에 저장된 첨부 파일명이 HangulFix가 확인한 NFC 이름과 byte-for-byte 일치합니다.")
                    .font(.callout)

                ForEach(result.verifiedAttachmentNames, id: \.self) { name in
                    Label(name, systemImage: "checkmark.circle")
                        .font(.caption)
                }

                if let webLink = result.webLink {
                    Button {
                        NSWorkspace.shared.open(webLink)
                    } label: {
                        Label("Outlook 초안 열기", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        openOutlookApplication()
                    } label: {
                        Label("Outlook 열기", systemImage: "envelope")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            .background(Color.green.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if viewModel.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Text(viewModel.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer()

            Button {
                viewModel.createDraft(
                    clientID: clientID,
                    tenant: tenant,
                    recipientsText: recipients,
                    subject: subject,
                    body: bodyText,
                    attachmentPaths: attachmentPaths
                )
            } label: {
                Label("안전한 Outlook 초안 만들기", systemImage: "envelope.badge.shield.half.filled")
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                viewModel.isBusy
                    || !viewModel.isSignedIn
                    || recipients.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || attachmentPaths.isEmpty
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func rawLeafName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    private func openOutlookApplication() {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.Outlook") else {
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
    }
}
