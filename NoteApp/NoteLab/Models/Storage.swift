import Foundation

/// 파일 기반 저장소 레이아웃
///
/// Application Support/NoteLabLibrary/
///   library.json                      폴더 + 노트 요약
///   Notebooks/<id>/notebook.json      페이지, 레이어, 녹음 메타데이터
///   Notebooks/<id>/ink/<page>/<layer>.drawing   PencilKit 데이터 (페이지·레이어별)
///   Notebooks/<id>/thumbs/<page>.jpg  썸네일 캐시
///   Notebooks/<id>/assets/            PDF 원본, 이미지
///   Notebooks/<id>/recordings/        녹음 파일
///   Notebooks/<id>/search.json        검색 색인 (PDF 텍스트 + 손글씨 인식)
///   WrongAnswers/items.json, *.jpg    오답노트
/// Documents/Backups/                  백업 (파일 앱에서 보임)
enum Storage {
    static let fm = FileManager.default

    static let root: URL = {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("NoteLabLibrary", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var documents: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    static var libraryFile: URL { root.appendingPathComponent("library.json") }
    static var notebooksDir: URL { root.appendingPathComponent("Notebooks", isDirectory: true) }

    static func notebookDir(_ id: UUID) -> URL {
        notebooksDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }
    static func notebookFile(_ id: UUID) -> URL { notebookDir(id).appendingPathComponent("notebook.json") }
    static func searchIndexFile(_ id: UUID) -> URL { notebookDir(id).appendingPathComponent("search.json") }

    static func inkDir(_ id: UUID, page: UUID) -> URL {
        notebookDir(id).appendingPathComponent("ink", isDirectory: true)
            .appendingPathComponent(page.uuidString, isDirectory: true)
    }
    static func inkFile(_ id: UUID, page: UUID, layer: UUID) -> URL {
        inkDir(id, page: page).appendingPathComponent("\(layer.uuidString).drawing")
    }
    static func thumbFile(_ id: UUID, page: UUID) -> URL {
        notebookDir(id).appendingPathComponent("thumbs", isDirectory: true)
            .appendingPathComponent("\(page.uuidString).jpg")
    }
    static func assetFile(_ id: UUID, name: String) -> URL {
        notebookDir(id).appendingPathComponent("assets", isDirectory: true).appendingPathComponent(name)
    }
    static func recordingFile(_ id: UUID, name: String) -> URL {
        notebookDir(id).appendingPathComponent("recordings", isDirectory: true).appendingPathComponent(name)
    }

    static var wrongDir: URL { root.appendingPathComponent("WrongAnswers", isDirectory: true) }
    static var wrongFile: URL { wrongDir.appendingPathComponent("items.json") }
    static func wrongImage(_ name: String) -> URL { wrongDir.appendingPathComponent(name) }

    static var backupsDir: URL {
        let url = documents.appendingPathComponent("Backups", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func ensureParent(_ url: URL) {
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        ensureParent(url)
        try data.write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
