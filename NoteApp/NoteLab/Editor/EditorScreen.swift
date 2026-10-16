import SwiftUI

struct OpenRequest: Identifiable {
    let id = UUID()
    let notebookId: UUID
    let pageIndex: Int?
}

/// 노트를 열어서 편집 화면을 띄운다 (못 열면 안내)
struct NotebookEditorLoader: View {
    let notebookId: UUID
    let pageIndex: Int?
    let onClose: () -> Void

    var body: some View {
        if let doc = NotebookDocument.open(notebookId) {
            EditorScreen(document: doc, initialPage: pageIndex, onClose: onClose)
        } else {
            VStack(spacing: 16) {
                ContentUnavailableView("노트를 열 수 없어요", systemImage: "exclamationmark.triangle",
                                       description: Text("파일이 삭제되었거나 손상되었습니다."))
                Button("닫기", action: onClose).buttonStyle(.borderedProminent)
            }
        }
    }
}

/// 별도 창(Stage Manager / Split View)에서 연 노트
struct NotebookWindowView: View {
    let notebookId: UUID
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        NotebookEditorLoader(notebookId: notebookId, pageIndex: nil) {
            dismissWindow()
        }
    }
}

struct EditorScreen: View {
    @StateObject private var model: EditorModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    let onClose: () -> Void

    init(document: NotebookDocument, initialPage: Int?, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: EditorModel(doc: document, initialPage: initialPage))
        self.onClose = onClose
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.isReadingMode {
                EditorTopBar(model: model, doc: model.doc, audio: model.audio, onClose: close)
                Divider()
                ToolOptionsBar(model: model)
                Divider()
            }
            HStack(spacing: 0) {
                if model.showSidebar && !model.isReadingMode {
                    PageSidebar(model: model, doc: model.doc)
                        .frame(width: 150)
                        .transition(.move(edge: .leading))
                    Divider()
                }
                ZStack(alignment: .bottom) {
                    PageEditorRepresentable(model: model, doc: model.doc, settings: settings)
                        .ignoresSafeArea(.container, edges: .bottom)
                    RecordingBar(model: model, audio: model.audio)
                        .padding(.bottom, 16)
                }
                .overlay(alignment: .topTrailing) {
                    if model.isReadingMode {
                        Button {
                            withAnimation { model.isReadingMode = false }
                        } label: {
                            Label("읽기 모드 끝내기", systemImage: "xmark")
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .padding(16)
                    }
                }
                .overlay(alignment: .top) {
                    if let toast = model.toast {
                        Text(toast)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.thinMaterial, in: Capsule())
                            .padding(.top, 12)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    PageIndicator(model: model)
                        .padding(16)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showSidebar)
        .animation(.easeInOut(duration: 0.2), value: model.isReadingMode)
        .animation(.easeInOut(duration: 0.2), value: model.toast)
        .sheet(item: $model.textRequest) { request in
            TextEditSheet(request: request) { text, size, color in
                model.commitText(request, text: text, fontSize: size, colorHex: color)
            }
        }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        .onDisappear { model.close() }
        .statusBarHidden(model.isReadingMode)
        .persistentSystemOverlays(model.isReadingMode ? .hidden : .automatic)
    }

    private func close() {
        model.close()
        onClose()
    }
}

struct PageEditorRepresentable: UIViewRepresentable {
    @ObservedObject var model: EditorModel
    @ObservedObject var doc: NotebookDocument
    @ObservedObject var settings: AppSettings

    func makeUIView(context: Context) -> PageEditorView {
        let v = PageEditorView(model: model)
        model.pageView = v
        return v
    }

    func updateUIView(_ uiView: PageEditorView, context: Context) {
        uiView.syncWithModel()
    }
}

/// 왼쪽 아래 페이지 번호 (탭하면 사이드바)
struct PageIndicator: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(spacing: 10) {
            Button { model.previousPage() } label: { Image(systemName: "chevron.left") }
                .disabled(model.pageIndex == 0)
            Button {
                model.showSidebar.toggle()
            } label: {
                Text("\(model.pageIndex + 1) / \(model.pageCount)")
                    .font(.footnote.monospacedDigit().weight(.semibold))
            }
            Button { model.nextPage() } label: { Image(systemName: "chevron.right") }
                .disabled(model.pageIndex >= model.pageCount - 1)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .opacity(0.9)
    }
}
