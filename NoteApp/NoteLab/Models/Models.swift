import Foundation
import CoreGraphics
import UIKit

// MARK: - 용지

enum PaperStyle: String, Codable, CaseIterable, Identifiable {
    case blank, lined, narrowLined, grid, dotted, cornell, music, todo
    var id: String { rawValue }
    var title: String {
        switch self {
        case .blank: return "무지"
        case .lined: return "줄노트"
        case .narrowLined: return "좁은 줄"
        case .grid: return "모눈"
        case .dotted: return "점 모눈"
        case .cornell: return "코넬"
        case .music: return "오선지"
        case .todo: return "체크리스트"
        }
    }
}

enum PaperColor: String, Codable, CaseIterable, Identifiable {
    case white, cream, green, gray, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .white: return "흰색"
        case .cream: return "크림"
        case .green: return "연두"
        case .gray: return "회색"
        case .dark: return "다크"
        }
    }
    var fillHex: String {
        switch self {
        case .white: return "#FFFFFF"
        case .cream: return "#FBF6E9"
        case .green: return "#EEF5EC"
        case .gray: return "#F1F1F3"
        case .dark: return "#2B2D31"
        }
    }
    var lineHex: String {
        switch self {
        case .white: return "#C9D3E0"
        case .cream: return "#DED3B6"
        case .green: return "#C3D8BE"
        case .gray: return "#CFCFD6"
        case .dark: return "#50545C"
        }
    }
    var fill: UIColor { UIColor(hex: fillHex) }
    var line: UIColor { UIColor(hex: lineHex) }
}

enum PaperSize: String, Codable, CaseIterable, Identifiable {
    case a4Portrait, a4Landscape, b5Portrait, letterPortrait, widescreen, square
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .a4Portrait: return CGSize(width: 595, height: 842)
        case .a4Landscape: return CGSize(width: 842, height: 595)
        case .b5Portrait: return CGSize(width: 516, height: 729)
        case .letterPortrait: return CGSize(width: 612, height: 792)
        case .widescreen: return CGSize(width: 960, height: 540)
        case .square: return CGSize(width: 700, height: 700)
        }
    }
    var title: String {
        switch self {
        case .a4Portrait: return "A4 세로"
        case .a4Landscape: return "A4 가로"
        case .b5Portrait: return "B5 세로"
        case .letterPortrait: return "레터"
        case .widescreen: return "16:9 슬라이드"
        case .square: return "정사각형"
        }
    }
}

enum PageBackground: Codable, Equatable {
    case paper(style: PaperStyle, color: PaperColor)
    case pdf(file: String, index: Int)
}

// MARK: - 페이지 구성 요소

struct LayerInfo: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var isHidden = false
    var isLocked = false
    /// 정답 레이어: 노트 전체에서 한 번에 숨기기/보이기
    var isAnswer = false
}

struct PageImage: Codable, Identifiable, Equatable {
    var id = UUID()
    var file: String
    var rect: CGRect
    var layerId: UUID
}

struct PageText: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var origin: CGPoint
    var width: CGFloat = 320
    var fontSize: CGFloat = 18
    var colorHex: String = "#1C1C1EFF"
    var layerId: UUID

    var font: UIFont { .systemFont(ofSize: fontSize) }
    var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: UIColor(hex: colorHex)]
    }
    var frame: CGRect {
        let bound = ((text.isEmpty ? " " : text) as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes, context: nil)
        return CGRect(origin: origin, size: CGSize(width: ceil(bound.width) + 8, height: ceil(bound.height) + 8))
    }
    /// 현재 UIGraphics 컨텍스트에 그린다.
    func draw() {
        (text as NSString).draw(with: frame.insetBy(dx: 4, dy: 4),
                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                attributes: attributes, context: nil)
    }
}

/// 가림막: 답을 가려 두고 탭해서 확인
struct MaskRect: Codable, Identifiable, Equatable {
    var id = UUID()
    var rect: CGRect
    var colorHex: String
}

struct Page: Codable, Identifiable, Equatable {
    var id = UUID()
    var size: CGSize
    var background: PageBackground
    var images: [PageImage] = []
    var texts: [PageText] = []
    var masks: [MaskRect] = []
    var isBookmarked = false

    var bounds: CGRect { CGRect(origin: .zero, size: size) }
}

struct Recording: Codable, Identifiable, Equatable {
    var id = UUID()
    var file: String
    var startDate: Date
    var duration: TimeInterval
    var title: String

    var endDate: Date { startDate.addingTimeInterval(duration) }
}

// MARK: - 노트북

struct Notebook: Codable, Identifiable {
    var id = UUID()
    var title: String
    var folderId: UUID?
    var createdAt = Date()
    var modifiedAt = Date()
    var coverHex: String
    var pages: [Page]
    var layers: [LayerInfo]
    var activeLayerId: UUID
    var recordings: [Recording] = []
    var lastPageIndex = 0
    var isFavorite = false

    static let maxLayers = 5

    static func make(title: String, folderId: UUID?, coverHex: String, pages: [Page]) -> Notebook {
        let layer = LayerInfo(name: "필기 1")
        return Notebook(title: title, folderId: folderId, coverHex: coverHex, pages: pages,
                        layers: [layer], activeLayerId: layer.id)
    }

    var meta: NotebookMeta {
        NotebookMeta(id: id, title: title, folderId: folderId, createdAt: createdAt, modifiedAt: modifiedAt,
                     coverHex: coverHex, pageCount: pages.count, firstPageId: pages.first?.id,
                     firstPageSize: pages.first?.size, isFavorite: isFavorite, lastOpenedAt: nil)
    }
}

/// 라이브러리 화면용 요약 정보 (전체 노트를 열지 않고 목록 표시)
struct NotebookMeta: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var folderId: UUID?
    var createdAt: Date
    var modifiedAt: Date
    var coverHex: String
    var pageCount: Int
    var firstPageId: UUID?
    var firstPageSize: CGSize?
    var isFavorite: Bool
    var lastOpenedAt: Date?
}

// MARK: - 과목 폴더 (시험 D-day, 공부 시간)

struct Folder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var colorHex: String
    var examTitle: String = ""
    var examDate: Date?
    /// "yyyy-MM-dd" -> 초
    var studyLog: [String: Double] = [:]

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ date: Date) -> String { dayFormatter.string(from: date) }

    var todaySeconds: Double { studyLog[Self.dayKey(Date())] ?? 0 }
    var totalSeconds: Double { studyLog.values.reduce(0, +) }

    /// 최근 7일 (오래된 날 → 오늘)
    var lastSevenDays: [(label: String, seconds: Double)] {
        let cal = Calendar.current
        return (0..<7).reversed().map { offset in
            let day = cal.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
            let label = offset == 0 ? "오늘" : "\(cal.component(.day, from: day))일"
            return (label: label, seconds: studyLog[Self.dayKey(day)] ?? 0)
        }
    }

    var daysUntilExam: Int? {
        guard let examDate else { return nil }
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date()), to: cal.startOfDay(for: examDate)).day
    }

    var dDayText: String? {
        guard let d = daysUntilExam else { return nil }
        if d == 0 { return "D-Day" }
        return d > 0 ? "D-\(d)" : "D+\(-d)"
    }
}

// MARK: - 오답노트

struct Attempt: Codable, Equatable {
    var date: Date
    var correct: Bool
}

struct WrongAnswerItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var createdAt = Date()
    var notebookId: UUID
    var notebookTitle: String
    var pageId: UUID
    var rect: CGRect
    var questionFile: String
    var answerFile: String?
    var folderId: UUID?
    var memo: String = ""
    var attempts: [Attempt] = []

    var correctCount: Int { attempts.filter(\.correct).count }
    var wrongCount: Int { attempts.filter { !$0.correct }.count }
    var lastResult: Bool? { attempts.last?.correct }
}

// MARK: - 검색 색인

struct PageSearchEntry: Codable {
    var pdfText: String = ""
    var inkText: String = ""
}

struct NotebookSearchIndex: Codable {
    var pages: [String: PageSearchEntry] = [:]
}
