import SwiftUI
import PencilKit
import PDFKit

/// 열려 있는 노트 하나. 필기 데이터는 페이지·레이어 단위로 필요할 때만 읽고,
/// 바뀐 부분만 백그라운드 큐에서 저장한다 (큰 노트도 버벅이지 않도록).
@MainActor
final class NotebookDocument: ObservableObject {
    // MARK: 레지스트리 (여러 창에서 같은 노트를 열면 같은 인스턴스를 공유)

    private final class WeakBox { weak var doc: NotebookDocument?; init(_ d: NotebookDocument) { doc = d } }
    private static var registry: [UUID: WeakBox] = [:]
    nonisolated static let ioQueue = DispatchQueue(label: "notelab.io", qos: .utility)

    static func open(_ id: UUID) -> NotebookDocument? {
        if let d = registry[id]?.doc { return d }
        guard var nb = Storage.read(Notebook.self, from: Storage.notebookFile(id)) else { return nil }
        if nb.pages.isEmpty {
            nb.pages = [Page(size: PaperSize.a4Portrait.size, background: .paper(style: .blank, color: .white))]
        }
        if nb.layers.isEmpty {
            let l = LayerInfo(name: "필기 1")
            nb.layers = [l]
            nb.activeLayerId = l.id
        }
        if !nb.layers.contains(where: { $0.id == nb.activeLayerId }) { nb.activeLayerId = nb.layers[0].id }
        let d = NotebookDocument(notebook: nb)
        registry[id] = WeakBox(d)
        return d
    }

    static func existing(_ id: UUID) -> NotebookDocument? { registry[id]?.doc }

    static func flushAll() {
        for box in registry.values { box.doc?.saveNow() }
    }

    /// 삭제·복원 시: 저장하지 않고 닫는다
    static func discard(_ id: UUID) {
        registry[id]?.doc?.isDiscarded = true
        registry[id] = nil
    }

    static func discardAll() {
        for id in Array(registry.keys) { discard(id) }
    }

    // MARK: 상태

    @Published var notebook: Notebook
    var id: UUID { notebook.id }

    private struct InkKey: Hashable { let page: UUID; let layer: UUID }
    private var ink: [UUID: [UUID: PKDrawing]] = [:]
    private var accessOrder: [UUID] = []
    private var dirtyInk: Set<InkKey> = []
    private var notebookDirty = false
    private var saveTask: Task<Void, Never>?
    private var isDiscarded = false
    private let maxCachedPages = 12

    private init(notebook: Notebook) {
        self.notebook = notebook
    }

    // MARK: 필기 데이터

    func drawing(page: UUID, layer: UUID) -> PKDrawing {
        if let d = ink[page]?[layer] {
            touch(page)
            return d
        }
        var d = PKDrawing()
        if let data = try? Data(contentsOf: Storage.inkFile(id, page: page, layer: layer)),
           let loaded = try? PKDrawing(data: data) {
            d = loaded
        }
        ink[page, default: [:]][layer] = d
        touch(page)
        return d
    }

    func setDrawing(_ drawing: PKDrawing, page: UUID, layer: UUID) {
        ink[page, default: [:]][layer] = drawing
        dirtyInk.insert(InkKey(page: page, layer: layer))
        notebookDirty = true
        scheduleSave()
    }

    func hasInk(page: UUID) -> Bool {
        notebook.layers.contains { !drawing(page: page, layer: $0.id).strokes.isEmpty }
    }

    private func touch(_ page: UUID) {
        accessOrder.removeAll { $0 == page }
        accessOrder.append(page)
        guard accessOrder.count > maxCachedPages else { return }
        let dirtyPages = Set(dirtyInk.map(\.page))
        for candidate in accessOrder where accessOrder.count > maxCachedPages {
            if !dirtyPages.contains(candidate) && candidate != page {
                ink[candidate] = nil
                accessOrder.removeAll { $0 == candidate }
            }
        }
    }

    // MARK: 저장

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        guard !isDiscarded else { return }
        let nbId = id
        var writes: [(URL, Data)] = []
        for key in dirtyInk {
            if let d = ink[key.page]?[key.layer] {
                writes.append((Storage.inkFile(nbId, page: key.page, layer: key.layer), d.dataRepresentation()))
            }
        }
        let changedPages = Set(dirtyInk.map(\.page))
        dirtyInk.removeAll()
        if notebookDirty {
            notebook.modifiedAt = Date()
            if let data = try? JSONEncoder().encode(notebook) {
                writes.append((Storage.notebookFile(nbId), data))
            }
            notebookDirty = false
            LibraryStore.shared.updateMeta(notebook.meta)
        }
        guard !writes.isEmpty else { return }
        Self.ioQueue.async {
            for (url, data) in writes {
                Storage.ensureParent(url)
                try? data.write(to: url, options: .atomic)
            }
        }
        for p in changedPages { ThumbnailService.shared.invalidate(doc: self, pageId: p) }
    }

    func update(_ change: (inout Notebook) -> Void) {
        change(&notebook)
        notebookDirty = true
        scheduleSave()
    }

    // MARK: 페이지

    func page(id: UUID) -> Page? { notebook.pages.first { $0.id == id } }
    func index(of pageId: UUID) -> Int? { notebook.pages.firstIndex { $0.id == pageId } }

    func updatePage(_ page: Page) {
        guard let i = index(of: page.id), notebook.pages[i] != page else { return }
        notebook.pages[i] = page
        notebookDirty = true
        scheduleSave()
        ThumbnailService.shared.invalidate(doc: self, pageId: page.id)
    }

    func setLastPageIndex(_ i: Int) {
        guard notebook.lastPageIndex != i else { return }
        notebook.lastPageIndex = i
        notebookDirty = true
        scheduleSave()
    }

    @discardableResult
    func insertPage(_ page: Page, at index: Int) -> Int {
        let i = max(0, min(index, notebook.pages.count))
        notebook.pages.insert(page, at: i)
        notebookDirty = true
        scheduleSave()
        return i
    }

    @discardableResult
    func duplicatePage(at index: Int) -> Int? {
        guard let src = notebook.pages[safe: index] else { return nil }
        var copy = src
        copy.id = UUID()
        copy.images = src.images.map { var i = $0; i.id = UUID(); return i }
        copy.texts = src.texts.map { var t = $0; t.id = UUID(); return t }
        copy.masks = src.masks.map { var m = $0; m.id = UUID(); return m }
        for layer in notebook.layers {
            let d = drawing(page: src.id, layer: layer.id)
            if !d.strokes.isEmpty { setDrawing(d, page: copy.id, layer: layer.id) }
        }
        return insertPage(copy, at: index + 1)
    }

    func deletePages(at offsets: IndexSet) {
        let removed = offsets.compactMap { notebook.pages[safe: $0] }
        notebook.pages.remove(atOffsets: offsets)
        if notebook.pages.isEmpty, let first = removed.first {
            notebook.pages = [Page(size: first.size, background: .paper(style: .blank, color: .white))]
        }
        notebook.lastPageIndex = min(notebook.lastPageIndex, notebook.pages.count - 1)
        notebookDirty = true
        let nbId = id
        for p in removed {
            ink[p.id] = nil
            dirtyInk = dirtyInk.filter { $0.page != p.id }
            Self.ioQueue.async {
                try? Storage.fm.removeItem(at: Storage.inkDir(nbId, page: p.id))
                try? Storage.fm.removeItem(at: Storage.thumbFile(nbId, page: p.id))
            }
        }
        scheduleSave()
    }

    func movePages(from: IndexSet, to: Int) {
        notebook.pages.move(fromOffsets: from, toOffset: to)
        notebookDirty = true
        scheduleSave()
    }

    func toggleBookmark(_ pageId: UUID) {
        guard let i = index(of: pageId) else { return }
        notebook.pages[i].isBookmarked.toggle()
        notebookDirty = true
        scheduleSave()
    }

    /// PDF 파일의 모든 페이지를 index 위치에 삽입. 삽입된 첫 페이지 인덱스 반환.
    func insertPDF(from url: URL, at index: Int) -> Int? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let name = "pdf-\(UUID().uuidString).pdf"
        let dest = Storage.assetFile(id, name: name)
        Storage.ensureParent(dest)
        guard (try? Storage.fm.copyItem(at: url, to: dest)) != nil,
              let pdf = PDFDocument(url: dest), pdf.pageCount > 0 else { return nil }
        let pages = PDFImport.pages(for: pdf, fileName: name)
        let at = max(0, min(index, notebook.pages.count))
        notebook.pages.insert(contentsOf: pages, at: at)
        notebookDirty = true
        scheduleSave()
        SearchIndexer.shared.indexPDFText(notebookId: id, pages: pages)
        return at
    }

    // MARK: 에셋

    func assetURL(_ name: String) -> URL { Storage.assetFile(id, name: name) }

    /// 사진을 적당한 크기로 줄여 저장하고 파일 이름과 원본 비율 크기를 돌려준다.
    func saveImage(_ data: Data) -> (name: String, size: CGSize)? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide: CGFloat = 2048
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { return nil }
        let name = "img-\(UUID().uuidString).jpg"
        let url = assetURL(name)
        Storage.ensureParent(url)
        guard (try? jpeg.write(to: url, options: .atomic)) != nil else { return nil }
        return (name, target)
    }

    // MARK: 레이어

    var activeLayer: LayerInfo? { notebook.layers.first { $0.id == notebook.activeLayerId } }

    func addLayer() {
        guard notebook.layers.count < Notebook.maxLayers else { return }
        let l = LayerInfo(name: "필기 \(notebook.layers.count + 1)")
        update {
            $0.layers.append(l)
            $0.activeLayerId = l.id
        }
    }

    func updateLayer(_ layer: LayerInfo) {
        guard let i = notebook.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        update { $0.layers[i] = layer }
    }

    func deleteLayer(_ id: UUID) {
        guard notebook.layers.count > 1 else { return }
        update {
            $0.layers.removeAll { $0.id == id }
            if $0.activeLayerId == id { $0.activeLayerId = $0.layers[0].id }
        }
    }

    func moveLayers(from: IndexSet, to: Int) {
        update { $0.layers.move(fromOffsets: from, toOffset: to) }
    }

    func setActiveLayer(_ id: UUID) {
        guard notebook.activeLayerId != id else { return }
        update { $0.activeLayerId = id }
    }

    var hasAnswerLayer: Bool { notebook.layers.contains { $0.isAnswer } }
    var answersHidden: Bool {
        let answers = notebook.layers.filter(\.isAnswer)
        return !answers.isEmpty && answers.allSatisfy(\.isHidden)
    }

    func setAnswersHidden(_ hidden: Bool) {
        update {
            for i in $0.layers.indices where $0.layers[i].isAnswer { $0.layers[i].isHidden = hidden }
        }
    }

    // MARK: 녹음

    func addRecording(_ r: Recording) { update { $0.recordings.append(r) } }

    func updateRecording(_ r: Recording) {
        guard let i = notebook.recordings.firstIndex(where: { $0.id == r.id }) else { return }
        update { $0.recordings[i] = r }
    }

    func deleteRecording(_ id: UUID) {
        guard let r = notebook.recordings.first(where: { $0.id == id }) else { return }
        try? Storage.fm.removeItem(at: Storage.recordingFile(self.id, name: r.file))
        update { $0.recordings.removeAll { $0.id == id } }
    }
}
