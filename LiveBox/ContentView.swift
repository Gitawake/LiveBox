import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import AVKit
import ImageIO

struct ContentView: View {
    @State private var image: URL?
    @State private var video: URL?
    @State private var videoDuration = 0.0
    @State private var videoStart = 0.0
    @State private var pickerRequest: MaterialRequest?
    @State private var selectionSession = MaterialSelectionSession()
    @State private var busy = false
    @State private var loading = false
    @State private var message: String?
    @State private var diagnosticResources: [URL] = []
    @State private var showingTools = false
    @State private var saved = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    VStack(alignment: .leading, spacing: 9) {
                        Text(video == nil ? "让瞬间，\n留在屏幕上。" : "留下这一段。")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .tracking(-1.2).fixedSize(horizontal: false, vertical: true)
                        Text(video == nil ? "一段视频，一张会动的照片。" : "选好片段，再为它留一张封面。")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    videoEditor
                    coverEditor
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield")
                        Text("在设备上处理 · 保留原声")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24)
                .frame(maxWidth: 600).frame(maxWidth: .infinity)
            }
            .background(pageBackground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) { saveBar }
            .toolbar(.hidden, for: .navigationBar)
            .tint(LiveBoxStyle.accent)
            .sheet(isPresented: $showingTools) { toolsSheet }
            .sheet(item: $pickerRequest) { request in
                AlbumPicker(selectingImage: request.kind == .image, onStart: {
                    guard selectionSession.isCurrent(request) else { return }
                    pickerRequest = nil
                    loading = true
                }, onFinish: { result in
                    guard selectionSession.isCurrent(request) else {
                        if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
                        return
                    }
                    switch result {
                    case .success(let url):
                        if request.kind == .image {
                            if let old = image { try? FileManager.default.removeItem(at: old) }
                            image = url
                            selectionSession.finish(request)
                            loading = false
                        } else {
                            Task { @MainActor in
                                do {
                                    let asset = AVURLAsset(url: url)
                                    let duration = try await asset.load(.duration).seconds
                                    guard duration.isFinite, duration > 0,
                                          try await asset.loadTracks(withMediaType: .video).first != nil else {
                                        throw LivePhotoMaker.Failure.invalidVideo
                                    }
                                    guard selectionSession.isCurrent(request) else {
                                        try? FileManager.default.removeItem(at: url)
                                        return
                                    }
                                    // Commit URL, duration and selection together after validation.
                                    let previous = video
                                    video = url
                                    videoDuration = duration
                                    videoStart = 0
                                    selectionSession.finish(request)
                                    loading = false
                                    if let previous { try? FileManager.default.removeItem(at: previous) }
                                } catch {
                                    try? FileManager.default.removeItem(at: url)
                                    guard selectionSession.isCurrent(request) else { return }
                                    selectionSession.finish(request)
                                    loading = false
                                    message = error.localizedDescription
                                }
                            }
                        }
                    case .failure(let error):
                        selectionSession.finish(request)
                        loading = false
                        message = error.localizedDescription
                    }
                }, onCancel: {
                    guard selectionSession.finish(request) else { return }
                    pickerRequest = nil
                    loading = false
                })
            }
            .alert("LiveBox", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("好", role: .cancel) { message = nil }
            } message: { Text(message ?? "") }
        }
    }

    private var pageBackground: Color {
        colorScheme == .dark ? Color(red: 0.07, green: 0.08, blue: 0.10) : Color(red: 0.96, green: 0.96, blue: 0.94)
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Image(systemName: "livephoto").font(.system(size: 23, weight: .medium)).foregroundStyle(LiveBoxStyle.accent)
                Text("LiveBox").font(.system(size: 21, weight: .bold, design: .rounded)).tracking(-0.5)
            }
            Spacer()
            Button { showingTools = true } label: {
                Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44).background(.primary.opacity(0.05), in: Circle())
            }
            .foregroundStyle(.primary).accessibilityLabel("帮助与工具")
        }
    }

    private var videoEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let video, videoDuration > 0 {
                HStack {
                    Label("视频片段", systemImage: "film").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("更换", systemImage: "arrow.triangle.2.circlepath") { beginPicking(.video) }
                        .font(.subheadline.weight(.medium))
                }
                VideoSegmentPicker(url: video, duration: videoDuration, start: $videoStart, busy: busy)
                    .id(video)
            } else {
                Button { beginPicking(.video) } label: {
                    VStack(spacing: 20) {
                        ZStack {
                            Circle().stroke(LiveBoxStyle.accent.opacity(0.06), lineWidth: 1).frame(width: 148, height: 148)
                            Circle().stroke(LiveBoxStyle.accent.opacity(0.10), lineWidth: 1).frame(width: 116, height: 116)
                            RoundedRectangle(cornerRadius: 26).fill(LiveBoxStyle.accent.opacity(0.08))
                                .frame(width: 76, height: 92).rotationEffect(.degrees(-9))
                            RoundedRectangle(cornerRadius: 26).fill(LiveBoxStyle.accent)
                                .frame(width: 76, height: 92).rotationEffect(.degrees(7))
                                .shadow(color: LiveBoxStyle.accent.opacity(0.2), radius: 18, y: 10)
                            Image(systemName: "play.fill").font(.system(size: 27)).foregroundStyle(.white)
                        }
                        VStack(spacing: 8) {
                            Text(loading ? "正在读取视频…" : "从一段视频开始")
                                .font(.headline).foregroundStyle(.primary)
                            Text("从相册选取，保留最多 3 秒")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            if loading { ProgressView().tint(.white) }
                            else { Image(systemName: "plus") }
                            Text(loading ? "读取中" : "选择视频")
                        }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.vertical, 13)
                        .background(LiveBoxStyle.accent, in: Capsule())
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 22)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 28))
                    .overlay { RoundedRectangle(cornerRadius: 28).strokeBorder(.primary.opacity(0.05), lineWidth: 1) }
                    .contentShape(RoundedRectangle(cornerRadius: 28))
                }.buttonStyle(.plain).accessibilityLabel("选择视频，最多保留 3 秒")
            }
        }.disabled(busy || loading)
    }

    private var coverEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Text("静态封面").font(.subheadline.weight(.semibold))
                Text("可选").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if image != nil {
                    Button("恢复视频帧") {
                        if let image { try? FileManager.default.removeItem(at: image) }
                        image = nil
                        saved = false
                    }.font(.caption.weight(.medium))
                    .accessibilityLabel("使用视频帧作封面")
                }
            }
            Button { beginPicking(.image) } label: {
                HStack(spacing: 14) {
                    CoverThumbnail(url: image)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(image == nil ? "使用视频中的画面" : "已选择图片封面")
                            .font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                        Text(image == nil ? "也可以选择一张高清图片" : "保留原尺寸，仅作为静态封面")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: image == nil ? "plus" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(14).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
                .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(.primary.opacity(0.05), lineWidth: 1) }
            }.buttonStyle(.plain)
        }.disabled(busy || loading)
    }

    private var saveBar: some View {
        VStack(spacing: 9) {
            Button(action: generate) {
                HStack(spacing: 9) {
                    if busy { ProgressView().tint(.white) }
                    else { Image(systemName: saved ? "checkmark.circle.fill" : "livephoto") }
                    Text(busy ? "正在生成实况照片…" : saved ? "再次生成并保存" : "生成并保存")
                    Spacer()
                    if !busy { Image(systemName: "arrow.down.to.line") }
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(video == nil || loading ? Color.secondary : .white)
                .padding(.horizontal, 20).frame(height: 56)
                .background(video == nil || loading ? Color.primary.opacity(0.06) : LiveBoxStyle.accent, in: RoundedRectangle(cornerRadius: 18))
            }.buttonStyle(.plain).disabled(video == nil || busy || loading)
            Text(loading ? "正在从相册读取素材" : saved ? "已保存到相册" : video == nil ? "先选择视频，开始制作" : "保存为 Live Photo · 最多 3 秒")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 8)
        .frame(maxWidth: 600).frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    private var toolsSheet: some View {
        NavigationStack {
            List {
                Section("使用方式") {
                    Label("选择视频，再拖动选框截取最多 3 秒。", systemImage: "film")
                    Label("图片只作静态封面，不插入视频。", systemImage: "photo")
                    Label("生成后会保存到系统相册。", systemImage: "square.and.arrow.down")
                }
                Section("快捷指令") {
                    Text("在「快捷指令」中搜索 LiveBox，添加「生成 Live Photo」，绑定视频变量。图片变量可选。")
                    Text("绑定已有变量，无需每次打开 App 选择素材。首次运行需要允许添加照片。")
                        .foregroundStyle(.secondary)
                }
                Section("关于 LiveBox") {
                    LabeledContent("应用", value: "LiveBox")
                    LabeledContent("版本", value: appVersion)
                    Text("将视频变成 Live Photo，让瞬间留在屏幕上。所有素材均在设备上处理。")
                        .foregroundStyle(.secondary)
                }
                Section("关于输出") {
                    Text("视频保持比例缩小到长边不超过 1920、短边不超过 1440 像素。独立图片保留原像素尺寸，视频保留原声和实际帧时间。")
                    Text("锁屏动态效果由 iOS 判定，部分素材可能无法开启。")
                        .foregroundStyle(.secondary)
                }
                if !diagnosticResources.isEmpty {
                    Section("问题排查") {
                        ShareLink(items: diagnosticResources) {
                            Label("导出最近生成的资源", systemImage: "square.and.arrow.up")
                        }
                        Text("包含 HEIC、MOV 和参数报告，可用于检查兼容性。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("帮助与工具").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showingTools = false } } }
        }.tint(LiveBoxStyle.accent)
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func generate() {
        guard let video, !busy, !loading else { return }
        let selectedImage = image
        let selectedStart = videoStart
        busy = true
        saved = false
        Task { @MainActor in
            do {
                let resources = try await LivePhotoMaker.create(image: selectedImage, video: video, startTime: selectedStart, diagnosticExport: true)
                if let previous = diagnosticResources.first {
                    try? FileManager.default.removeItem(at: previous.deletingLastPathComponent())
                }
                diagnosticResources = resources
                saved = true
                message = "Live Photo 已保存到相册。"
            } catch { message = error.localizedDescription }
            busy = false
        }
    }

    private func beginPicking(_ kind: MaterialKind) {
        guard !busy, !loading else { return }
        let request = MaterialRequest(kind: kind)
        saved = false
        selectionSession.begin(request)
        pickerRequest = request
    }

}

private struct VideoSegmentPicker: View {
    let url: URL
    let duration: Double
    @Binding var start: Double
    let busy: Bool
    @State private var player: AVPlayer?
    @State private var thumbnails: [UIImage] = []
    @State private var dragStart: Double?

    private var length: Double { min(3, duration) }
    private var maximumStart: Double { max(0, duration - length) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VideoPlayer(player: player)
                .frame(height: 320)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 24))
            if duration > 3 {
                Text("拖动选框，留下你喜欢的 3 秒")
                    .font(.caption).foregroundStyle(.secondary)
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let boxWidth = min(width, max(44, width * length / duration))
                    let travel = max(0, width - boxWidth)
                    let offset = maximumStart > 0 ? travel * start / maximumStart : 0
                    ZStack(alignment: .leading) {
                        HStack(spacing: 0) {
                            ForEach(thumbnails.indices, id: \.self) { index in
                                Image(uiImage: thumbnails[index])
                                    .resizable().scaledToFill()
                                    .frame(width: width / CGFloat(thumbnails.count), height: 60)
                                    .clipped()
                            }
                        }
                        .frame(width: width, height: 60)
                        .background(Color.secondary.opacity(0.2))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentColor.opacity(0.15))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(Color.accentColor, lineWidth: 3)
                            }
                            .overlay { Image(systemName: "arrow.left.and.right").foregroundStyle(.white).shadow(radius: 2) }
                            .frame(width: boxWidth, height: 60)
                            .offset(x: offset)
                            .gesture(DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if dragStart == nil { dragStart = start }
                                    guard travel > 0 else { return }
                                    start = min(maximumStart, max(0, (dragStart ?? start) + value.translation.width / travel * maximumStart))
                                }
                                .onEnded { _ in dragStart = nil })
                            .accessibilityLabel("3 秒视频选区")
                            .accessibilityValue(String(format: "起点 %.2f 秒", start))
                            .accessibilityAdjustableAction { direction in
                                switch direction {
                                case .increment: start = min(maximumStart, start + 0.1)
                                case .decrement: start = max(0, start - 0.1)
                                @unknown default: break
                                }
                            }
                    }
                }
                .frame(height: 60)
            }
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("所选片段").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.2f – %.2f 秒", start, start + length))
                        .font(.subheadline.weight(.medium)).monospacedDigit()
                }
                Spacer()
                Button { seekToSelection(play: true) } label: {
                    Label("预览", systemImage: "play.fill")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 17).padding(.vertical, 12)
                        .background(LiveBoxStyle.accent.opacity(0.08), in: Capsule())
                }.buttonStyle(.plain).foregroundStyle(LiveBoxStyle.accent)
                .accessibilityLabel("预览所选片段")
            }

        }
        .task(id: url) {
            player = AVPlayer(url: url)
            seekToSelection(play: false)
            guard duration > 3 else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 160, height: 120)
            var images: [UIImage] = []
            for index in 0..<10 {
                guard !Task.isCancelled else { return }
                let time = CMTime(seconds: duration * (Double(index) + 0.5) / 10, preferredTimescale: 600)
                if let result = try? await generator.image(at: time) {
                    images.append(UIImage(cgImage: result.image))
                }
            }
            guard !Task.isCancelled else { return }
            thumbnails = images
        }
        .onChange(of: busy) { _, isBusy in
            if isBusy { player?.pause() }
        }
        .onChange(of: start) { _, _ in seekToSelection(play: false) }
        .onDisappear { player?.pause() }
    }

    private func seekToSelection(play: Bool) {
        guard let player else { return }
        player.pause()
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: start + length, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            if play && finished { player.play() }
        }
    }
}

private enum LiveBoxStyle {
    static let accent = Color(red: 0.24, green: 0.32, blue: 0.91)
}

private struct CoverThumbnail: View {
    let url: URL?
    @State private var thumbnail: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(LiveBoxStyle.accent.opacity(0.07))
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").font(.system(size: 21)).foregroundStyle(LiveBoxStyle.accent)
            }
        }
        .frame(width: 56, height: 64).clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
        .task(id: url) {
            thumbnail = nil
            guard let url else { return }
            let result = await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 192
                      ] as CFDictionary) else { return Optional<UIImage>.none }
                return UIImage(cgImage: image)
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = result
        }
    }
}

// Selection lifecycle is independent of callback delivery order.
private enum MaterialKind { case image, video }

private struct MaterialRequest: Identifiable {
    let id = UUID()
    let kind: MaterialKind
}

private struct MaterialSelectionSession {
    private var activeID: UUID?
    mutating func begin(_ request: MaterialRequest) { activeID = request.id }
    func isCurrent(_ request: MaterialRequest) -> Bool { activeID == request.id }
    @discardableResult
    mutating func finish(_ request: MaterialRequest) -> Bool {
        guard isCurrent(request) else { return false }
        activeID = nil
        return true
    }
}
// End selection lifecycle.

private struct AlbumPicker: UIViewControllerRepresentable {
    let selectingImage: Bool
    let onStart: () -> Void
    let onFinish: (Result<URL, Error>) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration()
        configuration.filter = selectingImage ? .images : .videos
        configuration.selectionLimit = 1
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: PHPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: AlbumPicker
        private var handledSelection = false
        init(_ parent: AlbumPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard !handledSelection else { return }
            handledSelection = true
            guard let provider = results.first?.itemProvider else { parent.onCancel(); return }
            parent.onStart()
            let type = parent.selectingImage ? UTType.image.identifier : UTType.movie.identifier
            provider.loadFileRepresentation(forTypeIdentifier: type) { [parent] url, error in
                let result: Result<URL, Error>
                do {
                    if let error { throw error }
                    guard let url else {
                        throw NSError(domain: "LiveBox", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法读取相册素材，请重试。"])
                    }
                    // The provider URL is only valid during this callback.
                    let copy = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(url.pathExtension)
                    try FileManager.default.copyItem(at: url, to: copy)
                    result = .success(copy)
                } catch { result = .failure(error) }
                DispatchQueue.main.async { parent.onFinish(result) }
            }
        }
    }
}
