import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var backups: [BackupService.BackupInfo] = []
    @State private var restoreTarget: URL?
    @State private var showFolderImporter = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("필기") {
                    Toggle("손가락으로 필기", isOn: $settings.fingerDrawing)
                    Toggle("도형 자동 보정", isOn: $settings.shapeSnap)
                    Toggle("스와이프로 페이지 넘기기", isOn: $settings.swipeToTurnPage)
                    Picker("Apple Pencil 더블탭", selection: $settings.pencilDoubleTap) {
                        ForEach(PencilDoubleTapAction.allCases) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    Toggle("손글씨 검색 색인", isOn: $settings.handwritingIndexing)
                } header: {
                    Text("검색")
                } footer: {
                    Text("페이지를 넘길 때 기기 안에서 손글씨를 인식해 검색할 수 있게 합니다.")
                }
                Section {
                    Toggle("하루 한 번 자동 백업", isOn: $settings.autoBackup)
                    Button("지금 백업하기") {
                        library.saveNow()
                        NotebookDocument.flushAll()
                        NotebookDocument.ioQueue.async {
                            let ok = (try? BackupService.createBackup()) != nil
                            DispatchQueue.main.async {
                                message = ok ? "백업했어요. 파일 앱 › 나의 iPad › NoteLab › Backups 에서 볼 수 있어요." : "백업에 실패했어요."
                                reloadBackups()
                            }
                        }
                    }
                    Button("다른 위치의 백업 폴더에서 복원…") { showFolderImporter = true }
                } header: {
                    Text("백업")
                } footer: {
                    Text("백업은 파일 앱에서 보이는 폴더에 저장되므로 iCloud Drive나 컴퓨터로 복사해 둘 수 있어요. 자동 백업은 최근 5개를 보관합니다.")
                }
                if !backups.isEmpty {
                    Section("백업 목록") {
                        ForEach(backups) { b in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(b.name).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: b.size, countStyle: .file))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("복원") { restoreTarget = b.url }.buttonStyle(.bordered)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    BackupService.delete(b.url)
                                    reloadBackups()
                                } label: { Label("삭제", systemImage: "trash") }
                            }
                        }
                    }
                }
                Section("정보") {
                    LabeledContent("노트", value: "\(library.notebooks.count)개")
                    LabeledContent("오답", value: "\(library.wrongAnswers.count)개")
                    LabeledContent("버전", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
            .onAppear(perform: reloadBackups)
            .fileImporter(isPresented: $showFolderImporter, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result { restoreTarget = url }
            }
            .confirmationDialog("이 백업으로 복원할까요?", isPresented: Binding(get: { restoreTarget != nil },
                                                                     set: { if !$0 { restoreTarget = nil } }),
                                titleVisibility: .visible) {
                Button("복원", role: .destructive) {
                    guard let url = restoreTarget else { return }
                    do {
                        try BackupService.restore(from: url)
                        message = "복원했어요. 복원 전 상태는 '복원 전 백업'으로 남겨 두었어요."
                    } catch {
                        message = "복원 실패: \(error.localizedDescription)"
                    }
                    restoreTarget = nil
                    reloadBackups()
                }
            } message: {
                Text("현재 라이브러리는 자동으로 백업한 뒤 교체됩니다.")
            }
            .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("확인", role: .cancel) {}
            }
        }
    }

    private func reloadBackups() {
        backups = BackupService.listBackups()
    }
}
