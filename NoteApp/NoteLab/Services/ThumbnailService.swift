import SwiftUI

/// 페이지 썸네일: 메모리 캐시 → 디스크 캐시 → 필요할 때만 생성
@MainActor
final class ThumbnailService: ObservableObject {
    static let shared = ThumbnailService()

    /// 페이지별 갱신 번호. 바뀌면 해당 썸네일 뷰가 다시 읽는다.
    @Published private(set) var revision: [UUID: Int] = [:]

    private let cache = NSCache<NSString, UIImage>()
    private var pending: [UUID: Task<Void, Never>] = [:]
    private let width: CGFloat = 320

    private init() { cache.countLimit = 400 }

    func invalidate(doc: NotebookDocument, pageId: UUID) {
        pending[pageId]?.cancel()
        pending[pageId] = Task { [weak self, weak doc] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, let doc, !Task.isCancelled else { return }
            self.generate(doc: doc, pageId: pageId)
            self.pending[pageId] = nil
        }
    }

    @discardableResult
    func generate(doc: NotebookDocument, pageId: UUID) -> UIImage? {
        guard let page = doc.page(id: pageId) else { return nil }
        let img = PageRenderer.renderImage(doc: doc, page: page, scale: 2 * width / page.size.width,
                                           options: .thumbnail)
        cache.setObject(img, forKey: pageId.uuidString as NSString)
        let url = Storage.thumbFile(doc.id, page: pageId)
        if let data = img.jpegData(compressionQuality: 0.8) {
            DispatchQueue.global(qos: .utility).async {
                Storage.ensureParent(url)
                try? data.write(to: url, options: .atomic)
            }
        }
        revision[pageId, default: 0] += 1
        return img
    }

    func cached(_ pageId: UUID) -> UIImage? { cache.object(forKey: pageId.uuidString as NSString) }

    func thumbnail(notebookId: UUID, pageId: UUID) async -> UIImage? {
        if let img = cached(pageId) { return img }
        let url = Storage.thumbFile(notebookId, page: pageId)
        let loaded = await Task.detached(priority: .utility) { () -> UIImage? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)?.preparingForDisplay()
        }.value
        if let loaded {
            cache.setObject(loaded, forKey: pageId.uuidString as NSString)
            return loaded
        }
        guard let doc = NotebookDocument.existing(notebookId) ?? NotebookDocument.open(notebookId) else { return nil }
        return generate(doc: doc, pageId: pageId)
    }
}

/// 썸네일 뷰 (페이지 비율 유지)
struct PageThumbnail: View {
    let notebookId: UUID
    let pageId: UUID
    let size: CGSize
    @ObservedObject private var service = ThumbnailService.shared
    @State private var image: UIImage?

    init(notebookId: UUID, pageId: UUID, size: CGSize) {
        self.notebookId = notebookId
        self.pageId = pageId
        self.size = size
    }

    var body: some View {
        let rev = service.revision[pageId] ?? 0
        ZStack {
            Color.white
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .aspectRatio(max(size.width, 1) / max(size.height, 1), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Color.black.opacity(0.08)))
        .task(id: "\(pageId)-\(rev)") {
            image = await service.thumbnail(notebookId: notebookId, pageId: pageId)
        }
    }
}
