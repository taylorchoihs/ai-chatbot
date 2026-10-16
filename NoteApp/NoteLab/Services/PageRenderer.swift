import UIKit
import PencilKit

struct RenderOptions {
    /// 정답 레이어를 그릴지
    var includeAnswers = true
    /// 정답 레이어가 숨김 상태여도 그릴지 (오답노트 정답 이미지용)
    var forceAnswers = false
    var includeMasks = false

    static let thumbnail = RenderOptions(includeAnswers: true, forceAnswers: false, includeMasks: true)

    func shows(_ layer: LayerInfo) -> Bool {
        if layer.isAnswer { return includeAnswers && (forceAnswers || !layer.isHidden) }
        return !layer.isHidden
    }
}

enum PageRenderer {
    // MARK: 용지 템플릿

    static func drawPaper(style: PaperStyle, color: PaperColor, size: CGSize, in ctx: CGContext) {
        let full = CGRect(origin: .zero, size: size)
        ctx.saveGState()
        ctx.setFillColor(color.fill.cgColor)
        ctx.fill(full)
        ctx.setStrokeColor(color.line.cgColor)
        ctx.setLineWidth(0.6)
        let margin: CGFloat = 28

        func hLine(_ y: CGFloat, from x0: CGFloat, to x1: CGFloat) {
            ctx.move(to: CGPoint(x: x0, y: y))
            ctx.addLine(to: CGPoint(x: x1, y: y))
        }
        func vLine(_ x: CGFloat, from y0: CGFloat, to y1: CGFloat) {
            ctx.move(to: CGPoint(x: x, y: y0))
            ctx.addLine(to: CGPoint(x: x, y: y1))
        }

        switch style {
        case .blank:
            break
        case .lined, .narrowLined:
            let spacing: CGFloat = style == .lined ? 28 : 21
            var y: CGFloat = 80
            while y < size.height - 24 {
                hLine(y, from: margin, to: size.width - margin)
                y += spacing
            }
            ctx.strokePath()
            ctx.setStrokeColor(UIColor(hex: "#EBA0A0").cgColor)
            vLine(72, from: 0, to: size.height)
            ctx.strokePath()
        case .grid:
            let s: CGFloat = 18
            var x = s
            while x < size.width { vLine(x, from: 0, to: size.height); x += s }
            var y = s
            while y < size.height { hLine(y, from: 0, to: size.width); y += s }
            ctx.strokePath()
        case .dotted:
            ctx.setFillColor(color.line.cgColor)
            let s: CGFloat = 18, r: CGFloat = 1
            var y = s
            while y < size.height {
                var x = s
                while x < size.width {
                    ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    x += s
                }
                y += s
            }
        case .cornell:
            let top: CGFloat = 96, bottom = size.height - 150, cue = size.width * 0.3
            var y = top + 26
            while y < bottom - 4 {
                hLine(y, from: cue + 8, to: size.width - margin)
                y += 26
            }
            ctx.strokePath()
            ctx.setLineWidth(1.2)
            hLine(top, from: margin, to: size.width - margin)
            vLine(cue, from: top, to: bottom)
            hLine(bottom, from: margin, to: size.width - margin)
            ctx.strokePath()
        case .music:
            let gap: CGFloat = 7
            var y: CGFloat = 70
            while y + gap * 4 < size.height - 40 {
                for i in 0..<5 { hLine(y + CGFloat(i) * gap, from: margin, to: size.width - margin) }
                y += gap * 4 + 52
            }
            ctx.strokePath()
        case .todo:
            var y: CGFloat = 80
            while y < size.height - 30 {
                hLine(y, from: margin + 26, to: size.width - margin)
                ctx.addRect(CGRect(x: margin, y: y - 16, width: 13, height: 13))
                y += 36
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    /// 새 노트 시트에서 보여줄 작은 미리보기
    static func paperPreview(style: PaperStyle, color: PaperColor, size: CGSize, width: CGFloat) -> UIImage {
        let scale = width / size.width
        let target = CGSize(width: width, height: size.height * scale)
        return UIGraphicsImageRenderer(size: target).image { r in
            r.cgContext.scaleBy(x: scale, y: scale)
            drawPaper(style: style, color: color, size: size, in: r.cgContext)
        }
    }

    // MARK: PDF

    /// 현재 컨텍스트(페이지 좌표계, 원점 좌상단)에 PDF 페이지를 그린다. 회전값 반영.
    static func drawPDFPage(_ page: CGPDFPage, in ctx: CGContext, pageSize: CGSize) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: pageSize.height)
        ctx.scaleBy(x: 1, y: -1)
        let t = page.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: pageSize),
                                         rotate: 0, preserveAspectRatio: true)
        ctx.concatenate(t)
        ctx.clip(to: page.getBoxRect(.mediaBox))
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }

    @MainActor private static var pdfCache: [URL: CGPDFDocument] = [:]

    @MainActor static func cgPDF(_ url: URL) -> CGPDFDocument? {
        if let d = pdfCache[url] { return d }
        guard let d = CGPDFDocument(url as CFURL) else { return nil }
        if pdfCache.count > 8 { pdfCache.removeAll() }
        pdfCache[url] = d
        return d
    }

    // MARK: 페이지 전체

    @MainActor
    static func drawBackground(doc: NotebookDocument, page: Page, in ctx: CGContext) {
        switch page.background {
        case let .paper(style, color):
            drawPaper(style: style, color: color, size: page.size, in: ctx)
        case let .pdf(file, index):
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.fill(page.bounds)
            if let pdf = cgPDF(doc.assetURL(file)), let p = pdf.page(at: index + 1) {
                drawPDFPage(p, in: ctx, pageSize: page.size)
            }
        }
    }

    /// 배경 + 이미지 + 텍스트 + 잉크 + (선택) 가림막을 현재 UIGraphics 컨텍스트에 그린다.
    @MainActor
    static func drawPageContents(doc: NotebookDocument, page: Page, in ctx: CGContext, inkScale: CGFloat,
                                 clip: CGRect, options: RenderOptions, includeBackground: Bool = true) {
        if includeBackground { drawBackground(doc: doc, page: page, in: ctx) }
        let layers = doc.notebook.layers.filter { options.shows($0) }
        let visible = Set(layers.map(\.id))
        for img in page.images where visible.contains(img.layerId) {
            ImageCache.shared.image(at: doc.assetURL(img.file))?.draw(in: img.rect)
        }
        for t in page.texts where visible.contains(t.layerId) { t.draw() }
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            for layer in layers {
                let d = doc.drawing(page: page.id, layer: layer.id)
                guard !d.strokes.isEmpty, d.bounds.intersects(clip) else { continue }
                d.image(from: clip, scale: inkScale).draw(in: clip)
            }
        }
        if options.includeMasks {
            for m in page.masks {
                ctx.setFillColor(UIColor(hex: m.colorHex).cgColor)
                ctx.fill(m.rect)
            }
        }
    }

    @MainActor
    static func renderImage(doc: NotebookDocument, page: Page, scale: CGFloat, region: CGRect? = nil,
                            options: RenderOptions) -> UIImage {
        let rect = (region ?? page.bounds).integral
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: rect.size, format: format).image { r in
            let ctx = r.cgContext
            ctx.translateBy(x: -rect.minX, y: -rect.minY)
            drawPageContents(doc: doc, page: page, in: ctx, inkScale: scale, clip: rect, options: options)
        }
    }

    /// 손글씨 인식용: 흰 바탕에 잉크만
    @MainActor
    static func renderInkOnly(doc: NotebookDocument, page: Page, scale: CGFloat) -> UIImage? {
        let drawings = doc.notebook.layers.map { doc.drawing(page: page.id, layer: $0.id) }.filter { !$0.strokes.isEmpty }
        guard !drawings.isEmpty else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: page.size, format: format).image { r in
            UIColor.white.setFill()
            r.fill(page.bounds)
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                for d in drawings { d.image(from: page.bounds, scale: scale).draw(in: page.bounds) }
            }
        }
    }

    // MARK: 내보내기

    @MainActor
    static func exportPDF(doc: NotebookDocument, pageIndices: [Int], options: RenderOptions) -> URL? {
        let safeTitle = doc.notebook.title.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safeTitle).pdf")
        try? FileManager.default.removeItem(at: url)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
        do {
            try renderer.writePDF(to: url) { ctx in
                for i in pageIndices {
                    guard let page = doc.notebook.pages[safe: i] else { continue }
                    ctx.beginPage(withBounds: page.bounds, pageInfo: [:])
                    drawPageContents(doc: doc, page: page, in: ctx.cgContext, inkScale: 3,
                                     clip: page.bounds, options: options)
                }
            }
            return url
        } catch {
            return nil
        }
    }

    /// 오답노트 모음을 인쇄용 PDF로: 앞쪽은 문제, 뒤쪽은 정답
    @MainActor
    static func exportWrongAnswers(_ items: [WrongAnswerItem]) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("오답노트.pdf")
        try? FileManager.default.removeItem(at: url)
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let content = pageRect.insetBy(dx: 40, dy: 48)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 13),
                                                         .foregroundColor: UIColor.darkGray]
        func layout(_ ctx: UIGraphicsPDFRendererContext, header: String, file: (WrongAnswerItem) -> String?) {
            var y = content.minY
            ctx.beginPage()
            (header as NSString).draw(at: CGPoint(x: content.minX, y: y),
                                      withAttributes: [.font: UIFont.boldSystemFont(ofSize: 20)])
            y += 40
            for (n, item) in items.enumerated() {
                guard let name = file(item), let img = UIImage(contentsOfFile: Storage.wrongImage(name).path) else { continue }
                let w = min(content.width, img.size.width)
                let h = img.size.height * (w / img.size.width)
                let blockH = min(h, content.height - 30) + 30
                if y + blockH > content.maxY {
                    ctx.beginPage()
                    y = content.minY
                }
                let label = "\(n + 1). \(item.notebookTitle) · \(Format.shortDate.string(from: item.createdAt))"
                (label as NSString).draw(at: CGPoint(x: content.minX, y: y), withAttributes: titleAttrs)
                y += 20
                let drawH = min(h, content.height - 30)
                let drawW = img.size.width * (drawH / img.size.height)
                img.draw(in: CGRect(x: content.minX, y: y, width: min(w, drawW), height: drawH))
                y += drawH + 24
            }
        }
        do {
            try renderer.writePDF(to: url) { ctx in
                layout(ctx, header: "오답노트 · 문제") { $0.questionFile }
                layout(ctx, header: "오답노트 · 정답") { $0.answerFile }
            }
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - 백그라운드 배경 타일 렌더러

enum BackgroundSpec: Equatable {
    case paper(PaperStyle, PaperColor)
    case pdf(URL, Int)
}

/// 확대했을 때 보이는 영역만 화면 해상도로 다시 그려서 선명하게 유지한다.
final class BackgroundTileRenderer {
    private let queue = DispatchQueue(label: "notelab.background", qos: .userInitiated)
    private var documents: [URL: CGPDFDocument] = [:]

    func render(_ spec: BackgroundSpec, pageSize: CGSize, region: CGRect, scale: CGFloat,
                completion: @escaping (UIImage?) -> Void) {
        queue.async { [weak self] in
            let image = self?.draw(spec, pageSize: pageSize, region: region, scale: scale)
            DispatchQueue.main.async { completion(image) }
        }
    }

    private func draw(_ spec: BackgroundSpec, pageSize: CGSize, region: CGRect, scale: CGFloat) -> UIImage? {
        guard region.width >= 1, region.height >= 1 else { return nil }
        var cgPage: CGPDFPage?
        if case let .pdf(url, index) = spec {
            let doc = documents[url] ?? CGPDFDocument(url as CFURL)
            if let doc {
                documents[url] = doc
                cgPage = doc.page(at: index + 1)
            }
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: region.size, format: format).image { r in
            let ctx = r.cgContext
            ctx.translateBy(x: -region.minX, y: -region.minY)
            switch spec {
            case let .paper(style, color):
                PageRenderer.drawPaper(style: style, color: color, size: pageSize, in: ctx)
            case .pdf:
                ctx.setFillColor(UIColor.white.cgColor)
                ctx.fill(CGRect(origin: .zero, size: pageSize))
                if let cgPage { PageRenderer.drawPDFPage(cgPage, in: ctx, pageSize: pageSize) }
            }
        }
    }
}
