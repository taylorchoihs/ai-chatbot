import UIKit

/// 올가미 선택 위에 뜨는 메뉴
final class SelectionMenuView: UIView {
    var onCopy: (() -> Void)?
    var onCut: (() -> Void)?
    var onDelete: (() -> Void)?
    var onDuplicate: (() -> Void)?
    var onWrongAnswer: (() -> Void)?
    var onDone: (() -> Void)?
    var onColor: ((String) -> Void)?
    var onLayer: ((UUID) -> Void)?

    private let stack = UIStackView()
    private let colorButton = UIButton(type: .system)
    private let layerButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.layer.cornerRadius = 14
        blur.clipsToBounds = true
        addSubview(blur)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)

        stack.axis = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])

        stack.addArrangedSubview(makeButton("복사", "doc.on.doc") { [weak self] in self?.onCopy?() })
        stack.addArrangedSubview(makeButton("잘라내기", "scissors") { [weak self] in self?.onCut?() })
        stack.addArrangedSubview(makeButton("복제", "plus.square.on.square") { [weak self] in self?.onDuplicate?() })
        stack.addArrangedSubview(makeButton("삭제", "trash") { [weak self] in self?.onDelete?() })
        configure(colorButton, "색상", "paintpalette")
        configure(layerButton, "레이어", "square.3.layers.3d")
        colorButton.showsMenuAsPrimaryAction = true
        layerButton.showsMenuAsPrimaryAction = true
        stack.addArrangedSubview(colorButton)
        stack.addArrangedSubview(layerButton)
        stack.addArrangedSubview(makeButton("오답노트", "checkmark.circle.badge.xmark") { [weak self] in self?.onWrongAnswer?() })
        stack.addArrangedSubview(makeButton("완료", "checkmark") { [weak self] in self?.onDone?() })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configureMenus(colors: [String], layers: [LayerInfo]) {
        colorButton.menu = UIMenu(title: "색상 변경", children: colors.map { hex in
            UIAction(title: hex, image: swatch(UIColor(hex: hex))) { [weak self] _ in self?.onColor?(hex) }
        })
        layerButton.menu = UIMenu(title: "레이어로 이동", children: layers.map { layer in
            UIAction(title: layer.name + (layer.isAnswer ? " ★" : ""),
                     image: UIImage(systemName: layer.isLocked ? "lock" : "square.3.layers.3d"),
                     attributes: layer.isLocked ? [.disabled] : []) { [weak self] _ in self?.onLayer?(layer.id) }
        })
    }

    private func configure(_ b: UIButton, _ title: String, _ symbol: String) {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: symbol)
        config.title = title
        config.imagePlacement = .top
        config.imagePadding = 3
        config.buttonSize = .mini
        config.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)
        b.configuration = config
    }

    private func makeButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> UIButton {
        let b = UIButton(type: .system, primaryAction: UIAction { _ in action() })
        configure(b, title, symbol)
        return b
    }

    private func swatch(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 22, height: 22)).image { _ in
            color.setFill()
            UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 20, height: 20)).fill()
            UIColor.separator.setStroke()
            UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: 20, height: 20)).stroke()
        }.withRenderingMode(.alwaysOriginal)
    }
}
