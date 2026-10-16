import SwiftUI

private let coverColors = ["#3F6BE6FF", "#E5484DFF", "#30A46CFF", "#F76B15FF", "#8E4EC6FF",
                           "#0091FFFF", "#D6409FFF", "#5F6368FF", "#1C1C1EFF", "#C9A227FF"]

struct NewNotebookSheet: View {
    let defaultFolderId: UUID?
    let onCreated: (UUID) -> Void
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var folderId: UUID?
    @State private var style: PaperStyle = .lined
    @State private var color: PaperColor = .white
    @State private var size: PaperSize = .a4Portrait
    @State private var pageCount = 1
    @State private var coverHex = coverColors[0]

    init(defaultFolderId: UUID?, onCreated: @escaping (UUID) -> Void) {
        self.defaultFolderId = defaultFolderId
        self.onCreated = onCreated
        _folderId = State(initialValue: defaultFolderId)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("노트 제목", text: $title)
                    Picker("과목 폴더", selection: $folderId) {
                        Text("미분류").tag(UUID?.none)
                        ForEach(library.folders) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                }
                Section("표지 색") {
                    HStack(spacing: 10) {
                        ForEach(coverColors, id: \.self) { hex in
                            Circle().fill(Color(hex: hex)).frame(width: 28, height: 28)
                                .overlay(Circle().stroke(Color.primary, lineWidth: coverHex == hex ? 2.5 : 0).padding(-3))
                                .onTapGesture { coverHex = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section("용지") { PaperStylePicker(style: $style, color: color, size: size.size) }
                Section("용지 색") { PaperColorPicker(color: $color) }
                Section {
                    Picker("크기", selection: $size) {
                        ForEach(PaperSize.allCases) { Text($0.title).tag($0) }
                    }
                    Stepper("처음 페이지 수: \(pageCount)", value: $pageCount, in: 1...200)
                }
            }
            .navigationTitle("새 노트")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("만들기") {
                        let id = library.createNotebook(title: title, folderId: folderId, style: style, color: color,
                                                        size: size, pageCount: pageCount, coverHex: coverHex)
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { onCreated(id) }
                    }
                }
            }
        }
    }
}

struct FolderEditSheet: View {
    let original: Folder?
    let onSave: (Folder) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var colorHex: String
    @State private var examTitle: String
    @State private var hasExam: Bool
    @State private var examDate: Date

    init(folder: Folder?, onSave: @escaping (Folder) -> Void) {
        original = folder
        self.onSave = onSave
        _name = State(initialValue: folder?.name ?? "")
        _colorHex = State(initialValue: folder?.colorHex ?? coverColors[0])
        _examTitle = State(initialValue: folder?.examTitle ?? "")
        _hasExam = State(initialValue: folder?.examDate != nil)
        _examDate = State(initialValue: folder?.examDate ?? Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("과목") {
                    TextField("이름 (예: 미적분, 일반화학)", text: $name)
                    HStack(spacing: 10) {
                        ForEach(coverColors, id: \.self) { hex in
                            Circle().fill(Color(hex: hex)).frame(width: 26, height: 26)
                                .overlay(Circle().stroke(Color.primary, lineWidth: colorHex == hex ? 2.5 : 0).padding(-3))
                                .onTapGesture { colorHex = hex }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Toggle("시험 D-day 표시", isOn: $hasExam)
                    if hasExam {
                        TextField("시험 이름 (예: 중간고사)", text: $examTitle)
                        DatePicker("시험 날짜", selection: $examDate, displayedComponents: .date)
                    }
                } header: {
                    Text("시험")
                } footer: {
                    Text("이 폴더의 노트를 열어 둔 시간이 과목별 공부 시간으로 자동 기록됩니다.")
                }
            }
            .navigationTitle(original == nil ? "새 과목 폴더" : "폴더 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        var f = original ?? Folder(name: name, colorHex: colorHex)
                        f.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? "새 과목" : name
                        f.colorHex = colorHex
                        f.examTitle = hasExam ? examTitle : ""
                        f.examDate = hasExam ? examDate : nil
                        onSave(f)
                        dismiss()
                    }
                }
            }
        }
    }
}
