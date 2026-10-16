import SwiftUI
import PhotosUI

// MARK: - 상단 막대

struct EditorTopBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var doc: NotebookDocument
    @ObservedObject var audio: AudioService
    @ObservedObject private var settings = AppSettings.shared
    let onClose: () -> Void

    @State private var showLayers = false
    @State private var showRecordings = false
    @State private var showPageManager = false
    @State private var showAddPage = false
    @State private var showExport = false
    @State private var showPDFImporter = false
    @State private var showSearch = false
    @State private var shareItem: ShareItem?

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onClose) {
                Label("라이브러리", systemImage: "chevron.left")
            }
            Text(doc.notebook.title)
                .font(.headline)
                .lineLimit(1)
                .frame(maxWidth: 260, alignment: .leading)
                .padding(.leading, 8)
            Spacer(minLength: 8)

            BarButton(symbol: "arrow.uturn.backward", label: "실행 취소", disabled: !model.canUndo) { model.undo() }
            BarButton(symbol: "arrow.uturn.forward", label: "다시 실행", disabled: !model.canRedo) { model.redo() }
            Divider().frame(height: 22).padding(.horizontal, 4)
            BarButton(symbol: "sidebar.left", label: "페이지 목록", active: model.showSidebar) { model.showSidebar.toggle() }
            BarButton(symbol: "square.3.layers.3d", label: "레이어") { showLayers = true }
                .popover(isPresented: $showLayers) {
                    LayerPanel(model: model, doc: doc).frame(width: 360, height: 440)
                }
            BarButton(symbol: doc.answersHidden ? "eye.slash" : "eye", label: "정답 레이어 숨기기",
                      active: doc.answersHidden) { model.toggleAnswers() }
            BarButton(symbol: model.revealAllMasks ? "rectangle.dashed" : "rectangle.inset.filled",
                      label: "가림막 모두 보기", active: model.revealAllMasks) { model.revealAllMasks.toggle() }
            Button {
                if audio.isRecording { audio.stopRecording() } else { showRecordings = true }
            } label: {
                Image(systemName: audio.isRecording ? "stop.circle.fill" : "mic")
                    .font(.system(size: 19))
                    .foregroundStyle(audio.isRecording ? Color.red : Color.primary)
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("강의 녹음")
            .popover(isPresented: $showRecordings) {
                RecordingsPanel(doc: doc, audio: audio).frame(width: 360, height: 440)
            }
            moreMenu
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(.bar)
        .sheet(isPresented: $showAddPage) { AddPageSheet(model: model) }
        .sheet(isPresented: $showPageManager) { PageManagerSheet(model: model, doc: doc) }
        .sheet(isPresented: $showExport) { ExportSheet(model: model) }
        .sheet(isPresented: $showSearch) { NotebookSearchSheet(model: model) }
        .sheet(item: $shareItem) { ShareSheet(items: [$0.url]) }
        .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf]) { result in
            if case let .success(url) = result { model.insertPDF(url) }
        }
        .alert("오류", isPresented: Binding(get: { audio.errorMessage != nil },
                                           set: { if !$0 { audio.errorMessage = nil } })) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(audio.errorMessage ?? "")
        }
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button { showAddPage = true } label: { Label("페이지 추가…", systemImage: "doc.badge.plus") }
                Button { model.addPage(after: model.pageIndex) } label: { Label("같은 용지 바로 추가", systemImage: "plus") }
                Button { showPDFImporter = true } label: { Label("PDF 삽입…", systemImage: "doc.richtext") }
                Button { showPageManager = true } label: { Label("페이지 관리…", systemImage: "square.grid.2x2") }
                Button { doc.toggleBookmark(model.currentPage.id) } label: {
                    Label(model.currentPage.isBookmarked ? "책갈피 해제" : "책갈피", systemImage: "bookmark")
                }
            }
            Section {
                Button { showSearch = true } label: { Label("노트 안에서 검색", systemImage: "magnifyingglass") }
                Button { model.isReadingMode = true } label: { Label("읽기 모드", systemImage: "book") }
            }
            Section {
                Button { showExport = true } label: { Label("PDF로 내보내기…", systemImage: "square.and.arrow.up") }
                Button {
                    if let url = model.exportCurrentPageImage() { shareItem = ShareItem(url: url) }
                } label: { Label("현재 페이지 이미지 공유", systemImage: "photo") }
            }
            Section("필기 설정") {
                Toggle(isOn: $settings.fingerDrawing) { Label("손가락으로 필기", systemImage: "hand.draw") }
                Toggle(isOn: $settings.shapeSnap) { Label("도형 자동 보정", systemImage: "wand.and.stars") }
                Toggle(isOn: $settings.swipeToTurnPage) { Label("스와이프로 페이지 넘기기", systemImage: "hand.point.left") }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 19))
                .frame(width: 40, height: 40)
        }
    }
}

struct BarButton: View {
    let symbol: String
    let label: String
    var active = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .frame(width: 40, height: 40)
                .background(active ? Color.accentColor.opacity(0.18) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .disabled(disabled)
        .accessibilityLabel(label)
        .help(label)
    }
}

// MARK: - 도구 막대

struct ToolOptionsBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var clipboard = EditorClipboard.shared
    @State private var showShapes = false
    @State private var photoItem: PhotosPickerItem?

    private let maskColors = ["#F28B82FF", "#FBBC04FF", "#81C995FF", "#8AB4F8FF", "#5F6368FF"]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(EditorTool.allCases) { tool in
                    BarButton(symbol: tool.symbol, label: tool.title, active: model.tool == tool) {
                        model.tool = tool
                    }
                }
                BarButton(symbol: "square.on.circle", label: "도형") { showShapes = true }
                    .popover(isPresented: $showShapes) {
                        ShapePalette { kind in
                            showShapes = false
                            model.pageView?.insertShape(kind)
                        }
                    }
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .frame(width: 40, height: 40)
                }
                .accessibilityLabel("사진 넣기")
                if !clipboard.isEmpty {
                    BarButton(symbol: "doc.on.clipboard", label: "붙여넣기") { model.pageView?.paste() }
                }
                Divider().frame(height: 24).padding(.horizontal, 8)
                options
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 48)
        .background(.bar)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let saved = model.doc.saveImage(data) {
                    model.pageView?.insertImage(name: saved.name, size: saved.size)
                }
                photoItem = nil
            }
        }
    }

    @ViewBuilder private var options: some View {
        switch model.tool {
        case .pen:
            Menu {
                Picker("펜 종류", selection: $model.penKind) {
                    ForEach(PenKind.allCases) { Text($0.title).tag($0) }
                }
            } label: {
                Label(model.penKind.title, systemImage: "chevron.down")
                    .labelStyle(.titleAndIcon)
                    .font(.subheadline)
                    .padding(.horizontal, 8)
            }
            ColorSwatches(colors: $settings.penColors, selected: $model.penColorHex)
            WidthPicker(widths: [1.2, 2.5, 4, 7], selected: $model.penWidth, colorHex: model.penColorHex)
        case .highlighter:
            ColorSwatches(colors: $settings.highlighterColors, selected: $model.highlighterColorHex)
            WidthPicker(widths: [8, 14, 22, 32], selected: $model.highlighterWidth, colorHex: model.highlighterColorHex)
        case .eraser:
            Picker("지우개", selection: $model.eraserKind) {
                ForEach(EraserKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            if model.eraserKind == .pixel {
                WidthPicker(widths: [8, 20, 40], selected: $model.eraserWidth, colorHex: "#8E8E93FF")
            }
        case .lasso:
            hint("감싸서 선택 → 끌어서 이동, 오른쪽 아래 손잡이로 크기, 메뉴에서 색상·레이어·오답노트")
        case .text:
            hint("텍스트를 넣을 곳을 탭하세요. 기존 텍스트를 탭하면 편집합니다.")
        case .mask:
            ColorSwatches(colors: .constant(maskColors), selected: $model.maskColorHex, editable: false)
            hint("드래그해서 답을 가리고, 손가락으로 탭해 확인 · 펜슬로 탭하면 삭제")
        case .laser:
            hint("발표·화면 녹화용 레이저 포인터. 자국은 곧 사라집니다.")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
    }
}

struct ColorSwatches: View {
    @Binding var colors: [String]
    @Binding var selected: String
    var editable = true

    var body: some View {
        HStack(spacing: 6) {
            ForEach(colors, id: \.self) { hex in
                Button { selected = hex } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.primary.opacity(0.15)))
                        .padding(3)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: selected == hex ? 2.5 : 0))
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if editable && colors.count > 1 {
                        Button(role: .destructive) { colors.removeAll { $0 == hex } } label: {
                            Label("즐겨찾기에서 삭제", systemImage: "trash")
                        }
                    }
                }
            }
            ColorPicker("색상 선택", selection: Binding(get: { Color(hex: selected) },
                                                      set: { selected = $0.hexString }),
                        supportsOpacity: false)
                .labelsHidden()
            if editable && !colors.contains(selected) && colors.count < 12 {
                Button { colors.append(selected) } label: { Image(systemName: "plus.circle") }
                    .accessibilityLabel("현재 색을 즐겨찾기에 추가")
            }
        }
    }
}

struct WidthPicker: View {
    let widths: [CGFloat]
    @Binding var selected: CGFloat
    let colorHex: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(widths, id: \.self) { w in
                Button { selected = w } label: {
                    Circle()
                        .fill(Color(hex: colorHex))
                        .frame(width: min(4 + w * 1.2, 24), height: min(4 + w * 1.2, 24))
                        .frame(width: 32, height: 32)
                        .background(abs(selected - w) < 0.01 ? Color.accentColor.opacity(0.18) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(Circle().stroke(Color.primary.opacity(0.1)).frame(width: min(4 + w * 1.2, 24)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 6)
    }
}

// MARK: - 녹음 막대

struct RecordingBar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var audio: AudioService

    var body: some View {
        if audio.isRecording {
            HStack(spacing: 12) {
                Circle().fill(Color.red).frame(width: 10, height: 10)
                Text("녹음 중 \(Format.duration(audio.currentTime))").monospacedDigit()
                Text("이때 쓴 필기가 녹음과 연결됩니다").font(.caption).foregroundStyle(.secondary)
                Button("중지") { audio.stopRecording() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
        } else if audio.activeRecording != nil {
            HStack(spacing: 12) {
                Button { audio.skip(-10) } label: { Image(systemName: "gobackward.10") }
                Button { audio.togglePlay() } label: {
                    Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill").font(.title3)
                }
                Button { audio.skip(10) } label: { Image(systemName: "goforward.10") }
                Text(Format.duration(audio.currentTime)).font(.caption.monospacedDigit())
                Slider(value: Binding(get: { audio.currentTime }, set: { audio.seek(to: $0) }),
                       in: 0...max(audio.duration, 0.1))
                    .frame(width: 220)
                Text(Format.duration(audio.duration)).font(.caption.monospacedDigit())
                Menu {
                    ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                        Button(String(format: "%gx", r)) { audio.rate = Float(r) }
                    }
                } label: {
                    Text(String(format: "%gx", audio.rate)).font(.caption.monospacedDigit())
                }
                Toggle(isOn: $model.syncPlayback) { Image(systemName: "hand.tap") }
                    .toggleStyle(.button)
                    .help("켜면 필기를 손가락으로 탭해서 그 시점부터 재생")
                Button { audio.stopPlayback() } label: { Image(systemName: "xmark") }
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.1), radius: 6, y: 2)
        }
    }
}

struct RecordingsPanel: View {
    @ObservedObject var doc: NotebookDocument
    @ObservedObject var audio: AudioService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        audio.startRecording()
                        dismiss()
                    } label: {
                        Label("새 녹음 시작", systemImage: "record.circle").foregroundStyle(.red)
                    }
                    .disabled(audio.isRecording)
                }
                Section("녹음 목록") {
                    if doc.notebook.recordings.isEmpty {
                        Text("아직 녹음이 없어요").foregroundStyle(.secondary)
                    }
                    ForEach(Array(doc.notebook.recordings.reversed())) { r in
                        Button {
                            audio.play(r, at: 0)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.title)
                                    Text(Format.duration(r.duration)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if audio.activeRecording?.id == r.id {
                                    Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                if audio.activeRecording?.id == r.id { audio.stopPlayback() }
                                doc.deleteRecording(r.id)
                            } label: { Label("삭제", systemImage: "trash") }
                        }
                    }
                }
                Section {
                    Text("녹음 중에 쓴 필기는 그 순간과 연결됩니다. 녹음을 재생한 상태에서 손 모양 버튼을 켜고 필기를 탭하면 그 시점부터 들을 수 있어요. 앱이 갑자기 종료돼도 녹음은 보존되고, 다른 앱으로 넘어가도 계속 녹음됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("강의 녹음")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - 레이어 패널

struct LayerPanel: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var doc: NotebookDocument

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(doc.notebook.layers) { layer in
                        LayerRow(layer: layer, isActive: layer.id == doc.notebook.activeLayerId, doc: doc)
                    }
                    .onMove { doc.moveLayers(from: $0, to: $1) }
                    .onDelete { offsets in
                        let ids = offsets.compactMap { doc.notebook.layers[safe: $0]?.id }
                        ids.forEach { doc.deleteLayer($0) }
                    }
                } header: {
                    Text("레이어 (아래 → 위, 최대 \(Notebook.maxLayers)개)")
                } footer: {
                    Text("● 활성 레이어에 필기합니다. ★ 정답 레이어는 상단 눈 버튼으로 노트 전체에서 한 번에 숨기거나 보일 수 있어요. 잠근 레이어는 필기·지우기·선택이 막혀서 원본을 보호합니다. 올가미로 선택한 필기는 메뉴에서 다른 레이어로 옮길 수 있어요.")
                }
                Section {
                    Button { doc.addLayer() } label: { Label("레이어 추가", systemImage: "plus") }
                        .disabled(doc.notebook.layers.count >= Notebook.maxLayers)
                }
            }
            .navigationTitle("레이어")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { EditButton() }
        }
    }
}

struct LayerRow: View {
    let layer: LayerInfo
    let isActive: Bool
    let doc: NotebookDocument
    @State private var name: String

    init(layer: LayerInfo, isActive: Bool, doc: NotebookDocument) {
        self.layer = layer
        self.isActive = isActive
        self.doc = doc
        _name = State(initialValue: layer.name)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { doc.setActiveLayer(layer.id) } label: {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            TextField("이름", text: $name)
                .onSubmit(save)
                .onChange(of: name) { _, _ in save() }
            Spacer()
            toggle(layer.isAnswer ? "star.fill" : "star", on: layer.isAnswer, tint: .orange) { $0.isAnswer.toggle() }
            toggle(layer.isLocked ? "lock.fill" : "lock.open", on: layer.isLocked, tint: .red) { $0.isLocked.toggle() }
            toggle(layer.isHidden ? "eye.slash" : "eye", on: !layer.isHidden, tint: .accentColor) { $0.isHidden.toggle() }
        }
    }

    private func save() {
        guard name != layer.name else { return }
        var l = layer
        l.name = name
        doc.updateLayer(l)
    }

    private func toggle(_ symbol: String, on: Bool, tint: Color, change: @escaping (inout LayerInfo) -> Void) -> some View {
        Button {
            var l = layer
            change(&l)
            doc.updateLayer(l)
        } label: {
            Image(systemName: symbol).foregroundStyle(on ? tint : Color.secondary)
        }
        .buttonStyle(.plain)
    }
}
