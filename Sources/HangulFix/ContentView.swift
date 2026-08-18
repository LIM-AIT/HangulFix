import AppKit
import HangulFixCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var viewModel = HangulFixViewModel()
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            VStack(spacing: 16) {
                dropZone

                if !viewModel.selectedURLs.isEmpty {
                    selectionSummary
                }

                preview
            }
            .padding(20)

            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            consumeFinderServiceSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: FinderServiceBridge.didReceiveURLs)) { _ in
            consumeFinderServiceSelection()
        }
        .onChange(of: viewModel.isBusy) { _, isBusy in
            if !isBusy {
                consumeFinderServiceSelection()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "character.cursor.ibeam")
                .font(.system(size: 28, weight: .semibold))
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 2) {
                Text("HangulFix")
                    .font(.title2.bold())
                Text("Mac 한글 파일명을 Windows 호환 NFC 형식으로 변환")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !viewModel.selectedURLs.isEmpty || viewModel.lastSuccessCount > 0 || !viewModel.lastFailures.isEmpty {
                Button("초기화") {
                    viewModel.clear()
                }
                .disabled(viewModel.isBusy)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: isDropTargeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 34))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)

            Text("파일 또는 폴더를 여기에 놓으세요")
                .font(.headline)

            Text("하위 폴더까지 검사하며 파일 내용은 변경하지 않습니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("파일/폴더 선택") {
                openPanel()
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isBusy)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.06))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                )
        }
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isDropTargeted,
            perform: handleDrop(providers:)
        )
    }

    private var selectionSummary: some View {
        HStack {
            Label("선택 항목 \(viewModel.selectedURLs.count)개", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                viewModel.refreshPreview()
            } label: {
                Label("다시 검사", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .font(.caption)
            .disabled(viewModel.isBusy)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if viewModel.isBusy && viewModel.candidates.isEmpty {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Spacer()
        } else if !viewModel.lastFailures.isEmpty {
            failurePreview
        } else if viewModel.lastSuccessCount > 0 {
            ContentUnavailableView(
                "변환 완료",
                systemImage: "checkmark.circle.fill",
                description: Text("\(viewModel.lastSuccessCount)개의 이름이 NFC로 저장된 것을 확인했습니다.")
            )
            .frame(maxHeight: .infinity)
        } else if viewModel.candidates.isEmpty {
            ContentUnavailableView(
                "변환 대상 없음",
                systemImage: "textformat.abc",
                description: Text("NFD 형식의 한글 파일/폴더가 발견되면 여기에 표시됩니다.")
            )
            .frame(maxHeight: .infinity)
        } else {
            candidatePreview
        }
    }

    private var candidatePreview: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.candidates) { candidate in
                    CandidateRow(candidate: candidate)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                    Divider()
                }
            }
        }
        .background(Color.secondary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(0.12))
        }
    }

    private var failurePreview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Label("변환하지 못한 항목", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)

                ForEach(Array(viewModel.lastFailures.enumerated()), id: \.offset) { _, failure in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(failure.candidate.sourceName)
                            .fontWeight(.medium)
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if viewModel.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Image(systemName: footerIcon)
                .foregroundStyle(footerIconColor)

            Text(viewModel.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer()

            if !viewModel.candidates.isEmpty {
                Text("\(viewModel.candidates.count)개")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Button("NFC로 변환") {
                viewModel.execute()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!viewModel.canExecute)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var footerIcon: String {
        if !viewModel.lastFailures.isEmpty || viewModel.blockedCount > 0 {
            return "exclamationmark.triangle.fill"
        }
        if viewModel.lastSuccessCount > 0 {
            return "checkmark.circle.fill"
        }
        return "info.circle"
    }

    private var footerIconColor: Color {
        if !viewModel.lastFailures.isEmpty || viewModel.blockedCount > 0 {
            return .orange
        }
        if viewModel.lastSuccessCount > 0 {
            return .green
        }
        return .secondary
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.title = "변환할 파일 또는 폴더 선택"
        panel.prompt = "선택"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true

        if panel.runModal() == .OK {
            viewModel.addURLs(panel.urls)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !viewModel.isBusy else { return false }

        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?

                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsURL = item as? NSURL {
                    url = nsURL as URL
                } else if let string = item as? String {
                    url = URL(string: string)
                } else {
                    url = nil
                }

                guard let url, url.isFileURL else { return }
                Task { @MainActor in
                    viewModel.addURLs([url])
                }
            }
        }

        return true
    }

    private func consumeFinderServiceSelection() {
        guard !viewModel.isBusy else { return }

        let urls = FinderServiceBridge.shared.consumePendingURLs()
        guard !urls.isEmpty else { return }
        viewModel.replaceURLs(urls)
    }
}

private struct CandidateRow: View {
    let candidate: RenameCandidate

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: candidate.kind.systemImage)
                .frame(width: 22)
                .foregroundStyle(candidate.kind == .directory ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(candidate.sourceName)
                        .lineLimit(1)

                    Text("NFD")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())

                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Text(candidate.targetName)
                        .lineLimit(1)
                        .fontWeight(.medium)

                    Text("NFC")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }

                Text(candidate.parentPath)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let issue = candidate.issue {
                    Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)
        }
    }
}
