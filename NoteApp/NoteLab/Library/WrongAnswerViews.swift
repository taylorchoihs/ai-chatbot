import SwiftUI

enum WrongAnswerFilter: String, CaseIterable, Identifiable {
    case all, needsReview, unsolved, mastered
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "전체"
        case .needsReview: return "다시 볼 문제"
        case .unsolved: return "아직 안 푼 문제"
        case .mastered: return "맞힌 문제"
        }
    }
    func matches(_ item: WrongAnswerItem) -> Bool {
        switch self {
        case .all: return true
        case .needsReview: return item.lastResult == false
        case .unsolved: return item.attempts.isEmpty
        case .mastered: return item.lastResult == true
        }
    }
}

struct ReviewSession: Identifiable {
    let id = UUID()
    let itemIds: [UUID]
}

struct WrongAnswerListView: View {
    let onOpenSource: (WrongAnswerItem) -> Void
    @EnvironmentObject private var library: LibraryStore
    @State private var filter: WrongAnswerFilter = .all
    @State private var folderFilter: UUID?
    @State private var session: ReviewSession?
    @State private var shareItem: ShareItem?

    private var items: [WrongAnswerItem] {
        library.wrongAnswers.filter { filter.matches($0) && (folderFilter == nil || $0.folderId == folderFilter) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Picker("필터", selection: $filter) {
                    ForEach(WrongAnswerFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if !library.folders.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            chip("모든 과목", selected: folderFilter == nil) { folderFilter = nil }
                            ForEach(library.folders) { f in
                                chip(f.name, selected: folderFilter == f.id, color: Color(hex: f.colorHex)) { folderFilter = f.id }
                            }
                        }
                    }
                }
                if items.isEmpty {
                    ContentUnavailableView("오답이 없어요", systemImage: "checkmark.seal",
                                           description: Text("노트에서 올가미로 문제를 감싸고 메뉴의 '오답노트'를 누르면 여기에 모입니다. 정답 레이어와 가림막은 자동으로 문제/정답으로 나뉘어 저장돼요."))
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], spacing: 16) {
                        ForEach(items) { item in
                            WrongAnswerCard(item: item)
                                .onTapGesture {
                                    session = ReviewSession(itemIds: reorderedIds(startingAt: item.id))
                                }
                                .contextMenu {
                                    Button { onOpenSource(item) } label: { Label("원본 노트로 이동", systemImage: "arrow.uturn.left") }
                                    Button(role: .destructive) { library.deleteWrongAnswer(item.id) } label: {
                                        Label("삭제", systemImage: "trash")
                                    }
                                }
                        }
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle("오답노트")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if let url = PageRenderer.exportWrongAnswers(items) { shareItem = ShareItem(url: url) }
                } label: { Label("PDF로 출력", systemImage: "printer") }
                .disabled(items.isEmpty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    session = ReviewSession(itemIds: items.map(\.id).shuffled())
                } label: { Label("섞어서 복습", systemImage: "shuffle") }
                .disabled(items.isEmpty)
            }
        }
        .fullScreenCover(item: $session) { s in
            WrongAnswerReviewView(itemIds: s.itemIds) { item in
                session = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { onOpenSource(item) }
            }
            .environmentObject(library)
        }
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
    }

    private func reorderedIds(startingAt id: UUID) -> [UUID] {
        let ids = items.map(\.id)
        guard let i = ids.firstIndex(of: id) else { return ids }
        return Array(ids[i...] + ids[..<i])
    }

    private func chip(_ title: String, selected: Bool, color: Color = .accentColor, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? color.opacity(0.25) : Color.secondary.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct WrongAnswerCard: View {
    let item: WrongAnswerItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncWrongImage(name: item.questionFile)
                .frame(height: 160)
                .frame(maxWidth: .infinity)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(item.notebookTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                if item.attempts.isEmpty {
                    Text("새 문제").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("⭕ \(item.correctCount)  ❌ \(item.wrongCount)").font(.caption.monospacedDigit())
                }
            }
            Text(Format.shortDate.string(from: item.createdAt) + (item.memo.isEmpty ? "" : " · \(item.memo)"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .topLeading) {
            if item.lastResult == false {
                Text("다시 보기").font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.red, in: Capsule())
                    .padding(18)
            }
        }
    }
}

struct AsyncWrongImage: View {
    let name: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                ProgressView()
            }
        }
        .task(id: name) {
            let url = Storage.wrongImage(name)
            image = await Task.detached { ImageCache.shared.image(at: url) }.value
        }
    }
}

/// 복습 화면: 문제만 보고 → 정답 확인 → ⭕/❌ 기록
struct WrongAnswerReviewView: View {
    let itemIds: [UUID]
    let onOpenSource: (WrongAnswerItem) -> Void
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var showAnswer = false
    @State private var memo = ""
    @State private var correctThisSession = 0
    @State private var answeredThisSession = 0

    private var item: WrongAnswerItem? {
        guard let id = itemIds[safe: index] else { return nil }
        return library.wrongAnswers.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let item {
                    VStack(spacing: 16) {
                        ZStack {
                            AsyncWrongImage(name: showAnswer ? (item.answerFile ?? item.questionFile) : item.questionFile)
                                .id(showAnswer ? "a-\(item.id)" : "q-\(item.id)")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                        .onTapGesture { withAnimation { showAnswer.toggle() } }

                        TextField("메모 (틀린 이유, 개념 등)", text: $memo, onCommit: saveMemo)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 16) {
                            Button {
                                withAnimation { showAnswer.toggle() }
                            } label: {
                                Label(showAnswer ? "문제 보기" : "정답 보기", systemImage: showAnswer ? "eye.slash" : "eye")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            Button { record(false) } label: {
                                Label("틀림", systemImage: "xmark").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).tint(.red)
                            Button { record(true) } label: {
                                Label("맞음", systemImage: "circle").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).tint(.green)
                        }
                        .controlSize(.large)
                    }
                    .padding(24)
                    .onAppear { memo = item.memo }
                    .onChange(of: index) { _, _ in memo = self.item?.memo ?? "" }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 60)).foregroundStyle(.green)
                        Text("복습 완료!").font(.title.bold())
                        Text("\(answeredThisSession)문제 중 \(correctThisSession)문제 맞힘").foregroundStyle(.secondary)
                        Button("닫기") { dismiss() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .navigationTitle(item.map { "\(index + 1) / \(itemIds.count) · \($0.notebookTitle)" } ?? "오답 복습")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { saveMemo(); dismiss() } }
                if let item {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button { go(-1) } label: { Image(systemName: "chevron.left") }.disabled(index == 0)
                        Button { go(1) } label: { Image(systemName: "chevron.right") }
                        Button {
                            saveMemo()
                            onOpenSource(item)
                        } label: { Label("원본", systemImage: "arrow.uturn.left") }
                    }
                }
            }
        }
    }

    private func saveMemo() {
        guard var it = item, it.memo != memo else { return }
        it.memo = memo
        library.updateWrongAnswer(it)
    }

    private func record(_ correct: Bool) {
        guard let it = item else { return }
        saveMemo()
        library.recordAttempt(it.id, correct: correct)
        answeredThisSession += 1
        if correct { correctThisSession += 1 }
        go(1)
    }

    private func go(_ delta: Int) {
        saveMemo()
        showAnswer = false
        index = max(0, min(index + delta, itemIds.count))
    }
}
