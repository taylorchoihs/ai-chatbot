import SwiftUI
import UIKit

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension EditorModel {
    /// 현재 보고 있는 페이지를 유지한 채 순서 변경
    func movePages(from: IndexSet, to: Int) {
        let currentId = currentPage.id
        doc.movePages(from: from, to: to)
        if let i = doc.index(of: currentId) { pageIndex = i }
        objectWillChange.send()
    }

    func deletePages(at offsets: IndexSet) {
        pageView?.commitSelection()
        let currentId = currentPage.id
        doc.deletePages(at: offsets)
        pageIndex = doc.index(of: currentId) ?? max(0, min(pageIndex, pageCount - 1))
        objectWillChange.send()
    }
}

// MARK: - 페이지 사이드바

struct PageSidebar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var doc: NotebookDocument
    @State private var bookmarksOnly = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $bookmarksOnly) {
                Text("전체").tag(false)
                Image(systemName: "bookmark.fill").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(Array(doc.notebook.pages.enumerated()), id: \.element.id) { index, page in
                            if !bookmarksOnly || page.isBookmarked {
                                thumbnail(index: index, page: page).id(page.id)
                            }
                        }
                        Button { model.addPage(after: model.pageCount - 1) } label: {
                            Image(systemName: "plus")
                                .frame(width: 100, height: 60)
                                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 8)
                }
                .onAppear { proxy.scrollTo(model.currentPage.id, anchor: .center) }
                .onChange(of: model.pageIndex) { _, _ in
                    withAnimation { proxy.scrollTo(model.currentPage.id, anchor: .center) }
                }
            }
        }
        .background(Color(.secondarySystemBackground))
    }

    private func thumbnail(index: Int, page: Page) -> some View {
        let isCurrent = index == model.pageIndex
        return Button { model.goToPage(index) } label: {
            VStack(spacing: 4) {
                PageThumbnail(notebookId: doc.id, pageId: page.id, size: page.size)
                    .frame(width: 104)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: isCurrent ? 3 : 0))
                    .overlay(alignment: .topTrailing) {
                        if page.isBookmarked {
                            Image(systemName: "bookmark.fill").foregroundStyle(.orange).padding(4)
                        }
                    }
                Text("\(index + 1)")
                    .font(.caption2.weight(isCurrent ? .bold : .regular))
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { model.addPage(after: index) } label: { Label("뒤에 새 페이지", systemImage: "plus") }
            Button { model.duplicatePage(at: index) } label: { Label("복제", systemImage: "plus.square.on.square") }
            Button { doc.toggleBookmark(page.id) } label: {
                Label(page.isBookmarked ? "책갈피 해제" : "책갈피", systemImage: "bookmark")
            }
            Divider()
            Button(role: .destructive) { model.deletePages(at: IndexSet(integer: index)) } label: {
                Label("페이지 삭제", systemImage: "trash")
            }
        }
    }
}

// MARK: - 용지 선택 (새 노트·페이지 추가 공용)

enum PaperPreviewCache {
    private static var cache: [String: UIImage] = [:]
    static func image(style: PaperStyle, color: PaperColor, size: CGSize) -> UIImage {
        let key = "\(style.rawValue)-\(color.rawValue)-\(Int(size.width))x\(Int(size.height))"
        if let img = cache[key] { return img }
        let img = PageRenderer.paperPreview(style: style, color: color, size: size, width: 84)
        cache[key] = img
        return img
    }
}

struct PaperStylePicker: View {
    @Binding var style: PaperStyle
    let color: PaperColor
    let size: CGSize

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 12)], spacing: 12) {
            ForEach(PaperStyle.allCases) { s in
                Button { style = s } label: {
                    VStack(spacing: 4) {
                        Image(uiImage: PaperPreviewCache.image(style: s, color: color, size: size))
                            .resizable()
                            .scaledToFit()
                            .frame(height: 96)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(style == s ? Color.accentColor : Color.primary.opacity(0.15),
                                        lineWidth: style == s ? 3 : 1))
                        Text(s.title).font(.caption)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }
}

struct PaperColorPicker: View {
    @Binding var color: PaperColor

    var body: some View {
        HStack(spacing: 14) {
            ForEach(PaperColor.allCases) { c in
                Button { color = c } label: {
                    VStack(spacing: 4) {
                        Circle()
                            .fill(Color(uiColor: c.fill))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().stroke(color == c ? Color.accentColor : Color.primary.opacity(0.2),
                                                     lineWidth: color == c ? 3 : 1))
                        Text(c.title).font(.caption2)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 페이지 추가

struct AddPageSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var style: PaperStyle = .lined
    @State private var color: PaperColor = .white
    @State private var size: PaperSize?
    @State private var count = 1
    @State private var atEnd = false

    private var pageSize: CGSize { size?.size ?? model.currentPage.size }

    var body: some View {
        NavigationStack {
            Form {
                Section("용지") { PaperStylePicker(style: $style, color: color, size: pageSize) }
                Section("색상") { PaperColorPicker(color: $color) }
                Section("크기") {
                    Picker("크기", selection: $size) {
                        Text("현재 페이지와 같게").tag(PaperSize?.none)
                        ForEach(PaperSize.allCases) { Text($0.title).tag(PaperSize?.some($0)) }
                    }
                }
                Section {
                    Stepper("페이지 수: \(count)", value: $count, in: 1...50)
                    Toggle("노트 맨 끝에 추가", isOn: $atEnd)
                }
            }
            .navigationTitle("페이지 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("추가", action: add) }
            }
            .onAppear {
                if case let .paper(s, c) = model.currentPage.background {
                    style = s
                    color = c
                }
            }
        }
    }

    private func add() {
        let bg = PageBackground.paper(style: style, color: color)
        var index = atEnd ? model.pageCount - 1 : model.pageIndex
        var first: Int?
        for _ in 0..<count {
            index = model.doc.insertPage(Page(size: pageSize, background: bg), at: index + 1)
            if first == nil { first = index }
        }
        if let first { model.goToPage(first) }
        dismiss()
    }
}

// MARK: - 페이지 관리

struct PageManagerSheet: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var doc: NotebookDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(doc.notebook.pages.enumerated()), id: \.element.id) { index, page in
                    HStack(spacing: 14) {
                        PageThumbnail(notebookId: doc.id, pageId: page.id, size: page.size)
                            .frame(width: 56)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(index + 1)쪽").font(.body.weight(index == model.pageIndex ? .bold : .regular))
                            Text(describe(page)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if page.isBookmarked { Image(systemName: "bookmark.fill").foregroundStyle(.orange) }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.goToPage(index)
                        dismiss()
                    }
                    .swipeActions(edge: .leading) {
                        Button { model.duplicatePage(at: index) } label: {
                            Label("복제", systemImage: "plus.square.on.square")
                        }
                        .tint(.blue)
                        Button { doc.toggleBookmark(page.id) } label: { Label("책갈피", systemImage: "bookmark") }
                            .tint(.orange)
                    }
                }
                .onMove { model.movePages(from: $0, to: $1) }
                .onDelete { model.deletePages(at: $0) }
            }
            .navigationTitle("페이지 관리 (\(doc.notebook.pages.count)쪽)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } }
            }
        }
    }

    private func describe(_ page: Page) -> String {
        switch page.background {
        case let .paper(style, color): return "\(style.title) · \(color.title)"
        case let .pdf(_, index): return "PDF \(index + 1)쪽"
        }
    }
}

// MARK: - 내보내기

struct ExportSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var currentOnly = false
    @State private var includeAnswers = true
    @State private var includeMasks = false
    @State private var url: URL?
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section("범위") {
                    Picker("범위", selection: $currentOnly) {
                        Text("전체 \(model.pageCount)쪽").tag(false)
                        Text("현재 페이지").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Toggle("정답 레이어 포함", isOn: $includeAnswers)
                    Toggle("가림막 포함 (시험지처럼)", isOn: $includeMasks)
                } footer: {
                    Text("정답 레이어를 빼고 가림막을 넣으면 복습용 문제지를 만들 수 있어요.")
                }
                Section {
                    if let url {
                        ShareLink(item: url) { Label("공유 / 파일에 저장", systemImage: "square.and.arrow.up") }
                    } else {
                        Button {
                            working = true
                            DispatchQueue.main.async {
                                url = model.exportPDF(currentOnly: currentOnly, includeAnswers: includeAnswers,
                                                      includeMasks: includeMasks)
                                working = false
                            }
                        } label: {
                            HStack {
                                Text("PDF 만들기")
                                if working { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(working)
                    }
                }
            }
            .onChange(of: currentOnly) { _, _ in url = nil }
            .onChange(of: includeAnswers) { _, _ in url = nil }
            .onChange(of: includeMasks) { _, _ in url = nil }
            .navigationTitle("PDF로 내보내기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
        }
    }
}

// MARK: - 텍스트 입력

struct TextEditSheet: View {
    let request: TextRequest
    let onSave: (String, CGFloat, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var size: CGFloat
    @State private var color: Color

    init(request: TextRequest, onSave: @escaping (String, CGFloat, String) -> Void) {
        self.request = request
        self.onSave = onSave
        _text = State(initialValue: request.existing?.text ?? "")
        _size = State(initialValue: request.existing?.fontSize ?? 18)
        _color = State(initialValue: Color(hex: request.existing?.colorHex ?? "#1C1C1EFF"))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 160)
                        .font(.system(size: min(size, 28)))
                }
                Section {
                    Stepper("글자 크기 \(Int(size))", value: $size, in: 8...72, step: 2)
                    ColorPicker("글자 색", selection: $color, supportsOpacity: false)
                }
                if request.existing != nil {
                    Section {
                        Button("텍스트 상자 삭제", role: .destructive) {
                            onSave("", size, color.hexString)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(request.existing == nil ? "텍스트 추가" : "텍스트 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") {
                        onSave(text, size, color.hexString)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - 도형 팔레트

struct ShapePalette: View {
    let onPick: (ShapeKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("도형 \(ShapeKind.allCases.count)종").font(.headline)
            Text("넣은 도형은 필기처럼 올가미로 이동·크기·색을 바꿀 수 있어요. 손으로 그린 도형을 바로 보정하려면 ⋯ 메뉴에서 '도형 자동 보정'을 켜세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                    ForEach(ShapeKind.allCases) { kind in
                        Button { onPick(kind) } label: {
                            VStack(spacing: 4) {
                                Image(systemName: kind.symbol).font(.title2).frame(height: 30)
                                Text(kind.title).font(.caption2).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding()
        .frame(width: 400, height: 460)
    }
}

// MARK: - 노트 안 검색

struct NotebookSearchSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SearchResult] = []

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty {
                    let marks = model.doc.notebook.pages.enumerated().filter { $0.element.isBookmarked }
                    Section("책갈피") {
                        if marks.isEmpty { Text("책갈피한 페이지가 없어요").foregroundStyle(.secondary) }
                        ForEach(marks, id: \.element.id) { index, _ in
                            Button("\(index + 1)쪽") {
                                model.goToPage(index)
                                dismiss()
                            }
                        }
                    }
                } else {
                    if results.isEmpty { Text("결과가 없어요").foregroundStyle(.secondary) }
                    ForEach(results) { r in
                        Button {
                            if let p = r.pageIndex { model.goToPage(p) }
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(r.pageIndex.map { "\($0 + 1)쪽" } ?? "제목").font(.headline)
                                Text(r.snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                Text(r.kind == .ink ? "손글씨" : r.kind == .pdf ? "PDF 텍스트" : "제목")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "손글씨·PDF 텍스트 검색")
            .task(id: query) {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let meta = LibraryStore.shared.meta(model.doc.id) else { return }
                let q = query
                results = await Task.detached { SearchIndexer.search(q, in: [meta]) }.value
                    .filter { $0.pageIndex != nil }
            }
            .navigationTitle("노트 안에서 검색")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } } }
            .onAppear {
                model.doc.saveNow()
                SearchIndexer.shared.indexInk(doc: model.doc, pageId: model.currentPage.id)
            }
        }
    }
}
