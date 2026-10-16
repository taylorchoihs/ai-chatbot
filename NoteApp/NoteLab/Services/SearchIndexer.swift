import SwiftUI
import Vision
import PDFKit

struct SearchResult: Identifiable {
    enum Kind { case title, pdf, ink }
    let id = UUID()
    let notebookId: UUID
    let notebookTitle: String
    let pageIndex: Int?
    let kind: Kind
    let snippet: String
}

/// 검색 색인: PDF 텍스트 + 기기 내 손글씨 인식(Vision, 한국어/영어). 네트워크·AI 서버를 쓰지 않는다.
@MainActor
final class SearchIndexer: ObservableObject {
    static let shared = SearchIndexer()

    @Published private(set) var isIndexing = false
    @Published private(set) var progress: Double = 0

    nonisolated private static let queue = DispatchQueue(label: "notelab.index", qos: .utility)

    private init() {}

    nonisolated static func load(_ id: UUID) -> NotebookSearchIndex {
        Storage.read(NotebookSearchIndex.self, from: Storage.searchIndexFile(id)) ?? NotebookSearchIndex()
    }

    nonisolated static func save(_ index: NotebookSearchIndex, _ id: UUID) {
        try? Storage.write(index, to: Storage.searchIndexFile(id))
    }

    // MARK: PDF 텍스트

    func indexPDFText(notebookId: UUID, pages: [Page]) {
        let items: [(UUID, String, Int)] = pages.compactMap {
            if case let .pdf(file, index) = $0.background { return ($0.id, file, index) }
            return nil
        }
        guard !items.isEmpty else { return }
        Self.queue.async {
            var docs: [String: PDFDocument] = [:]
            var index = Self.load(notebookId)
            for (pageId, file, i) in items {
                let doc = docs[file] ?? PDFDocument(url: Storage.assetFile(notebookId, name: file))
                docs[file] = doc
                let text = doc?.page(at: i)?.string ?? ""
                index.pages[pageId.uuidString, default: PageSearchEntry()].pdfText = text
            }
            Self.save(index, notebookId)
        }
    }

    // MARK: 손글씨

    func indexInk(doc: NotebookDocument, pageId: UUID) {
        guard AppSettings.shared.handwritingIndexing, let page = doc.page(id: pageId) else { return }
        let image = PageRenderer.renderInkOnly(doc: doc, page: page, scale: 1.5)
        let cg = image?.cgImage
        let nbId = doc.id
        Self.queue.async {
            let text = cg.map { Self.recognize($0) } ?? ""
            var index = Self.load(nbId)
            index.pages[pageId.uuidString, default: PageSearchEntry()].inkText = text
            Self.save(index, nbId)
        }
    }

    nonisolated static func recognize(_ cg: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ko-KR", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: " ")
    }

    /// 모든 노트의 손글씨를 다시 인식
    func reindexAll() async {
        guard !isIndexing else { return }
        isIndexing = true
        progress = 0
        let metas = LibraryStore.shared.notebooks
        for (n, meta) in metas.enumerated() {
            if let doc = NotebookDocument.open(meta.id) {
                indexPDFText(notebookId: doc.id, pages: doc.notebook.pages)
                for page in doc.notebook.pages {
                    indexInk(doc: doc, pageId: page.id)
                    await Task.yield()
                }
            }
            progress = Double(n + 1) / Double(max(metas.count, 1))
        }
        // 큐에 쌓인 인식 작업이 끝날 때까지 대기
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            Self.queue.async { c.resume() }
        }
        isIndexing = false
    }

    // MARK: 검색

    nonisolated static func search(_ query: String, in metas: [NotebookMeta]) -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var results: [SearchResult] = []
        for meta in metas {
            if meta.title.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                results.append(SearchResult(notebookId: meta.id, notebookTitle: meta.title, pageIndex: nil,
                                            kind: .title, snippet: meta.title))
            }
            let index = load(meta.id)
            guard !index.pages.isEmpty else { continue }
            var order: [String: Int] = [:]
            if let nb = Storage.read(Notebook.self, from: Storage.notebookFile(meta.id)) {
                for (i, p) in nb.pages.enumerated() { order[p.id.uuidString] = i }
            }
            let hits = index.pages.compactMap { key, entry -> SearchResult? in
                guard let pageIndex = order[key] else { return nil }
                if let s = snippet(entry.inkText, q) {
                    return SearchResult(notebookId: meta.id, notebookTitle: meta.title, pageIndex: pageIndex,
                                        kind: .ink, snippet: s)
                }
                if let s = snippet(entry.pdfText, q) {
                    return SearchResult(notebookId: meta.id, notebookTitle: meta.title, pageIndex: pageIndex,
                                        kind: .pdf, snippet: s)
                }
                return nil
            }
            results.append(contentsOf: hits.sorted { ($0.pageIndex ?? 0) < ($1.pageIndex ?? 0) })
        }
        return results
    }

    nonisolated static func snippet(_ text: String, _ q: String) -> String? {
        guard let r = text.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = text.index(r.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start..<end].replacingOccurrences(of: "\n", with: " ")
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }
}
