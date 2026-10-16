import SwiftUI

@main
struct NoteLabApp: App {
    @StateObject private var library = LibraryStore.shared
    @StateObject private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(library)
                .environmentObject(settings)
                .onAppear { BackupService.runAutoBackupIfNeeded() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                LibraryStore.shared.saveNow()
                NotebookDocument.flushAll()
            }
        }

        // Stage Manager / Split View에서 노트를 별도 창으로 열기
        WindowGroup("노트", id: "notebook", for: UUID.self) { $notebookId in
            if let id = notebookId {
                NotebookWindowView(notebookId: id)
                    .environmentObject(library)
                    .environmentObject(settings)
            }
        }
    }
}
