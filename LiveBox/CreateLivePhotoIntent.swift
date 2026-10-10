import AppIntents
import UniformTypeIdentifiers

struct CreateLivePhotoIntent: AppIntent {
    static var title: LocalizedStringResource = "生成 Live Photo"
    static var description = IntentDescription("使用视频开头最多 3 秒生成 Live Photo 动态壁纸并保存到相册，保留视频声音与源帧率。图片可选，仅作为静态封面，不插入视频。")
    static var openAppWhenRun = false

    @Parameter(title: "图片", supportedContentTypes: [.image])
    var image: IntentFile?
    @Parameter(title: "视频", supportedContentTypes: [.movie])
    var video: IntentFile?

    static var parameterSummary: some ParameterSummary {
        Summary("将 \(\.$video) 生成 Live Photo，封面 \(\.$image)")
    }

    enum InputError: LocalizedError {
        case missingVariables
        var errorDescription: String? {
            "请在快捷指令编辑器中绑定视频变量。图片封面可选。"
        }
    }

    func perform() async throws -> some IntentResult {
        guard let video else { throw InputError.missingVariables }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let imageURL = try await image?.file(contentType: .image, destinationDirectory: folder)
        let videoURL = try await video.file(contentType: .movie, destinationDirectory: folder)
        let imageAccess = imageURL?.fileURL.startAccessingSecurityScopedResource() ?? false
        let videoAccess = videoURL.fileURL.startAccessingSecurityScopedResource()
        defer {
            if imageAccess { imageURL?.fileURL.stopAccessingSecurityScopedResource() }
            if videoAccess { videoURL.fileURL.stopAccessingSecurityScopedResource() }
        }
        try await LivePhotoMaker.create(image: imageURL?.fileURL, video: videoURL.fileURL)
        return .result()
    }
}

struct LiveBoxShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CreateLivePhotoIntent(), phrases: ["用 \(.applicationName) 生成实况照片"], shortTitle: "生成 Live Photo", systemImageName: "livephoto")
    }
}
