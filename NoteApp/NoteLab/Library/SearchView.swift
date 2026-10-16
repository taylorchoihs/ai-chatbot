import SwiftUI

/// 모든 노트에서 제목·PDF 텍스트·손글씨 검색
struct SearchView: View {
    let onOpen: (SearchResult) -> Void
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var indexer = SearchIndexer.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var searching = false

    private var grouped: [(id: UUID, title: String, results: [SearchResult])] {
        var order: [UUID] = []
        var map: [UUID: [SearchResult]] = [:]
        for r in results {
            if map[r.notebookId] == nil { order.append(r.notebookId) }
            map[r.notebookId, default: []].append(r)
        }
        return order.map { id in
            (id: id, title: map[id]?.first?.notebookTitle ?? "", results: map[id] ?? [])
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    Section {
                        Label("필기는 기기 안에서 인식돼요 (한국어·영어). 인터넷이나 AI 서버로 보내지 않습니다.", systemImage: "lock.shield")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if indexer.isIndexing {
                            ProgressView(value: indexer.progress) { Text("손글씨 색인 중…") }
                        } else {
                            Button { Task { await indexer.reindexAll() } } label: {
                                Label("모든 노트 손글씨 다시 색인", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                } else if results.isEmpty && !searching {
                    Text("'\(query)' 결과가 없어요").foregroundStyle(.secondary)
                }
                ForEach(grouped, id: \.id) { group in
                    Section(group.title) {
                        ForEach(group.results) { r in
                            Button {
                                onOpen(r)
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: icon(r.kind)).foregroundStyle(Color.accentColor).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(r.pageIndex.map { "\($0 + 1)쪽" } ?? "노트 제목").font(.subheadline.weight(.semibold))
                                        Text(r.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "제목, PDF 내용, 손글씨")
            .task(id: query) {
                searching = true
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let q = query
                let metas = library.notebooks
                let found = await Task.detached { SearchIndexer.search(q, in: metas) }.value
                guard !Task.isCancelled else { return }
                results = found
                searching = false
            }
            .navigationTitle("검색")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
            .onAppear { NotebookDocument.flushAll() }
        }
    }

    private func icon(_ kind: SearchResult.Kind) -> String {
        switch kind {
        case .title: return "textformat"
        case .pdf: return "doc.text"
        case .ink: return "pencil.and.scribble"
        }
    }
}
