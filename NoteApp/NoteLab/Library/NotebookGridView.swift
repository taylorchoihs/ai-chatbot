import SwiftUI
import UniformTypeIdentifiers

enum NotebookSort: String, CaseIterable, Identifiable {
    case modified, created, title
    var id: String { rawValue }
    var title: String {
        switch self {
        case .modified: return "수정한 날짜"
        case .created: return "만든 날짜"
        case .title: return "이름"
        }
    }
}

struct NotebookGridView: View {
    let section: LibrarySection
    let onOpen: (UUID) -> Void
    let onEditFolder: (Folder) -> Void

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @AppStorage("library.sort") private var sort: NotebookSort = .modified
    @State private var query = ""
    @State private var showNew = false
    @State private var showImporter = false
    @State private var renaming: NotebookMeta?
    @State private var renameText = ""
    @State private var deleting: NotebookMeta?
    @State private var importError = false

    private var folderId: UUID? {
        if case let .folder(id) = section { return id }
        return nil
    }

    private var title: String {
        switch section {
        case .all: return "모든 노트"
        case .favorites: return "즐겨찾기"
        case .recent: return "최근 연 노트"
        case .unfiled: return "미분류"
        case .folder: return library.folder(folderId)?.name ?? "폴더"
        case .wrongAnswers: return "오답노트"
        }
    }

    private var items: [NotebookMeta] {
        var list = library.notebooks
        switch section {
        case .all, .wrongAnswers: break
        case .favorites: list = list.filter(\.isFavorite)
        case .recent: list = list.filter { $0.lastOpenedAt != nil }
        case .unfiled: list = list.filter { $0.folderId == nil }
        case let .folder(id): list = list.filter { $0.folderId == id }
        }
        if !query.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        if section == .recent {
            return list.sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        }
        switch sort {
        case .modified: return list.sorted { $0.modifiedAt > $1.modifiedAt }
        case .created: return list.sorted { $0.createdAt > $1.createdAt }
        case .title: return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        ScrollView {
            if let folder = library.folder(folderId) {
                FolderHeaderCard(folder: folder) { onEditFolder(folder) }
                    .padding(.horizontal)
                    .padding(.top, 8)
            }
            if items.isEmpty {
                ContentUnavailableView {
                    Label(query.isEmpty ? "노트가 없어요" : "검색 결과가 없어요", systemImage: "book.closed")
                } description: {
                    Text(query.isEmpty ? "새 노트를 만들거나 PDF를 가져와 보세요." : "다른 단어로 찾아보세요.")
                } actions: {
                    if query.isEmpty {
                        Button("새 노트") { showNew = true }.buttonStyle(.borderedProminent)
                        Button("PDF 가져오기") { showImporter = true }
                    }
                }
                .padding(.top, 60)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 24)], spacing: 28) {
                    ForEach(items) { meta in
                        NotebookCard(meta: meta, folder: library.folder(meta.folderId))
                            .onTapGesture { onOpen(meta.id) }
                            .contextMenu { contextMenu(for: meta) }
                    }
                }
                .padding(24)
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, prompt: "노트 제목 검색")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("정렬", selection: $sort) {
                        ForEach(NotebookSort.allCases) { Text($0.title).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showNew = true } label: { Label("새 노트", systemImage: "square.and.pencil") }
                    Button { showImporter = true } label: { Label("PDF 가져오기", systemImage: "doc.richtext") }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $showNew) {
            NewNotebookSheet(defaultFolderId: folderId) { id in onOpen(id) }
                .environmentObject(library)
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            guard case let .success(urls) = result else { return }
            var last: UUID?
            for url in urls {
                if let id = library.importPDF(from: url, folderId: folderId) { last = id } else { importError = true }
            }
            if urls.count == 1, let last { onOpen(last) }
        }
        .alert("PDF를 가져올 수 없어요", isPresented: $importError) { Button("확인", role: .cancel) {} }
        .alert("이름 변경", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("제목", text: $renameText)
            Button("저장") {
                if let r = renaming, !renameText.trimmingCharacters(in: .whitespaces).isEmpty {
                    library.rename(r.id, to: renameText)
                }
                renaming = nil
            }
            Button("취소", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("노트를 삭제할까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("삭제", role: .destructive) {
                if let d = deleting { library.deleteNotebook(d.id) }
                deleting = nil
            }
        } message: {
            Text("'\(deleting?.title ?? "")' 노트와 필기, 녹음이 모두 삭제됩니다. 백업에서 복원할 수 있어요.")
        }
    }

    @ViewBuilder
    private func contextMenu(for meta: NotebookMeta) -> some View {
        Button { onOpen(meta.id) } label: { Label("열기", systemImage: "book") }
        if supportsMultipleWindows {
            Button { openWindow(id: "notebook", value: meta.id) } label: {
                Label("새 창에서 열기", systemImage: "macwindow.badge.plus")
            }
        }
        Button {
            renameText = meta.title
            renaming = meta
        } label: { Label("이름 변경", systemImage: "pencil") }
        Button { library.toggleFavorite(meta.id) } label: {
            Label(meta.isFavorite ? "즐겨찾기 해제" : "즐겨찾기", systemImage: meta.isFavorite ? "star.slash" : "star")
        }
        Menu {
            Button("미분류") { library.move(meta.id, to: nil) }
            ForEach(library.folders) { f in
                Button(f.name) { library.move(meta.id, to: f.id) }
            }
        } label: { Label("폴더로 이동", systemImage: "folder") }
        Button { library.duplicateNotebook(meta.id) } label: { Label("복제", systemImage: "plus.square.on.square") }
        Divider()
        Button(role: .destructive) { deleting = meta } label: { Label("삭제", systemImage: "trash") }
    }
}

struct NotebookCard: View {
    let meta: NotebookMeta
    let folder: Folder?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                if let pageId = meta.firstPageId {
                    PageThumbnail(notebookId: meta.id, pageId: pageId, size: meta.firstPageSize ?? PaperSize.a4Portrait.size)
                        .overlay(alignment: .leading) {
                            Rectangle().fill(Color(hex: meta.coverHex)).frame(width: 6)
                        }
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Color(hex: meta.coverHex)).aspectRatio(0.72, contentMode: .fit)
                }
                if meta.isFavorite {
                    Image(systemName: "star.fill").foregroundStyle(.yellow).padding(6)
                        .shadow(color: .black.opacity(0.3), radius: 2)
                }
            }
            .frame(height: 210, alignment: .bottom)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                HStack(spacing: 4) {
                    Text(Format.shortDate.string(from: meta.modifiedAt))
                    Text("· \(meta.pageCount)쪽")
                    if let folder {
                        Text("· \(folder.name)").foregroundStyle(Color(hex: folder.colorHex))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }
}

/// 과목 폴더 상단: 시험 D-day, 오늘/누적 공부 시간, 최근 7일 그래프
struct FolderHeaderCard: View {
    let folder: Folder
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if let d = folder.dDayText {
                        Text(d).font(.system(size: 34, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color(hex: folder.colorHex))
                    }
                    VStack(alignment: .leading) {
                        Text(folder.examTitle.isEmpty ? (folder.examDate == nil ? "시험 일정 없음" : "시험") : folder.examTitle)
                            .font(.headline)
                        if let date = folder.examDate {
                            Text(Format.shortDate.string(from: date)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 16) {
                    Label("오늘 \(Format.studyTime(folder.todaySeconds))", systemImage: "timer")
                    Label("누적 \(Format.studyTime(folder.totalSeconds))", systemImage: "chart.bar")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            StudyBars(days: folder.lastSevenDays, color: Color(hex: folder.colorHex))
                .frame(width: 220, height: 72)
            Button("편집", action: onEdit).buttonStyle(.bordered)
        }
        .padding(18)
        .background(Color(hex: folder.colorHex).opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct StudyBars: View {
    let days: [(label: String, seconds: Double)]
    let color: Color

    var body: some View {
        let maxValue = max(days.map { $0.seconds }.max() ?? 0, 60)
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(day.label == "오늘" ? 1 : 0.5))
                        .frame(height: max(3, 50 * day.seconds / maxValue))
                    Text(day.label).font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
