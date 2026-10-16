import Foundation

/// 라이브러리 전체를 Documents/Backups 폴더로 복사한다.
/// Documents는 파일 앱(나의 iPad › NoteLab)에서 보이므로 iCloud Drive 등으로 옮길 수 있다.
enum BackupService {
    struct BackupInfo: Identifiable {
        var id: URL { url }
        let url: URL
        let name: String
        let date: Date
        let size: Int64
    }

    private static let lastKey = "lastAutoBackup"
    private static let autoPrefix = "자동"

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return f
    }()

    @MainActor
    static func runAutoBackupIfNeeded() {
        guard AppSettings.shared.autoBackup else { return }
        let last = UserDefaults.standard.object(forKey: lastKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 60 * 60 * 20 else { return }
        guard !LibraryStore.shared.notebooks.isEmpty else { return }
        LibraryStore.shared.saveNow()
        NotebookDocument.flushAll()
        UserDefaults.standard.set(Date(), forKey: lastKey)
        NotebookDocument.ioQueue.async {
            _ = try? createBackup(prefix: autoPrefix)
            prune(prefix: autoPrefix, keep: 5)
        }
    }

    @discardableResult
    static func createBackup(prefix: String = "수동") throws -> URL {
        let name = "\(prefix) 백업 \(nameFormatter.string(from: Date()))"
        let dest = Storage.backupsDir.appendingPathComponent(name, isDirectory: true)
        try Storage.fm.copyItem(at: Storage.root, to: dest)
        return dest
    }

    static func listBackups() -> [BackupInfo] {
        let keys: [URLResourceKey] = [.creationDateKey, .isDirectoryKey]
        let items = (try? Storage.fm.contentsOfDirectory(at: Storage.backupsDir, includingPropertiesForKeys: keys)) ?? []
        return items.compactMap { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true else { return nil }
            return BackupInfo(url: url, name: url.lastPathComponent, date: values?.creationDate ?? .distantPast,
                              size: directorySize(url))
        }
        .sorted { $0.date > $1.date }
    }

    static func delete(_ url: URL) { try? Storage.fm.removeItem(at: url) }

    static func isValidBackup(_ url: URL) -> Bool {
        Storage.fm.fileExists(atPath: url.appendingPathComponent("library.json").path)
            || Storage.fm.fileExists(atPath: url.appendingPathComponent("Notebooks").path)
    }

    /// 현재 라이브러리를 "복원 전" 백업으로 남긴 뒤 교체한다.
    @MainActor
    static func restore(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard isValidBackup(url) else {
            throw NSError(domain: "NoteLab", code: 1, userInfo: [NSLocalizedDescriptionKey: "NoteLab 백업 폴더가 아닙니다."])
        }
        LibraryStore.shared.saveNow()
        NotebookDocument.flushAll()
        NotebookDocument.ioQueue.sync {}
        try createBackup(prefix: "복원 전")
        NotebookDocument.discardAll()
        let children = (try? Storage.fm.contentsOfDirectory(at: Storage.root, includingPropertiesForKeys: nil)) ?? []
        for c in children { try Storage.fm.removeItem(at: c) }
        let sources = try Storage.fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        for s in sources {
            try Storage.fm.copyItem(at: s, to: Storage.root.appendingPathComponent(s.lastPathComponent))
        }
        LibraryStore.shared.reload()
    }

    private static func prune(prefix: String, keep: Int) {
        let mine = listBackups().filter { $0.name.hasPrefix(prefix) }
        for b in mine.dropFirst(keep) { delete(b.url) }
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let e = Storage.fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
