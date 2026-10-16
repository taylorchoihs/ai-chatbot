import UIKit
import PencilKit

/// 한 페이지를 편집하는 UIKit 뷰.
///
/// 계층 (아래 → 위):
///   underView   (페이지 좌표, 확대 변환) 배경 이미지, 확대용 선명한 타일, 사진, 텍스트
///   PKCanvasView × 레이어 수 (레이어마다 하나, 스크롤·확대는 활성 레이어가 주도하고 나머지는 따라감)
///   overView    (페이지 좌표, 확대 변환) 가림막, 들어 올린 선택 영역 이미지
///   overlay     (화면 좌표) 올가미 경로, 선택 테두리, 레이저
///   selectionMenu
final class PageEditorView: UIView, PKCanvasViewDelegate, UIPencilInteractionDelegate {

    // MARK: 내부 타입

    private struct PageSnapshot {
        var drawings: [UUID: PKDrawing]
        var page: Page
    }

    private struct LiftedStroke {
        var layer: UUID
        var stroke: PKStroke
    }

    private struct LiftedSelection {
        var strokes: [LiftedStroke]
        var images: [PageImage]
        var texts: [PageText]
        var originalBounds: CGRect
        var currentRect: CGRect
        var targetLayer: UUID?
        var before: PageSnapshot
        var modified: Bool

        var scale: CGFloat { currentRect.width / max(originalBounds.width, 0.0001) }
        var transform: CGAffineTransform {
            CGAffineTransform(translationX: currentRect.minX, y: currentRect.minY)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -originalBounds.minX, y: -originalBounds.minY)
        }
    }

    private enum DragMode { case none, lasso, move, resize, mask, laser }

    private final class GestureDelegate: NSObject, UIGestureRecognizerDelegate {
        var shouldBegin: (UIGestureRecognizer) -> Bool = { _ in true }
        var simultaneous: (UIGestureRecognizer, UIGestureRecognizer) -> Bool = { _, _ in false }
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool { shouldBegin(g) }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            simultaneous(g, other)
        }
    }

    // MARK: 상태

    private let model: EditorModel

    private let underView = UIView()
    private let baseImageView = UIImageView()
    private let detailImageView = UIImageView()
    private let decorationView = UIView()
    private let overView = UIView()
    private let maskContainer = UIView()
    private let floatingImageView = UIImageView()
    private let overlay = EditorOverlayView()
    private let selectionMenu = SelectionMenuView()

    private var canvases: [UUID: PKCanvasView] = [:]
    private var master: PKCanvasView?
    private(set) var page: Page?
    private var loadedLayers: [LayerInfo] = []
    private var suppressSync = false
    private var fitZoom: CGFloat = 1
    private var lastBoundsSize: CGSize = .zero
    private let tileRenderer = BackgroundTileRenderer()
    private var backgroundGeneration = 0
    private var detailGeneration = 0
    private var detailWork: DispatchWorkItem?

    private var selection: LiftedSelection?
    private var floatingBaseRect: CGRect = .zero
    private var liftedDecorationIds: Set<UUID> = []
    private var lassoPoints: [CGPoint] = []
    private var maskDraft: CGRect?
    private var dragMode: DragMode = .none
    private var dragOriginRect: CGRect = .zero
    private var dragStartPoint: CGPoint = .zero
    private var laserPoints: [(point: CGPoint, time: CFTimeInterval)] = []
    private var displayLink: CADisplayLink?
    private var revealedMasks: Set<UUID> = []
    private var lastRevealAll = false
    private var strokeCountAtToolBegin = 0

    private let gestureDelegate = GestureDelegate()
    private lazy var toolPan = UIPanGestureRecognizer(target: self, action: #selector(handleToolPan(_:)))
    private lazy var selectionFingerPan = UIPanGestureRecognizer(target: self, action: #selector(handleToolPan(_:)))
    private lazy var fingerTap = UITapGestureRecognizer(target: self, action: #selector(handleFingerTap(_:)))
    private lazy var pencilTap = UITapGestureRecognizer(target: self, action: #selector(handlePencilTap(_:)))
    private lazy var twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap))
    private lazy var threeFingerTap = UITapGestureRecognizer(target: self, action: #selector(handleRedoTap))
    private lazy var swipeLeft = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
    private lazy var swipeRight = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))

    // PencilKit 캔버스는 응답 체인으로 undoManager를 찾는다 → 편집기 전용 UndoManager 사용
    override var undoManager: UndoManager? { model.undoManager }

    private var displayScale: CGFloat { max(traitCollection.displayScale, 2) }
    private var zoom: CGFloat { master?.zoomScale ?? 1 }

    // MARK: 초기화

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        backgroundColor = UIColor.secondarySystemBackground
        clipsToBounds = true

        underView.isUserInteractionEnabled = false
        underView.backgroundColor = .white
        underView.layer.shadowColor = UIColor.black.cgColor
        underView.layer.shadowOpacity = 0.12
        underView.layer.shadowRadius = 4
        underView.layer.shadowOffset = CGSize(width: 0, height: 1)
        baseImageView.contentMode = .scaleToFill
        detailImageView.contentMode = .scaleToFill
        detailImageView.isHidden = true
        decorationView.clipsToBounds = true
        underView.addSubview(baseImageView)
        underView.addSubview(detailImageView)
        underView.addSubview(decorationView)
        addSubview(underView)

        overView.isUserInteractionEnabled = false
        maskContainer.clipsToBounds = true
        overView.addSubview(maskContainer)
        overView.addSubview(floatingImageView)
        addSubview(overView)

        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(overlay)

        selectionMenu.isHidden = true
        addSubview(selectionMenu)
        selectionMenu.onCopy = { [weak self] in self?.copySelection() }
        selectionMenu.onCut = { [weak self] in self?.copySelection(); self?.deleteSelection() }
        selectionMenu.onDuplicate = { [weak self] in self?.duplicateSelection() }
        selectionMenu.onDelete = { [weak self] in self?.deleteSelection() }
        selectionMenu.onDone = { [weak self] in self?.commitSelection() }
        selectionMenu.onWrongAnswer = { [weak self] in self?.sendSelectionToWrongAnswers() }
        selectionMenu.onColor = { [weak self] hex in self?.recolorSelection(hex) }
        selectionMenu.onLayer = { [weak self] id in self?.moveSelection(toLayer: id) }

        setupGestures()
        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    private func setupGestures() {
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
        toolPan.maximumNumberOfTouches = 1
        toolPan.allowedTouchTypes = [pencil]
        selectionFingerPan.maximumNumberOfTouches = 1
        selectionFingerPan.allowedTouchTypes = [direct]
        fingerTap.allowedTouchTypes = [direct]
        pencilTap.allowedTouchTypes = [pencil]
        twoFingerTap.numberOfTouchesRequired = 2
        twoFingerTap.allowedTouchTypes = [direct]
        threeFingerTap.numberOfTouchesRequired = 3
        threeFingerTap.allowedTouchTypes = [direct]
        swipeLeft.direction = .left
        swipeRight.direction = .right
        swipeLeft.allowedTouchTypes = [direct]
        swipeRight.allowedTouchTypes = [direct]
        twoFingerTap.require(toFail: threeFingerTap)
        for g in [fingerTap, pencilTap, twoFingerTap, threeFingerTap] as [UIGestureRecognizer] {
            g.cancelsTouchesInView = false
        }
        let all: [UIGestureRecognizer] = [toolPan, selectionFingerPan, fingerTap, pencilTap,
                                          twoFingerTap, threeFingerTap, swipeLeft, swipeRight]
        for g in all {
            g.delegate = gestureDelegate
            addGestureRecognizer(g)
        }
        gestureDelegate.shouldBegin = { [weak self] g in self?.gestureShouldBegin(g) ?? false }
        gestureDelegate.simultaneous = { [weak self] g, _ in
            guard let self else { return false }
            return g === self.fingerTap || g === self.pencilTap || g === self.twoFingerTap
                || g === self.threeFingerTap || g === self.swipeLeft || g === self.swipeRight
        }
    }

    private func gestureShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        let p = g.location(in: self)
        if !selectionMenu.isHidden && selectionMenu.frame.insetBy(dx: -4, dy: -4).contains(p) { return false }
        if g === selectionFingerPan {
            guard model.tool == .lasso, selection != nil else { return false }
            let start: CGPoint
            if let pan = g as? UIPanGestureRecognizer {
                let t = pan.translation(in: self)
                start = CGPoint(x: p.x - t.x, y: p.y - t.y)
            } else {
                start = p
            }
            return hitsHandle(start) || selectionScreenRect.insetBy(dx: -16, dy: -16).contains(start)
        }
        if g === swipeLeft || g === swipeRight {
            return AppSettings.shared.swipeToTurnPage && isAtFitZoom && selection == nil && dragMode == .none
        }
        return true
    }

    // MARK: 모델과 동기화 (SwiftUI updateUIView에서 호출)

    func syncWithModel() {
        let current = model.currentPage
        if page?.id != current.id {
            loadPage(current)
        } else if let page, page != current, selection == nil {
            self.page = current
            if page.background != current.background || page.size != current.size {
                configureZoom(reset: page.size != current.size)
            }
            rebuildDecorations()
        }
        let layers = model.doc.notebook.layers
        if layers.map(\.id) != loadedLayers.map(\.id) {
            commitSelection()
            rebuildCanvases()
            configureZoom(reset: false)
        } else if layers != loadedLayers {
            loadedLayers = layers
            applyLayerVisibility()
            rebuildDecorations()
        }
        if canvases[model.doc.notebook.activeLayerId] !== master { updateMaster() }
        if lastRevealAll != model.revealAllMasks {
            lastRevealAll = model.revealAllMasks
            revealedMasks = []
            rebuildMasks()
        }
        applyTool()
    }

    private func loadPage(_ newPage: Page) {
        commitSelection()
        cancelTransient()
        model.undoManager.removeAllActions()
        publishLater { $0.refreshUndoState() }
        page = newPage
        revealedMasks = []
        baseImageView.image = nil
        detailImageView.image = nil
        detailImageView.isHidden = true
        rebuildCanvases()
        configureZoom(reset: true)
        rebuildDecorations()
    }

    private func cancelTransient() {
        lassoPoints = []
        maskDraft = nil
        dragMode = .none
        laserPoints = []
        updateOverlay()
    }

    // MARK: 캔버스 (레이어)

    private func makeCanvas() -> PKCanvasView {
        let c = PKCanvasView(frame: bounds)
        c.backgroundColor = .clear
        c.isOpaque = false
        c.overrideUserInterfaceStyle = .light
        c.delegate = self
        c.showsVerticalScrollIndicator = false
        c.showsHorizontalScrollIndicator = false
        c.contentInsetAdjustmentBehavior = .never
        c.drawingPolicy = .pencilOnly
        c.alwaysBounceVertical = true
        return c
    }

    private func rebuildCanvases() {
        guard let page else { return }
        let layers = model.doc.notebook.layers
        var next: [UUID: PKCanvasView] = [:]
        suppressSync = true
        for layer in layers {
            let c = canvases[layer.id] ?? makeCanvas()
            c.frame = bounds
            c.drawing = model.doc.drawing(page: page.id, layer: layer.id)
            next[layer.id] = c
        }
        suppressSync = false
        for (id, c) in canvases where next[id] == nil { c.removeFromSuperview() }
        canvases = next
        for layer in layers {
            if let c = canvases[layer.id] { insertSubview(c, belowSubview: overView) }
        }
        loadedLayers = layers
        updateMaster()
        applyLayerVisibility()
    }

    private func updateMaster() {
        let previous = master
        master = canvases[model.doc.notebook.activeLayerId] ?? loadedLayers.compactMap { canvases[$0.id] }.first
        for c in canvases.values { c.isUserInteractionEnabled = (c === master) }
        if let m = master, let p = previous, p !== m, p.superview != nil {
            m.minimumZoomScale = p.minimumZoomScale
            m.maximumZoomScale = p.maximumZoomScale
            m.zoomScale = p.zoomScale
            m.contentSize = p.contentSize
            m.contentInset = p.contentInset
            m.contentOffset = p.contentOffset
        }
        applyLayerVisibility()
        applyTool()
    }

    private func applyLayerVisibility() {
        for layer in loadedLayers {
            guard let c = canvases[layer.id] else { continue }
            if c === master {
                // 스크롤을 주도하는 캔버스는 숨겨도 터치를 받아야 하므로 투명하게만 처리
                c.isHidden = false
                c.alpha = layer.isHidden ? 0 : 1
            } else {
                c.isHidden = layer.isHidden
                c.alpha = 1
            }
        }
    }

    private var activeLayerInfo: LayerInfo? {
        loadedLayers.first { $0.id == model.doc.notebook.activeLayerId }
    }

    private var activeLayerWritable: Bool {
        guard let l = activeLayerInfo else { return false }
        return !l.isLocked && !l.isHidden
    }

    func applyTool() {
        guard let m = master else { return }
        let settings = AppSettings.shared
        let policy: PKCanvasViewDrawingPolicy = settings.fingerDrawing ? .anyInput : .pencilOnly
        let pkTool = model.pkTool
        let drawingEnabled = pkTool != nil && activeLayerWritable && !model.isReadingMode
        for c in canvases.values {
            if c.drawingPolicy != policy { c.drawingPolicy = policy }
            c.drawingGestureRecognizer.isEnabled = (c === m) && drawingEnabled
        }
        if let pkTool { m.tool = pkTool }
        m.isScrollEnabled = selection == nil

        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let customTool = [.lasso, .mask, .laser].contains(model.tool)
        toolPan.isEnabled = !model.isReadingMode && customTool
        toolPan.allowedTouchTypes = settings.fingerDrawing ? [pencil, direct] : [pencil]
        pencilTap.isEnabled = [.text, .mask, .lasso].contains(model.tool) && !model.isReadingMode
        let swipeTouches = settings.fingerDrawing ? 2 : 1
        swipeLeft.numberOfTouchesRequired = swipeTouches
        swipeRight.numberOfTouchesRequired = swipeTouches

        if model.tool != .lasso, selection != nil {
            // SwiftUI 업데이트 도중에 문서를 바꾸지 않도록 다음 런루프에서 반영
            DispatchQueue.main.async { [weak self] in
                guard let self, self.model.tool != .lasso else { return }
                self.commitSelection()
            }
        }
        if model.tool != .laser, !laserPoints.isEmpty {
            laserPoints = []
            updateOverlay()
        }
    }

    // MARK: 확대·스크롤

    override func layoutSubviews() {
        super.layoutSubviews()
        overlay.frame = bounds
        for c in canvases.values where c.frame != bounds { c.frame = bounds }
        if bounds.size != lastBoundsSize, bounds.width > 0 {
            let first = lastBoundsSize == .zero
            lastBoundsSize = bounds.size
            configureZoom(reset: first || isAtFitZoom, scrollToTop: first)
        }
    }

    private var isAtFitZoom: Bool { zoom <= fitZoom * 1.02 }

    private func configureZoom(reset: Bool, scrollToTop: Bool = true) {
        guard let page, bounds.width > 0, bounds.height > 0 else { return }
        let fitW = (bounds.width - 32) / page.size.width
        let fitAll = (bounds.height - 32) / page.size.height
        let topY = screenToPage(.zero).y
        fitZoom = fitW
        for c in canvases.values {
            c.minimumZoomScale = min(fitW, fitAll) * 0.9
            c.maximumZoomScale = fitW * 6
        }
        if reset, let m = master {
            m.zoomScale = fitW
            updateContentGeometry(m)
            if scrollToTop {
                m.contentOffset = CGPoint(x: -m.contentInset.left, y: -m.contentInset.top)
            } else {
                // 회전·창 크기 변경: 보던 위치 유지
                let maxY = max(-m.contentInset.top, m.contentSize.height + m.contentInset.bottom - bounds.height)
                m.contentOffset = CGPoint(x: -m.contentInset.left, y: min(max(topY * fitW, -m.contentInset.top), maxY))
            }
        } else if let m = master {
            updateContentGeometry(m)
        }
        syncFollowers()
        renderBaseBackground()
        scheduleDetailRender()
    }

    private func updateContentGeometry(_ c: PKCanvasView) {
        guard let page else { return }
        let z = c.zoomScale
        let size = CGSize(width: page.size.width * z, height: page.size.height * z)
        if c.contentSize != size { c.contentSize = size }
        let insetX = max(16, (bounds.width - size.width) / 2)
        let insetY = max(16, (bounds.height - size.height) / 2)
        let inset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
        if c.contentInset != inset { c.contentInset = inset }
    }

    private func syncFollowers() {
        guard let m = master else { return }
        for c in canvases.values where c !== m {
            if c.zoomScale != m.zoomScale { c.zoomScale = m.zoomScale }
            if c.contentSize != m.contentSize { c.contentSize = m.contentSize }
            if c.contentInset != m.contentInset { c.contentInset = m.contentInset }
            if c.contentOffset != m.contentOffset { c.contentOffset = m.contentOffset }
        }
        syncContentTransforms()
    }

    private func syncContentTransforms() {
        guard let page, let m = master else { return }
        let z = m.zoomScale
        let off = m.contentOffset
        for v in [underView, overView] {
            v.bounds = page.bounds
            v.transform = CGAffineTransform(scaleX: z, y: z)
            v.center = CGPoint(x: page.size.width * z / 2 - off.x, y: page.size.height * z / 2 - off.y)
        }
        underView.layer.shadowPath = UIBezierPath(rect: page.bounds).cgPath
        updateOverlay()
        positionSelectionMenu()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        guard scrollView === master, let m = master else { return }
        updateContentGeometry(m)
        syncFollowers()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === master else { return }
        syncFollowers()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard scrollView === master else { return }
        scheduleDetailRender()
        if selection != nil { renderFloating() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === master else { return }
        scheduleDetailRender()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard scrollView === master, !decelerate else { return }
        scheduleDetailRender()
    }

    func pageToScreen(_ p: CGPoint) -> CGPoint {
        guard let m = master else { return p }
        return CGPoint(x: p.x * m.zoomScale - m.contentOffset.x, y: p.y * m.zoomScale - m.contentOffset.y)
    }

    func screenToPage(_ p: CGPoint) -> CGPoint {
        guard let m = master else { return p }
        return CGPoint(x: (p.x + m.contentOffset.x) / m.zoomScale, y: (p.y + m.contentOffset.y) / m.zoomScale)
    }

    private func pageRectToScreen(_ r: CGRect) -> CGRect {
        CGRect(corner: pageToScreen(r.origin), pageToScreen(CGPoint(x: r.maxX, y: r.maxY)))
    }

    private var visiblePageRect: CGRect {
        guard let page else { return .zero }
        let r = CGRect(corner: screenToPage(.zero), screenToPage(CGPoint(x: bounds.maxX, y: bounds.maxY)))
        return r.intersection(page.bounds)
    }

    // MARK: 배경 렌더링

    private func backgroundSpec(for page: Page) -> BackgroundSpec {
        switch page.background {
        case let .paper(style, color): return .paper(style, color)
        case let .pdf(file, index): return .pdf(model.doc.assetURL(file), index)
        }
    }

    private func renderBaseBackground() {
        guard let page, bounds.width > 0 else { return }
        if case let .paper(_, color) = page.background {
            underView.backgroundColor = color.fill
        } else {
            underView.backgroundColor = .white
        }
        baseImageView.frame = page.bounds
        decorationView.frame = page.bounds
        maskContainer.frame = page.bounds
        backgroundGeneration += 1
        let gen = backgroundGeneration
        let scale = min(fitZoom * displayScale, 2600 / max(page.size.width, page.size.height))
        tileRenderer.render(backgroundSpec(for: page), pageSize: page.size, region: page.bounds, scale: scale) { [weak self] img in
            guard let self, gen == self.backgroundGeneration else { return }
            self.baseImageView.image = img
        }
    }

    private func scheduleDetailRender() {
        detailWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.renderDetail() }
        detailWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func renderDetail() {
        guard let page, let m = master else { return }
        updateTextScale()
        guard m.zoomScale > fitZoom * 1.15 else {
            detailImageView.isHidden = true
            return
        }
        let region = visiblePageRect.integral.intersection(page.bounds)
        guard !region.isNull, region.width > 1, region.height > 1 else { return }
        detailGeneration += 1
        let gen = detailGeneration
        let scale = min(m.zoomScale * displayScale, 14)
        tileRenderer.render(backgroundSpec(for: page), pageSize: page.size, region: region, scale: scale) { [weak self] img in
            guard let self, gen == self.detailGeneration, let img else { return }
            self.detailImageView.image = img
            self.detailImageView.frame = region
            self.detailImageView.isHidden = false
        }
    }

    // MARK: 사진·텍스트·가림막

    private func rebuildDecorations() {
        guard let page else { return }
        decorationView.subviews.forEach { $0.removeFromSuperview() }
        let visible = Set(loadedLayers.filter { !$0.isHidden }.map(\.id))
        for img in page.images where visible.contains(img.layerId) && !liftedDecorationIds.contains(img.id) {
            let v = UIImageView(image: ImageCache.shared.image(at: model.doc.assetURL(img.file)))
            v.frame = img.rect
            v.contentMode = .scaleToFill
            decorationView.addSubview(v)
        }
        for t in page.texts where visible.contains(t.layerId) && !liftedDecorationIds.contains(t.id) {
            let label = UILabel(frame: t.frame.insetBy(dx: 4, dy: 4))
            label.numberOfLines = 0
            label.attributedText = NSAttributedString(string: t.text, attributes: t.attributes)
            decorationView.addSubview(label)
        }
        updateTextScale()
        rebuildMasks()
    }

    private func updateTextScale() {
        let s = min(displayScale * zoom, 10)
        for case let label as UILabel in decorationView.subviews where label.contentScaleFactor != s {
            label.contentScaleFactor = s
            label.setNeedsDisplay()
        }
    }

    private func isMaskRevealed(_ id: UUID) -> Bool {
        model.revealAllMasks != revealedMasks.contains(id)
    }

    private func rebuildMasks() {
        guard let page else { return }
        maskContainer.subviews.forEach { $0.removeFromSuperview() }
        for m in page.masks {
            let v = UIView(frame: m.rect)
            let color = UIColor(hex: m.colorHex)
            v.layer.cornerRadius = 3
            if isMaskRevealed(m.id) {
                v.backgroundColor = color.withAlphaComponent(0.12)
                v.layer.borderColor = color.withAlphaComponent(0.8).cgColor
                v.layer.borderWidth = 1
            } else {
                v.backgroundColor = color
            }
            maskContainer.addSubview(v)
        }
    }

    private func toggleMask(_ id: UUID) {
        if revealedMasks.contains(id) { revealedMasks.remove(id) } else { revealedMasks.insert(id) }
        rebuildMasks()
    }

    func upsertText(_ text: PageText) {
        guard var p = page else { return }
        commitSelection()
        let before = snapshot()
        if let i = p.texts.firstIndex(where: { $0.id == text.id }) { p.texts[i] = text } else { p.texts.append(text) }
        commitChange(to: PageSnapshot(drawings: before.drawings, page: p), from: before, actionName: "텍스트")
    }

    func removeText(_ id: UUID) {
        guard var p = page else { return }
        let before = snapshot()
        p.texts.removeAll { $0.id == id }
        commitChange(to: PageSnapshot(drawings: before.drawings, page: p), from: before, actionName: "텍스트 삭제")
    }

    // MARK: 상태 스냅샷 + 실행 취소

    private func snapshot() -> PageSnapshot {
        var d: [UUID: PKDrawing] = [:]
        for (id, c) in canvases { d[id] = c.drawing }
        return PageSnapshot(drawings: d, page: page ?? model.currentPage)
    }

    private func applyState(_ snap: PageSnapshot) {
        guard snap.page.id == page?.id else { return }
        suppressSync = true
        for (id, d) in snap.drawings { canvases[id]?.drawing = d }
        suppressSync = false
        for (id, d) in snap.drawings { model.doc.setDrawing(d, page: snap.page.id, layer: id) }
        page = snap.page
        model.doc.updatePage(snap.page)
        model.pageEdited(snap.page.id)
        rebuildDecorations()
    }

    private func commitChange(to new: PageSnapshot, from old: PageSnapshot, actionName: String) {
        applyState(new)
        model.undoManager.registerUndo(withTarget: self) { view in
            view.cancelSelectionWithoutApplying()
            view.commitChange(to: old, from: new, actionName: actionName)
        }
        model.undoManager.setActionName(actionName)
        publishLater { $0.refreshUndoState() }
    }

    /// SwiftUI 상태 변경은 뷰 업데이트가 끝난 뒤에
    private func publishLater(_ change: @escaping (EditorModel) -> Void) {
        let model = self.model
        DispatchQueue.main.async { change(model) }
    }

    // MARK: PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !suppressSync, let page,
              let layerId = canvases.first(where: { $0.value === canvasView })?.key else { return }
        model.doc.setDrawing(canvasView.drawing, page: page.id, layer: layerId)
        model.pageEdited(page.id)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        strokeCountAtToolBegin = canvasView.drawing.strokes.count
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard AppSettings.shared.shapeSnap, canvasView === master,
              model.tool == .pen || model.tool == .highlighter else { return }
        let before = strokeCountAtToolBegin
        DispatchQueue.main.async { [weak self] in
            self?.snapLastStroke(canvasView, expectedCount: before + 1)
        }
    }

    private func snapLastStroke(_ canvas: PKCanvasView, expectedCount: Int) {
        var drawing = canvas.drawing
        guard drawing.strokes.count == expectedCount, let last = drawing.strokes.last,
              let pts = ShapeRecognizer.recognize(last) else { return }
        let width = last.path.first?.size.width ?? 3
        guard let snapped = ShapeFactory.stroke(points: pts, ink: last.ink, width: width,
                                                date: last.path.creationDate) else { return }
        let old = snapshot()
        drawing.strokes[drawing.strokes.count - 1] = snapped
        var new = old
        if let id = canvases.first(where: { $0.value === canvas })?.key { new.drawings[id] = drawing }
        commitChange(to: new, from: old, actionName: "도형 보정")
    }

    // MARK: Apple Pencil 더블탭

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        switch AppSettings.shared.pencilDoubleTap {
        case .system:
            switch UIPencilInteraction.preferredTapAction {
            case .switchEraser: model.toggleEraser()
            case .switchPrevious: model.switchToPreviousTool()
            default: break
            }
        case .eraser: model.toggleEraser()
        case .previous: model.switchToPreviousTool()
        case .none: break
        }
    }

    // MARK: 제스처

    @objc private func handleUndoTap() { model.undo() }
    @objc private func handleRedoTap() { model.redo() }

    @objc private func handleSwipe(_ g: UISwipeGestureRecognizer) {
        if g.direction == .left { model.nextPage() } else { model.previousPage() }
    }

    @objc private func handleFingerTap(_ g: UITapGestureRecognizer) {
        guard let page else { return }
        let screen = g.location(in: self)
        let p = screenToPage(screen)
        if let mask = page.masks.last(where: { $0.rect.contains(p) }) {
            toggleMask(mask.id)
            return
        }
        if selection != nil {
            if !selectionScreenRect.insetBy(dx: -12, dy: -12).contains(screen) { commitSelection() }
            return
        }
        if model.tool == .text && !model.isReadingMode {
            textTap(p)
            return
        }
        let audio = model.audio
        if model.syncPlayback, audio.activeRecording != nil, !audio.isRecording, let date = strokeDate(at: p) {
            model.seekRecording(toStrokeDate: date)
        }
    }

    @objc private func handlePencilTap(_ g: UITapGestureRecognizer) {
        guard let page else { return }
        let screen = g.location(in: self)
        let p = screenToPage(screen)
        switch model.tool {
        case .text:
            textTap(p)
        case .mask:
            if let mask = page.masks.last(where: { $0.rect.contains(p) }) { deleteMask(mask.id) }
        case .lasso:
            if selection != nil, !selectionScreenRect.insetBy(dx: -12, dy: -12).contains(screen) { commitSelection() }
        default:
            break
        }
    }

    private func textTap(_ p: CGPoint) {
        guard let page else { return }
        if let t = page.texts.last(where: { $0.frame.contains(p) }) {
            model.requestText(at: t.origin, existing: t)
        } else if activeLayerWritable {
            model.requestText(at: p, existing: nil)
        }
    }

    @objc private func handleToolPan(_ g: UIPanGestureRecognizer) {
        let screen = g.location(in: self)
        let p = screenToPage(screen)
        let t = g.translation(in: self)
        let startScreen = CGPoint(x: screen.x - t.x, y: screen.y - t.y)
        switch model.tool {
        case .lasso: handleLassoPan(g, screen: screen, start: startScreen, point: p)
        case .mask: handleMaskPan(g, start: screenToPage(startScreen), point: p)
        case .laser: handleLaserPan(g, point: p)
        default: break
        }
    }

    // MARK: 올가미 / 선택

    private var selectionScreenRect: CGRect {
        guard let sel = selection else { return .null }
        return pageRectToScreen(sel.currentRect)
    }

    private func hitsHandle(_ screen: CGPoint) -> Bool {
        guard selection != nil else { return false }
        let r = selectionScreenRect
        return hypot(screen.x - r.maxX, screen.y - r.maxY) < EditorOverlayView.handleRadius + 14
    }

    private func handleLassoPan(_ g: UIPanGestureRecognizer, screen: CGPoint, start: CGPoint, point: CGPoint) {
        switch g.state {
        case .began:
            if let sel = selection {
                if hitsHandle(start) {
                    dragMode = .resize
                    dragOriginRect = sel.currentRect
                    selectionMenu.isHidden = true
                    return
                }
                if selectionScreenRect.insetBy(dx: -12, dy: -12).contains(start) {
                    dragMode = .move
                    dragOriginRect = sel.currentRect
                    selectionMenu.isHidden = true
                    return
                }
                commitSelection()
            }
            guard g === toolPan else { return }
            dragMode = .lasso
            lassoPoints = [screenToPage(start), point]
            updateOverlay()
        case .changed:
            switch dragMode {
            case .lasso:
                if let last = lassoPoints.last, hypot(last.x - point.x, last.y - point.y) * zoom > 2 {
                    lassoPoints.append(point)
                    updateOverlay()
                }
            case .move:
                let t = g.translation(in: self)
                selection?.currentRect = dragOriginRect.offsetBy(dx: t.x / zoom, dy: t.y / zoom)
                selection?.modified = true
                layoutFloating()
            case .resize:
                let o = dragOriginRect
                let sx = (point.x - o.minX) / max(o.width, 1)
                let sy = (point.y - o.minY) / max(o.height, 1)
                let s = max(0.1, min(max(sx, sy), 20))
                selection?.currentRect = CGRect(x: o.minX, y: o.minY, width: o.width * s, height: o.height * s)
                selection?.modified = true
                layoutFloating()
            default:
                break
            }
        case .ended, .cancelled, .failed:
            if dragMode == .lasso { finishLasso() }
            if dragMode == .resize { renderFloating() }
            dragMode = .none
            showSelectionMenu()
        default:
            break
        }
    }

    private func finishLasso() {
        guard let page, lassoPoints.count > 2 else {
            lassoPoints = []
            updateOverlay()
            return
        }
        let path = CGMutablePath()
        path.addLines(between: lassoPoints)
        path.closeSubpath()
        lassoPoints = []

        let before = snapshot()
        let editable = loadedLayers.filter { !$0.isHidden && !$0.isLocked }
        let editableIds = Set(editable.map(\.id))
        var picked: [LiftedStroke] = []
        var remaining: [UUID: PKDrawing] = [:]
        for layer in editable {
            guard let c = canvases[layer.id] else { continue }
            var keep: [PKStroke] = []
            var took = false
            for s in c.drawing.strokes {
                if strokeInside(s, path) {
                    picked.append(LiftedStroke(layer: layer.id, stroke: s))
                    took = true
                } else {
                    keep.append(s)
                }
            }
            if took {
                var d = c.drawing
                d.strokes = keep
                remaining[layer.id] = d
            }
        }
        let images = page.images.filter { editableIds.contains($0.layerId) && path.contains($0.rect.center) }
        let texts = page.texts.filter { editableIds.contains($0.layerId) && path.contains($0.frame.center) }
        guard !picked.isEmpty || !images.isEmpty || !texts.isEmpty else {
            updateOverlay()
            return
        }
        // 선택한 내용을 캔버스에서 들어 올린다 (문서에는 아직 원래 상태가 남아 있음)
        suppressSync = true
        for (id, d) in remaining { canvases[id]?.drawing = d }
        suppressSync = false
        lift(LiftedSelection(strokes: picked, images: images, texts: texts, originalBounds: .null,
                             currentRect: .null, targetLayer: nil, before: before, modified: false))
    }

    private func lift(_ newSelection: LiftedSelection) {
        var sel = newSelection
        var b = CGRect.null
        for s in sel.strokes { b = b.union(s.stroke.renderBounds) }
        for i in sel.images { b = b.union(i.rect) }
        for t in sel.texts { b = b.union(t.frame) }
        guard !b.isNull else { return }
        sel.originalBounds = b
        sel.currentRect = b
        selection = sel
        liftedDecorationIds = Set(sel.images.map(\.id) + sel.texts.map(\.id))
        rebuildDecorations()
        renderFloating()
        master?.isScrollEnabled = false
        publishLater { if !$0.hasSelection { $0.hasSelection = true } }
        updateOverlay()
        showSelectionMenu()
    }

    private func strokeInside(_ s: PKStroke, _ path: CGPath) -> Bool {
        guard path.boundingBoxOfPath.intersects(s.renderBounds) else { return false }
        var total = 0, inside = 0
        for pt in s.path.interpolatedPoints(by: .distance(4)) {
            total += 1
            if path.contains(pt.location.applying(s.transform)) { inside += 1 }
        }
        return total > 0 && Double(inside) / Double(total) >= 0.6
    }

    private func renderFloating() {
        guard let sel = selection else {
            floatingImageView.image = nil
            return
        }
        let b = sel.originalBounds.insetBy(dx: -2, dy: -2)
        let scale = min(displayScale * zoom * max(sel.scale, 1), 8)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let doc = model.doc
        floatingImageView.image = UIGraphicsImageRenderer(size: b.size, format: format).image { ctx in
            ctx.cgContext.translateBy(x: -b.minX, y: -b.minY)
            for i in sel.images { ImageCache.shared.image(at: doc.assetURL(i.file))?.draw(in: i.rect) }
            for t in sel.texts { t.draw() }
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                let d = PKDrawing(strokes: sel.strokes.map { $0.stroke })
                d.image(from: b, scale: scale).draw(in: b)
            }
        }
        floatingBaseRect = b
        layoutFloating()
    }

    private func layoutFloating() {
        guard let sel = selection else { return }
        floatingImageView.frame = floatingBaseRect.applying(sel.transform)
        updateOverlay()
        positionSelectionMenu()
    }

    private func showSelectionMenu() {
        guard selection != nil, dragMode == .none else {
            selectionMenu.isHidden = true
            return
        }
        selectionMenu.configureMenus(colors: AppSettings.shared.penColors, layers: loadedLayers)
        selectionMenu.isHidden = false
        positionSelectionMenu()
    }

    private func positionSelectionMenu() {
        guard selection != nil, !selectionMenu.isHidden else { return }
        let r = selectionScreenRect
        let size = selectionMenu.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        var y = r.minY - size.height - 16
        if y < 8 { y = r.maxY + 20 }
        y = max(8, min(y, bounds.height - size.height - 8))
        let x = max(8, min(r.midX - size.width / 2, bounds.width - size.width - 8))
        selectionMenu.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// 선택을 내려놓고 변경 사항을 문서에 반영 (실행 취소 가능)
    func commitSelection() {
        guard let sel = selection, var newPage = page else { return }
        selection = nil
        let T = sel.transform
        if !sel.modified && sel.targetLayer == nil {
            // 바뀐 게 없으면 원래 상태 그대로 복원 (획 순서도 유지)
            clearSelectionUI()
            applyState(sel.before)
            return
        }
        var drawings: [UUID: PKDrawing] = [:]
        for (id, c) in canvases { drawings[id] = c.drawing }
        for ls in sel.strokes {
            var s = ls.stroke
            s.transform = s.transform.concatenating(T)
            let target = sel.targetLayer ?? ls.layer
            drawings[target, default: PKDrawing()].strokes.append(s)
        }
        let s = sel.scale
        for img in sel.images {
            var moved = img
            moved.rect = img.rect.applying(T)
            if let t = sel.targetLayer { moved.layerId = t }
            if let i = newPage.images.firstIndex(where: { $0.id == img.id }) { newPage.images[i] = moved } else { newPage.images.append(moved) }
        }
        for text in sel.texts {
            var moved = text
            moved.origin = text.origin.applying(T)
            moved.fontSize = text.fontSize * s
            moved.width = text.width * s
            if let t = sel.targetLayer { moved.layerId = t }
            if let i = newPage.texts.firstIndex(where: { $0.id == text.id }) { newPage.texts[i] = moved } else { newPage.texts.append(moved) }
        }
        clearSelectionUI()
        commitChange(to: PageSnapshot(drawings: drawings, page: newPage), from: sel.before, actionName: "선택 편집")
    }

    /// 실행 취소 직전: 들어 올린 선택을 반영하지 않고 버림 (before 상태로 되돌아가므로)
    private func cancelSelectionWithoutApplying() {
        guard selection != nil else { return }
        selection = nil
        clearSelectionUI()
    }

    private func clearSelectionUI() {
        liftedDecorationIds = []
        floatingImageView.image = nil
        selectionMenu.isHidden = true
        master?.isScrollEnabled = true
        publishLater { [weak self] m in
            if self?.selection == nil, m.hasSelection { m.hasSelection = false }
        }
        updateOverlay()
        rebuildDecorations()
    }

    func deleteSelection() {
        guard let sel = selection, var newPage = page else { return }
        selection = nil
        let liftedIds = Set(sel.images.map(\.id) + sel.texts.map(\.id))
        newPage.images.removeAll { liftedIds.contains($0.id) }
        newPage.texts.removeAll { liftedIds.contains($0.id) }
        var drawings: [UUID: PKDrawing] = [:]
        for (id, c) in canvases { drawings[id] = c.drawing }
        clearSelectionUI()
        commitChange(to: PageSnapshot(drawings: drawings, page: newPage), from: sel.before, actionName: "삭제")
    }

    func copySelection() {
        guard let sel = selection else { return }
        let T = sel.transform
        let strokes = sel.strokes.map { ls -> PKStroke in
            var s = ls.stroke
            s.transform = s.transform.concatenating(T)
            return s
        }
        let images: [EditorClipboard.ImageItem] = sel.images.compactMap { img in
            guard let data = try? Data(contentsOf: model.doc.assetURL(img.file)) else { return nil }
            var moved = img
            moved.rect = img.rect.applying(T)
            return EditorClipboard.ImageItem(image: moved, data: data)
        }
        let texts = sel.texts.map { t -> PageText in
            var moved = t
            moved.origin = t.origin.applying(T)
            moved.fontSize = t.fontSize * sel.scale
            moved.width = t.width * sel.scale
            return moved
        }
        EditorClipboard.shared.set(strokes: strokes, images: images, texts: texts)
        model.showToast("복사했어요")
    }

    func duplicateSelection() {
        copySelection()
        commitSelection()
        paste(offset: CGPoint(x: 24, y: 24))
    }

    /// 클립보드 내용을 새 선택으로 붙여넣는다
    func paste(offset: CGPoint? = nil) {
        let clip = EditorClipboard.shared
        guard !clip.isEmpty, page != nil, activeLayerWritable else { return }
        commitSelection()
        let layerId = model.doc.notebook.activeLayerId
        var strokes = clip.strokes
        var images: [PageImage] = clip.images.compactMap { item in
            guard let saved = model.doc.saveImage(item.data) else { return nil }
            var img = item.image
            img.id = UUID()
            img.file = saved.name
            img.layerId = layerId
            return img
        }
        var texts = clip.texts.map { t -> PageText in
            var n = t
            n.id = UUID()
            n.layerId = layerId
            return n
        }
        // 기본: 보이는 영역 가운데로
        var bounds = CGRect.null
        for s in strokes { bounds = bounds.union(s.renderBounds) }
        for i in images { bounds = bounds.union(i.rect) }
        for t in texts { bounds = bounds.union(t.frame) }
        guard !bounds.isNull else { return }
        let d: CGPoint
        if let offset {
            d = offset
        } else {
            let v = visiblePageRect
            d = CGPoint(x: v.midX - bounds.midX, y: v.midY - bounds.midY)
        }
        let shift = CGAffineTransform(translationX: d.x, y: d.y)
        strokes = strokes.map { var s = $0; s.transform = s.transform.concatenating(shift); return s }
        images = images.map { var i = $0; i.rect = i.rect.applying(shift); return i }
        texts = texts.map { var t = $0; t.origin = t.origin.applying(shift); return t }
        insertFloating(strokes: strokes, images: images, texts: texts)
    }

    /// 아직 페이지에 없는 내용을 선택 상태로 띄운다 (도형·사진·붙여넣기)
    private func insertFloating(strokes: [PKStroke], images: [PageImage], texts: [PageText]) {
        guard var p = page else { return }
        let layerId = model.doc.notebook.activeLayerId
        let before = snapshot()
        // 사진·텍스트는 페이지에 먼저 넣고 들어 올린 상태로 표시
        p.images.append(contentsOf: images)
        p.texts.append(contentsOf: texts)
        page = p
        let sel = LiftedSelection(strokes: strokes.map { LiftedStroke(layer: layerId, stroke: $0) },
                                  images: images, texts: texts, originalBounds: .null, currentRect: .null,
                                  targetLayer: nil, before: before, modified: true)
        if model.tool != .lasso { model.tool = .lasso }
        lift(sel)
    }

    func insertShape(_ kind: ShapeKind) {
        guard page != nil, activeLayerWritable else {
            model.showToast("잠기거나 숨긴 레이어에는 추가할 수 없어요")
            return
        }
        commitSelection()
        let size = kind.defaultSize
        let v = visiblePageRect
        let rect = CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height)
        let (ink, width) = model.shapeInk
        insertFloating(strokes: ShapeFactory.strokes(kind: kind, in: rect, ink: ink, width: width), images: [], texts: [])
    }

    func insertImage(name: String, size: CGSize) {
        guard page != nil, activeLayerWritable else {
            model.showToast("잠기거나 숨긴 레이어에는 추가할 수 없어요")
            return
        }
        commitSelection()
        let v = visiblePageRect
        let maxW = v.width * 0.6, maxH = v.height * 0.6
        let s = min(maxW / max(size.width, 1), maxH / max(size.height, 1), 1)
        let w = size.width * s, h = size.height * s
        let img = PageImage(file: name, rect: CGRect(x: v.midX - w / 2, y: v.midY - h / 2, width: w, height: h),
                            layerId: model.doc.notebook.activeLayerId)
        insertFloating(strokes: [], images: [img], texts: [])
    }

    private func recolorSelection(_ hex: String) {
        guard var sel = selection else { return }
        let color = UIColor(hex: hex)
        sel.strokes = sel.strokes.map { ls in
            var n = ls
            n.stroke.ink = PKInk(ls.stroke.ink.inkType, color: color)
            return n
        }
        sel.texts = sel.texts.map { var t = $0; t.colorHex = hex; return t }
        sel.modified = true
        selection = sel
        renderFloating()
    }

    private func moveSelection(toLayer id: UUID) {
        guard selection != nil else { return }
        selection?.targetLayer = id
        selection?.modified = true
        let name = loadedLayers.first { $0.id == id }?.name ?? ""
        commitSelection()
        model.showToast("'\(name)' 레이어로 옮겼어요")
    }

    private func sendSelectionToWrongAnswers() {
        guard let sel = selection, let page else { return }
        let rect = sel.currentRect
        let pageId = page.id
        commitSelection()
        model.addWrongAnswer(pageId: pageId, rect: rect)
    }

    // MARK: 가림막

    private func handleMaskPan(_ g: UIPanGestureRecognizer, start: CGPoint, point: CGPoint) {
        guard let page else { return }
        switch g.state {
        case .began, .changed:
            dragMode = .mask
            maskDraft = CGRect(corner: start, point).intersection(page.bounds)
            updateOverlay()
        case .ended:
            dragMode = .none
            if let r = maskDraft, r.width > 8, r.height > 8 { addMask(r) }
            maskDraft = nil
            updateOverlay()
        default:
            dragMode = .none
            maskDraft = nil
            updateOverlay()
        }
    }

    private func addMask(_ rect: CGRect) {
        guard var p = page else { return }
        let before = snapshot()
        p.masks.append(MaskRect(rect: rect, colorHex: model.maskColorHex))
        commitChange(to: PageSnapshot(drawings: before.drawings, page: p), from: before, actionName: "가림막")
    }

    private func deleteMask(_ id: UUID) {
        guard var p = page else { return }
        let before = snapshot()
        p.masks.removeAll { $0.id == id }
        commitChange(to: PageSnapshot(drawings: before.drawings, page: p), from: before, actionName: "가림막 삭제")
    }

    // MARK: 레이저 포인터

    private func handleLaserPan(_ g: UIPanGestureRecognizer, point: CGPoint) {
        switch g.state {
        case .began, .changed:
            laserPoints.append((point, CACurrentMediaTime()))
            if displayLink == nil {
                let link = CADisplayLink(target: self, selector: #selector(laserTick))
                link.add(to: .main, forMode: .common)
                displayLink = link
            }
            updateOverlay()
        default:
            break
        }
    }

    @objc private func laserTick() {
        let now = CACurrentMediaTime()
        laserPoints.removeAll { now - $0.time > 0.6 }
        updateOverlay()
        if laserPoints.isEmpty {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    // MARK: 녹음 동기화

    /// 탭한 위치 근처 획의 생성 시각
    private func strokeDate(at p: CGPoint) -> Date? {
        let tol = 14 / zoom
        var best: (date: Date, dist: CGFloat)?
        for layer in loadedLayers where !layer.isHidden {
            guard let c = canvases[layer.id] else { continue }
            for s in c.drawing.strokes where s.renderBounds.insetBy(dx: -tol, dy: -tol).contains(p) {
                for pt in s.path.interpolatedPoints(by: .distance(3)) {
                    let q = pt.location.applying(s.transform)
                    let d = hypot(q.x - p.x, q.y - p.y)
                    if d < tol, d < (best?.dist ?? .greatestFiniteMagnitude) {
                        best = (s.path.creationDate, d)
                    }
                }
            }
        }
        return best?.date
    }

    // MARK: 오버레이

    private func updateOverlay() {
        overlay.update(lasso: lassoPoints.map(pageToScreen),
                       selection: selection == nil ? nil : selectionScreenRect.insetBy(dx: -4, dy: -4),
                       draft: maskDraft.map(pageRectToScreen),
                       laser: laserPoints.map { pageToScreen($0.point) })
    }
}
