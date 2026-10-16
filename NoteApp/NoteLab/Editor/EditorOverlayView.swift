import UIKit

/// 화면 좌표계 오버레이: 올가미 경로, 선택 영역, 가림막 초안, 레이저 포인터
/// (확대해도 선이 흐려지지 않도록 페이지가 아니라 화면 좌표로 그린다)
final class EditorOverlayView: UIView {
    private let lassoLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let draftLayer = CAShapeLayer()
    private let laserGlow = CAShapeLayer()
    private let laserCore = CAShapeLayer()

    static let handleRadius: CGFloat = 10

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        lassoLayer.strokeColor = UIColor.systemBlue.cgColor
        lassoLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.06).cgColor
        lassoLayer.lineWidth = 1.5
        lassoLayer.lineDashPattern = [6, 4]

        selectionLayer.strokeColor = UIColor.systemBlue.cgColor
        selectionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.04).cgColor
        selectionLayer.lineWidth = 1.2
        selectionLayer.lineDashPattern = [5, 4]

        handleLayer.fillColor = UIColor.white.cgColor
        handleLayer.strokeColor = UIColor.systemBlue.cgColor
        handleLayer.lineWidth = 2

        draftLayer.strokeColor = UIColor.systemRed.cgColor
        draftLayer.fillColor = UIColor.systemRed.withAlphaComponent(0.25).cgColor
        draftLayer.lineWidth = 1
        draftLayer.lineDashPattern = [4, 3]

        for l in [laserGlow, laserCore] {
            l.fillColor = nil
            l.lineCap = .round
            l.lineJoin = .round
        }
        laserGlow.strokeColor = UIColor.systemRed.withAlphaComponent(0.35).cgColor
        laserGlow.lineWidth = 12
        laserCore.strokeColor = UIColor(red: 1, green: 0.2, blue: 0.2, alpha: 1).cgColor
        laserCore.lineWidth = 4

        for l in [lassoLayer, selectionLayer, handleLayer, draftLayer, laserGlow, laserCore] { layer.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(lasso: [CGPoint], selection: CGRect?, draft: CGRect?, laser: [CGPoint]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if lasso.count > 1 {
            let p = CGMutablePath()
            p.addLines(between: lasso)
            lassoLayer.path = p
        } else {
            lassoLayer.path = nil
        }
        if let r = selection {
            selectionLayer.path = CGPath(rect: r, transform: nil)
            let h = Self.handleRadius
            handleLayer.path = CGPath(ellipseIn: CGRect(x: r.maxX - h, y: r.maxY - h, width: h * 2, height: h * 2), transform: nil)
        } else {
            selectionLayer.path = nil
            handleLayer.path = nil
        }
        draftLayer.path = draft.map { CGPath(rect: $0, transform: nil) }
        if laser.count > 1 {
            let p = CGMutablePath()
            p.addLines(between: laser)
            laserGlow.path = p
            laserCore.path = p
        } else if let only = laser.first {
            let dot = CGPath(ellipseIn: CGRect(x: only.x - 1, y: only.y - 1, width: 2, height: 2), transform: nil)
            laserGlow.path = dot
            laserCore.path = dot
        } else {
            laserGlow.path = nil
            laserCore.path = nil
        }
        CATransaction.commit()
    }
}
