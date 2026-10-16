import SwiftUI
import UniformTypeIdentifiers

enum LibrarySection: Hashable {
    case all, favorites, recent, unfiled, folder(UUID), wrongAnswers
}

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var settings: AppSettings
    @State private var section: LibrarySection? = .all
    @State private var openRequest: OpenRequest?
    @State private var showSearch = false
    @State private var showSettings = false
    @State private var editingFolder: Folder?
    @State private var creatingFolder = false
    @State private var folderToDelete: Folder?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                detail
            }
        }
        .fullScreenCover(item: $openRequest) { req in
            NotebookEditorLoader(notebookId: req.notebookId, pageIndex: req.pageIndex) { openRequest = nil }
                .environmentObject(library)
                .environmentObject(settings)
        }
        .sheet(isPresented: $showSearch) {
            SearchView { result in
                showSearch = false
                openRequest = OpenRequest(notebookId: result.notebookId, pageIndex: result.pageIndex)
            }
            .environmentObject(library)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(library).environmentObject(settings)
        }
        .sheet(item: $editingFolder) { folder in
            FolderEditSheet(folder: folder) { library.updateFolder($0) }
        }
        .sheet(isPresented: $creatingFolder) {
            FolderEditSheet(folder: nil) { f in
                var created = library.addFolder(name: f.name, colorHex: f.colorHex)
                created.examTitle = f.examTitle
                created.examDate = f.examDate
                library.updateFolder(created)
                section = .folder(created.id)
            }
        }
        .confirmationDialog("과목 폴더를 삭제할까요?", isPresented: Binding(get: { folderToDelete != nil },
                                                                   set: { if !$0 { folderToDelete = nil } }),
                            titleVisibility: .visible) {
            Button("폴더만 삭제 (노트는 미분류로 이동)", role: .destructive) {
                if let f = folderToDelete {
                    library.deleteFolder(f.id)
                    if section == .folder(f.id) { section = .all }
                }
            }
        }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "pdf" else { return }
            if let id = library.importPDF(from: url, folderId: currentFolderId) {
                openRequest = OpenRequest(notebookId: id, pageIndex: 0)
            }
        }
    }

    private var currentFolderId: UUID? {
        if case let .folder(id) = section { return id }
        return nil
    }

    // MARK: 사이드바

    private var sidebar: some View {
        List(selection: $section) {
            Section("라이브러리") {
                Label("모든 노트", systemImage: "books.vertical").tag(LibrarySection.all)
                Label("즐겨찾기", systemImage: "star").tag(LibrarySection.favorites)
                Label("최근 연 노트", systemImage: "clock").tag(LibrarySection.recent)
                Label("미분류", systemImage: "tray").tag(LibrarySection.unfiled)
            }
            Section("학습") {
                Label {
                    HStack {
                        Text("오답노트")
                        Spacer()
                        Text("\(library.wrongAnswers.count)").foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "checkmark.circle.badge.xmark")
                }
                .tag(LibrarySection.wrongAnswers)
            }
            Section {
                ForEach(library.folders) { folder in
                    FolderRow(folder: folder)
                        .tag(LibrarySection.folder(folder.id))
                        .contextMenu {
                            Button { editingFolder = folder } label: { Label("편집", systemImage: "pencil") }
                            Button(role: .destructive) { folderToDelete = folder } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
                }
                .onMove { library.moveFolders(from: $0, to: $1) }
            } header: {
                HStack {
                    Text("과목 폴더")
                    Spacer()
                    Button { creatingFolder = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .navigationTitle("NoteLab")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel("전체 검색")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    .accessibilityLabel("설정")
            }
        }
    }

    // MARK: 본문

    @ViewBuilder private var detail: some View {
        switch section ?? .all {
        case .wrongAnswers:
            WrongAnswerListView { item in
                let index = NotebookDocument.open(item.notebookId)?.index(of: item.pageId)
                openRequest = OpenRequest(notebookId: item.notebookId, pageIndex: index)
            }
        default:
            NotebookGridView(section: section ?? .all,
                             onOpen: { openRequest = OpenRequest(notebookId: $0, pageIndex: nil) },
                             onEditFolder: { editingFolder = $0 })
        }
    }
}

struct FolderRow: View {
    let folder: Folder

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(Color(hex: folder.colorHex))
            VStack(alignment: .leading, spacing: 1) {
                Text(folder.name).lineLimit(1)
                if folder.todaySeconds >= 60 {
                    Text("오늘 \(Format.studyTime(folder.todaySeconds))").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let d = folder.dDayText {
                Text(d)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(hex: folder.colorHex).opacity(0.2), in: Capsule())
            }
        }
    }
}
