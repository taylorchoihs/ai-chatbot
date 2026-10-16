import Foundation

enum PencilDoubleTapAction: String, CaseIterable, Identifiable {
    case system, eraser, previous, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "시스템 설정 따르기"
        case .eraser: return "지우개 전환"
        case .previous: return "이전 도구로 전환"
        case .none: return "사용 안 함"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var fingerDrawing: Bool { didSet { d.set(fingerDrawing, forKey: "fingerDrawing") } }
    @Published var shapeSnap: Bool { didSet { d.set(shapeSnap, forKey: "shapeSnap") } }
    @Published var swipeToTurnPage: Bool { didSet { d.set(swipeToTurnPage, forKey: "swipeToTurnPage") } }
    @Published var pencilDoubleTap: PencilDoubleTapAction { didSet { d.set(pencilDoubleTap.rawValue, forKey: "pencilDoubleTap") } }
    @Published var autoBackup: Bool { didSet { d.set(autoBackup, forKey: "autoBackup") } }
    @Published var handwritingIndexing: Bool { didSet { d.set(handwritingIndexing, forKey: "handwritingIndexing") } }
    @Published var penColors: [String] { didSet { d.set(penColors, forKey: "penColors") } }
    @Published var highlighterColors: [String] { didSet { d.set(highlighterColors, forKey: "highlighterColors") } }

    static let defaultPenColors = ["#1C1C1EFF", "#2F5BEAFF", "#E5484DFF", "#30A46CFF", "#F76B15FF", "#8E4EC6FF", "#FFFFFFFF"]
    static let defaultHighlighterColors = ["#FFE066FF", "#A8E6A1FF", "#9AD0FFFF", "#FFB3C7FF", "#D9B8FFFF"]

    private init() {
        fingerDrawing = d.object(forKey: "fingerDrawing") as? Bool ?? false
        shapeSnap = d.object(forKey: "shapeSnap") as? Bool ?? false
        swipeToTurnPage = d.object(forKey: "swipeToTurnPage") as? Bool ?? true
        pencilDoubleTap = PencilDoubleTapAction(rawValue: d.string(forKey: "pencilDoubleTap") ?? "") ?? .system
        autoBackup = d.object(forKey: "autoBackup") as? Bool ?? true
        handwritingIndexing = d.object(forKey: "handwritingIndexing") as? Bool ?? true
        penColors = d.stringArray(forKey: "penColors") ?? Self.defaultPenColors
        highlighterColors = d.stringArray(forKey: "highlighterColors") ?? Self.defaultHighlighterColors
    }
}
