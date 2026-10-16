import SwiftUI
import PencilKit

enum EditorTool: String, CaseIterable, Identifiable {
    case pen, highlighter, eraser, lasso, text, mask, laser
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pen: return "펜"
        case .highlighter: return "형광펜"
        case .eraser: return "지우개"
        case .lasso: return "올가미"
        case .text: return "텍스트"
        case .mask: return "가림막"
        case .laser: return "레이저"
        }
    }
    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        case .text: return "textformat"
        case .mask: return "rectangle.inset.filled"
        case .laser: return "cursorarrow.rays"
        }
    }
    var isInking: Bool { self == .pen || self == .highlighter || self == .eraser }
}

enum PenKind: String, CaseIterable, Identifiable {
    case pen, fountain, pencil, monoline
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pen: return "볼펜"
        case .fountain: return "만년필"
        case .pencil: return "연필"
        case .monoline: return "모노라인"
        }
    }
    var inkType: PKInkingTool.InkType {
        switch self {
        case .pen: return .pen
        case .fountain: return .fountainPen
        case .pencil: return .pencil
        case .monoline: return .monoline
        }
    }
}

enum EraserKind: String, CaseIterable, Identifiable {
    case stroke, pixel
    var id: String { rawValue }
    var title: String { self == .stroke ? "획 지우개" : "부분 지우개" }
}

struct TextRequest: Identifiable {
    let id = UUID()
    let point: CGPoint
    let existing: PageText?
}

/// 노트 사이를 오가며 복사·붙여넣기 할 수 있는 앱 내부 클립보드
final class EditorClipboard: ObservableObject {
    static let shared = EditorClipboard()
    struct ImageItem { var image: PageImage; var data: Data }
    @Published private(set) var strokes: [PKStroke] = []
    private(set) var images: [ImageItem] = []
    private(set) var texts: [PageText] = []
    var isEmpty: Bool { strokes.isEmpty && images.isEmpty && texts.isEmpty }

    func set(strokes: [PKStroke], images: [ImageItem], texts: [PageText]) {
        self.images = images
        self.texts = texts
        self.strokes = strokes
        objectWillChange.send()
    }
}

@MainActor
final class EditorModel: ObservableObject {
    let doc: NotebookDocument
    let audio: AudioService
    let undoManager = UndoManager()
    weak var pageView: PageEditorView?

    @Published var pageIndex: Int {
        didSet {
            guard oldValue != pageIndex else { return }
            if let old = doc.notebook.pages[safe: oldValue]?.id { indexIfEdited(old) }
            doc.setLastPageIndex(pageIndex)
        }
    }

    @Published var tool: EditorTool = .pen {
        didSet { if oldValue != tool && oldValue != .eraser { previousTool = oldValue } }
    }
    private(set) var previousTool: EditorTool = .pen

    @Published var penKind: PenKind = .pen { didSet { saveToolPrefs() } }
    @Published var penColorHex = "#1C1C1EFF" { didSet { saveToolPrefs() } }
    @Published var penWidth: CGFloat = 2.5 { didSet { saveToolPrefs() } }
    @Published var highlighterColorHex = "#FFE066FF" { didSet { saveToolPrefs() } }
    @Published var highlighterWidth: CGFloat = 16 { didSet { saveToolPrefs() } }
    @Published var eraserKind: EraserKind = .stroke { didSet { saveToolPrefs() } }
    @Published var eraserWidth: CGFloat = 20
    @Published var maskColorHex = "#F28B82FF"

    @Published var isReadingMode = false
    @Published var showSidebar = false
    @Published var revealAllMasks = false
    @Published var syncPlayback = true
    @Published var hasSelection = false
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var textRequest: TextRequest?
    @Published var toast: String?

    private var editedPages: Set<UUID> = []
    private var studyStart: Date?
    private var studyTimer: Timer?
    private var undoObservers: [NSObjectProtocol] = []
    private var toastTask: Task<Void, Never>?

    init(doc: NotebookDocument, initialPage: Int?) {
        self.doc = doc
        self.audio = AudioService(doc: doc)
        let idx = initialPage ?? doc.notebook.lastPageIndex
        self.pageIndex = max(0, min(idx, doc.notebook.pages.count - 1))
        loadToolPrefs()
        undoManager.levelsOfUndo = 100
        let names: [Notification.Name] = [.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange,
                                          .NSUndoManagerDidRedoChange, .NSUndoManagerCheckpoint]
        for name in names {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshUndoState() }
            })
        }
        startStudy()
        LibraryStore.shared.markOpened(doc.id)
    }

    deinit {
        for o in undoObservers { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: 페이지

    var pageCount: Int { doc.notebook.pages.count }

    var currentPage: Page {
        let pages = doc.notebook.pages
        return pages[max(0, min(pageIndex, pages.count - 1))]
    }

    func goToPage(_ i: Int) {
        let target = max(0, min(i, pageCount - 1))
        guard target != pageIndex else { return }
        pageView?.commitSelection()
        pageIndex = target
    }

    func nextPage() { goToPage(pageIndex + 1) }
    func previousPage() { goToPage(pageIndex - 1) }

    func addPage(after index: Int, background: PageBackground? = nil, size: CGSize? = nil) {
        let ref = doc.notebook.pages[safe: index] ?? currentPage
        var bg = background ?? ref.background
        if background == nil, case .pdf = bg { bg = .paper(style: .blank, color: .white) }
        let page = Page(size: size ?? ref.size, background: bg)
        let at = doc.insertPage(page, at: index + 1)
        goToPage(at)
    }

    func duplicatePage(at index: Int) {
        if let at = doc.duplicatePage(at: index) { goToPage(at) }
    }

    func deletePage(at index: Int) {
        pageView?.commitSelection()
        doc.deletePages(at: IndexSet(integer: index))
        pageIndex = max(0, min(pageIndex, pageCount - 1))
        objectWillChange.send()
    }

    func insertPDF(_ url: URL) {
        if let at = doc.insertPDF(from: url, at: pageIndex + 1) {
            goToPage(at)
            showToast("PDF 페이지를 삽입했어요")
        } else {
            showToast("PDF를 열 수 없어요")
        }
    }

    func pageEdited(_ pageId: UUID) { editedPages.insert(pageId) }

    private func indexIfEdited(_ pageId: UUID) {
        guard editedPages.remove(pageId) != nil else { return }
        SearchIndexer.shared.indexInk(doc: doc, pageId: pageId)
    }

    // MARK: 도구

    var pkTool: PKTool? {
        switch tool {
        case .pen:
            return PKInkingTool(penKind.inkType, color: UIColor(hex: penColorHex), width: penWidth)
        case .highlighter:
            return PKInkingTool(.marker, color: UIColor(hex: highlighterColorHex), width: highlighterWidth)
        case .eraser:
            return eraserKind == .stroke ? PKEraserTool(.vector) : PKEraserTool(.bitmap, width: eraserWidth)
        default:
            return nil
        }
    }

    /// 도형·붙여넣기에 쓸 잉크
    var shapeInk: (ink: PKInk, width: CGFloat) {
        if tool == .highlighter {
            return (PKInk(.marker, color: UIColor(hex: highlighterColorHex)), highlighterWidth)
        }
        return (PKInk(penKind.inkType, color: UIColor(hex: penColorHex)), max(penWidth, 1.5))
    }

    func toggleEraser() { tool = tool == .eraser ? previousTool : .eraser }
    func switchToPreviousTool() { tool = previousTool }

    private func saveToolPrefs() {
        let d = UserDefaults.standard
        d.set(penKind.rawValue, forKey: "tool.penKind")
        d.set(penColorHex, forKey: "tool.penColor")
        d.set(Double(penWidth), forKey: "tool.penWidth")
        d.set(highlighterColorHex, forKey: "tool.hlColor")
        d.set(Double(highlighterWidth), forKey: "tool.hlWidth")
        d.set(eraserKind.rawValue, forKey: "tool.eraser")
    }

    private func loadToolPrefs() {
        let d = UserDefaults.standard
        if let k = PenKind(rawValue: d.string(forKey: "tool.penKind") ?? "") { penKind = k }
        if let c = d.string(forKey: "tool.penColor") { penColorHex = c }
        if d.double(forKey: "tool.penWidth") > 0 { penWidth = CGFloat(d.double(forKey: "tool.penWidth")) }
        if let c = d.string(forKey: "tool.hlColor") { highlighterColorHex = c }
        if d.double(forKey: "tool.hlWidth") > 0 { highlighterWidth = CGFloat(d.double(forKey: "tool.hlWidth")) }
        if let e = EraserKind(rawValue: d.string(forKey: "tool.eraser") ?? "") { eraserKind = e }
    }

    // MARK: 실행 취소

    func undo() {
        pageView?.commitSelection()
        if undoManager.canUndo { undoManager.undo() }
        refreshUndoState()
    }

    func redo() {
        if undoManager.canRedo { undoManager.redo() }
        refreshUndoState()
    }

    func refreshUndoState() {
        if canUndo != undoManager.canUndo { canUndo = undoManager.canUndo }
        if canRedo != undoManager.canRedo { canRedo = undoManager.canRedo }
    }

    // MARK: 정답·가림막

    func toggleAnswers() {
        guard doc.hasAnswerLayer else {
            showToast("레이어 패널에서 정답 레이어(★)를 지정하세요")
            return
        }
        doc.setAnswersHidden(!doc.answersHidden)
        showToast(doc.answersHidden ? "정답 레이어를 숨겼어요" : "정답 레이어를 표시해요")
    }

    // MARK: 텍스트

    func requestText(at point: CGPoint, existing: PageText?) {
        textRequest = TextRequest(point: point, existing: existing)
    }

    func commitText(_ request: TextRequest, text: String, fontSize: CGFloat, colorHex: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if var t = request.existing {
            if trimmed.isEmpty {
                pageView?.removeText(t.id)
            } else {
                t.text = text
                t.fontSize = fontSize
                t.colorHex = colorHex
                pageView?.upsertText(t)
            }
        } else if !trimmed.isEmpty {
            let t = PageText(text: text, origin: request.point, fontSize: fontSize, colorHex: colorHex,
                             layerId: doc.notebook.activeLayerId)
            pageView?.upsertText(t)
        }
    }

    // MARK: 오답노트

    func addWrongAnswer(pageId: UUID, rect: CGRect) {
        guard let page = doc.page(id: pageId) else { return }
        let r = rect.insetBy(dx: -12, dy: -12).intersection(page.bounds)
        guard !r.isNull, r.width > 8, r.height > 8 else { return }
        let question = PageRenderer.renderImage(doc: doc, page: page, scale: 2.5, region: r,
                                                options: RenderOptions(includeAnswers: false, forceAnswers: false, includeMasks: true))
        let answer = PageRenderer.renderImage(doc: doc, page: page, scale: 2.5, region: r,
                                              options: RenderOptions(includeAnswers: true, forceAnswers: true, includeMasks: false))
        let qName = "q-\(UUID().uuidString).jpg"
        let aName = "a-\(UUID().uuidString).jpg"
        Storage.ensureParent(Storage.wrongImage(qName))
        guard let qData = question.jpegData(compressionQuality: 0.9),
              (try? qData.write(to: Storage.wrongImage(qName))) != nil else { return }
        var answerFile: String?
        if let aData = answer.jpegData(compressionQuality: 0.9), (try? aData.write(to: Storage.wrongImage(aName))) != nil {
            answerFile = aName
        }
        let item = WrongAnswerItem(notebookId: doc.id, notebookTitle: doc.notebook.title, pageId: pageId, rect: r,
                                   questionFile: qName, answerFile: answerFile, folderId: doc.notebook.folderId)
        LibraryStore.shared.addWrongAnswer(item)
        showToast("오답노트에 추가했어요")
    }

    // MARK: 녹음 동기화

    func seekRecording(toStrokeDate date: Date) {
        if !audio.playMoment(date) { showToast("이 필기 시점의 녹음이 없어요") }
    }

    // MARK: 내보내기

    func exportPDF(currentOnly: Bool, includeAnswers: Bool, includeMasks: Bool) -> URL? {
        pageView?.commitSelection()
        let indices = currentOnly ? [pageIndex] : Array(0..<pageCount)
        return PageRenderer.exportPDF(doc: doc, pageIndices: indices,
                                      options: RenderOptions(includeAnswers: includeAnswers, forceAnswers: false,
                                                             includeMasks: includeMasks))
    }

    func exportCurrentPageImage() -> URL? {
        pageView?.commitSelection()
        let img = PageRenderer.renderImage(doc: doc, page: currentPage, scale: 3, options: RenderOptions())
        let name = doc.notebook.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(pageIndex + 1).png")
        guard let data = img.pngData(), (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    // MARK: 공부 시간

    private func startStudy() {
        studyStart = Date()
        studyTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.flushStudy(restart: true) }
        }
    }

    private func flushStudy(restart: Bool) {
        guard let start = studyStart else {
            if restart { studyStart = Date() }
            return
        }
        let secs = Date().timeIntervalSince(start)
        if let f = doc.notebook.folderId { LibraryStore.shared.addStudyTime(folderId: f, seconds: secs) }
        studyStart = restart ? Date() : nil
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        if phase == .active {
            if studyStart == nil { studyStart = Date() }
        } else {
            flushStudy(restart: false)
            pageView?.commitSelection()
            doc.saveNow()
        }
    }

    func close() {
        flushStudy(restart: false)
        studyTimer?.invalidate()
        studyTimer = nil
        pageView?.commitSelection()
        if audio.isRecording { audio.stopRecording() }
        audio.stopPlayback()
        indexIfEdited(currentPage.id)
        doc.saveNow()
    }

    // MARK: 알림

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }
}
