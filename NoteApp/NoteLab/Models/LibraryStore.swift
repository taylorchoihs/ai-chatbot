import SwiftUI
import PDFKit

private struct LibraryFile: Codable {
    var folders: [Folder]
    var notebooks: [NotebookMeta]
}

/// 라이브러리 전체 (폴더, 노트 목록, 오답노트) 관리
@MainActor
final class LibraryStore: ObservableObject {
    static let shared = LibraryStore()

    @Published private(set) var folders: [Folder] = []
    @Published private(set) var notebooks: [NotebookMeta] = []
    @Published private(set) var wrongAnswers: [WrongAnswerItem] = []

    private var saveTask: Task<Void, Never>?

    private init() { reload() }

    func reload() {
        let file = Storage.read(LibraryFile.self, from: Storage.libraryFile)
        folders = file?.folders ?? []
        notebooks = file?.notebooks ?? []
        wrongAnswers = Storage.read([WrongAnswerItem].self, from: Storage.wrongFile) ?? []
        reconcileWithDisk()
    }

    /// library.json이 없거나 어긋났을 때(복원 직후 등) 노트 폴더를 직접 훑어서 복구
    private func reconcileWithDisk() {
        let dirs = (try? Storage.fm.contentsOfDirectory(at: Storage.notebooksDir, includingPropertiesForKeys: nil)) ?? []
        var known = Dictionary(notebooks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var found: Set<UUID> = []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            found.insert(id)
            if known[id] == nil, let nb = Storage.read(Notebook.self, from: Storage.notebookFile(id)) {
                known[id] = nb.meta
            }
        }
        let merged = known.values.filter { found.contains($0.id) }.sorted { $0.modifiedAt > $1.modifiedAt }
        if merged != notebooks {
            notebooks = merged
            scheduleSave()
        }
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        try? Storage.write(LibraryFile(folders: folders, notebooks: notebooks), to: Storage.libraryFile)
        try? Storage.write(wrongAnswers, to: Storage.wrongFile)
    }

    // MARK: 노트

    func meta(_ id: UUID) -> NotebookMeta? { notebooks.first { $0.id == id } }

    @discardableResult
    func createNotebook(title: String, folderId: UUID?, style: PaperStyle, color: PaperColor,
                        size: PaperSize, pageCount: Int, coverHex: String) -> UUID {
        let pages = (0..<max(1, pageCount)).map { _ in
            Page(size: size.size, background: .paper(style: style, color: color))
        }
        let name = title.trimmingCharacters(in: .whitespaces).isEmpty ? "새 노트" : title
        let nb = Notebook.make(title: name, folderId: folderId, coverHex: coverHex, pages: pages)
        try? Storage.write(nb, to: Storage.notebookFile(nb.id))
        notebooks.insert(nb.meta, at: 0)
        scheduleSave()
        return nb.id
    }

    /// PDF를 복사해서 새 노트로 만든다. 페이지마다 원본 PDF 페이지를 배경으로 쓴다.
    func importPDF(from url: URL, folderId: UUID?) -> UUID? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let fileName = "pdf-\(UUID().uuidString).pdf"
        let dest = Storage.assetFile(id, name: fileName)
        Storage.ensureParent(dest)
        do {
            try Storage.fm.copyItem(at: url, to: dest)
        } catch {
            return nil
        }
        guard let pdf = PDFDocument(url: dest), pdf.pageCount > 0 else {
            try? Storage.fm.removeItem(at: Storage.notebookDir(id))
            return nil
        }
        let pages = PDFImport.pages(for: pdf, fileName: fileName)
        var nb = Notebook.make(title: url.deletingPathExtension().lastPathComponent, folderId: folderId,
                               coverHex: "#3F6BE6FF", pages: pages)
        nb.id = id
        try? Storage.write(nb, to: Storage.notebookFile(id))
        notebooks.insert(nb.meta, at: 0)
        scheduleSave()
        SearchIndexer.shared.indexPDFText(notebookId: id, pages: pages)
        return id
    }

    func deleteNotebook(_ id: UUID) {
        NotebookDocument.discard(id)
        try? Storage.fm.removeItem(at: Storage.notebookDir(id))
        notebooks.removeAll { $0.id == id }
        scheduleSave()
    }

    func duplicateNotebook(_ id: UUID) {
        NotebookDocument.existing(id)?.saveNow()
        let newId = UUID()
        // 저장 큐의 쓰기가 끝난 다음 복사
        NotebookDocument.ioQueue.sync {}
        do {
            try Storage.fm.copyItem(at: Storage.notebookDir(id), to: Storage.notebookDir(newId))
        } catch { return }
        guard var nb = Storage.read(Notebook.self, from: Storage.notebookFile(newId)) else { return }
        nb.id = newId
        nb.title += " 사본"
        nb.createdAt = Date()
        nb.modifiedAt = Date()
        try? Storage.write(nb, to: Storage.notebookFile(newId))
        notebooks.insert(nb.meta, at: 0)
        scheduleSave()
    }

    /// 열린 문서가 있으면 그 문서를 통해, 아니면 파일을 직접 수정
    func mutateNotebook(_ id: UUID, _ change: (inout Notebook) -> Void) {
        if let doc = NotebookDocument.existing(id) {
            doc.update(change)
            doc.saveNow()
            return
        }
        guard var nb = Storage.read(Notebook.self, from: Storage.notebookFile(id)) else { return }
        change(&nb)
        try? Storage.write(nb, to: Storage.notebookFile(id))
        updateMeta(nb.meta)
    }

    func rename(_ id: UUID, to title: String) { mutateNotebook(id) { $0.title = title } }
    func move(_ id: UUID, to folderId: UUID?) { mutateNotebook(id) { $0.folderId = folderId } }
    func toggleFavorite(_ id: UUID) { mutateNotebook(id) { $0.isFavorite.toggle() } }

    func markOpened(_ id: UUID) {
        guard let i = notebooks.firstIndex(where: { $0.id == id }) else { return }
        notebooks[i].lastOpenedAt = Date()
        scheduleSave()
    }

    func updateMeta(_ meta: NotebookMeta) {
        if let i = notebooks.firstIndex(where: { $0.id == meta.id }) {
            var m = meta
            m.lastOpenedAt = notebooks[i].lastOpenedAt
            if notebooks[i] != m { notebooks[i] = m }
        } else {
            notebooks.insert(meta, at: 0)
        }
        scheduleSave()
    }

    // MARK: 폴더

    func folder(_ id: UUID?) -> Folder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    @discardableResult
    func addFolder(name: String, colorHex: String) -> Folder {
        let f = Folder(name: name.isEmpty ? "새 과목" : name, colorHex: colorHex)
        folders.append(f)
        scheduleSave()
        return f
    }

    func updateFolder(_ folder: Folder) {
        guard let i = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[i] = folder
        scheduleSave()
    }

    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        for nb in notebooks where nb.folderId == id { move(nb.id, to: nil) }
        scheduleSave()
    }

    func moveFolders(from: IndexSet, to: Int) {
        folders.move(fromOffsets: from, toOffset: to)
        scheduleSave()
    }

    func addStudyTime(folderId: UUID, seconds: TimeInterval) {
        guard seconds > 0, let i = folders.firstIndex(where: { $0.id == folderId }) else { return }
        folders[i].studyLog[Folder.dayKey(Date()), default: 0] += seconds
        scheduleSave()
    }

    // MARK: 오답노트

    func addWrongAnswer(_ item: WrongAnswerItem) {
        wrongAnswers.insert(item, at: 0)
        scheduleSave()
    }

    func updateWrongAnswer(_ item: WrongAnswerItem) {
        guard let i = wrongAnswers.firstIndex(where: { $0.id == item.id }) else { return }
        wrongAnswers[i] = item
        scheduleSave()
    }

    func recordAttempt(_ id: UUID, correct: Bool) {
        guard let i = wrongAnswers.firstIndex(where: { $0.id == id }) else { return }
        wrongAnswers[i].attempts.append(Attempt(date: Date(), correct: correct))
        scheduleSave()
    }

    func deleteWrongAnswer(_ id: UUID) {
        guard let item = wrongAnswers.first(where: { $0.id == id }) else { return }
        try? Storage.fm.removeItem(at: Storage.wrongImage(item.questionFile))
        if let a = item.answerFile { try? Storage.fm.removeItem(at: Storage.wrongImage(a)) }
        wrongAnswers.removeAll { $0.id == id }
        scheduleSave()
    }
}

enum PDFImport {
    static func pages(for pdf: PDFDocument, fileName: String) -> [Page] {
        (0..<pdf.pageCount).compactMap { i in
            guard let p = pdf.page(at: i) else { return nil }
            var size = p.bounds(for: .mediaBox).size
            if p.rotation % 180 != 0 { size = CGSize(width: size.height, height: size.width) }
            return Page(size: size, background: .pdf(file: fileName, index: i))
        }
    }
}
