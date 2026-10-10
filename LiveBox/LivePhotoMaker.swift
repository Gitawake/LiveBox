import AVFoundation
import Photos
import ImageIO
import UniformTypeIdentifiers
import CoreImage
import OSLog

struct LivePhotoMaker {
    private static let logger = Logger(subsystem: "LiveBox", category: "Conversion")
    enum Failure: LocalizedError {
        case invalidImage, invalidVideo, permission, conversion(String)
        var errorDescription: String? {
            switch self {
            case .invalidImage: return "无法读取图片，请提供 JPEG、PNG 或 HEIC 图片。"
            case .invalidVideo: return "视频没有可用画面或时长。"
            case .permission: return "请在设置中允许 LiveBox 添加照片。"
            case .conversion(let message): return "生成失败：\(message)"
            }
        }
    }

    @discardableResult
    static func create(image: URL?, video: URL, startTime: Double = 0, diagnosticExport: Bool = false) async throws -> [URL] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var keepResources = false
        defer { if !keepResources { try? FileManager.default.removeItem(at: directory) } }
        let identifier = UUID().uuidString
        let photo = directory.appendingPathComponent("photo.heic")
        let movie = directory.appendingPathComponent("video.mov")
        logger.notice("LiveBox: conversion started")
        try await writeWallpaper(video, to: movie, photo: photo, identifier: identifier, startTime: startTime, coverImage: image)
        logger.notice("LiveBox: media files created; requesting photo-library permission")
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.permission }
        logger.notice("LiveBox: saving paired resources to Photos")
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: photo, options: nil)
                request.addResource(with: .pairedVideo, fileURL: movie, options: nil)
            }
        } catch {
            let detail = error as NSError
            logger.error("LiveBox: Photos save failed; domain=\(detail.domain, privacy: .public), code=\(detail.code), description=\(detail.localizedDescription, privacy: .public)")
            throw error
        }
        logger.notice("LiveBox: Photos save completed")
        guard diagnosticExport else { return [] }
        let report = directory.appendingPathComponent("diagnostics.json")
        do {
            let sourceAsset = AVURLAsset(url: video)
            let resultAsset = AVURLAsset(url: movie)
            let sourceTrack = try await sourceAsset.loadTracks(withMediaType: .video)[0]
            let resultTrack = try await resultAsset.loadTracks(withMediaType: .video)[0]
            let size = try await resultTrack.load(.naturalSize)
            let details: [String: Any] = [
                "systemVersion": ProcessInfo.processInfo.operatingSystemVersionString,
                "contentIdentifier": identifier,
                "requestedStartSeconds": startTime,
                "independentCover": image != nil,
                "sourceDurationSeconds": try await sourceAsset.load(.duration).seconds,
                "sourceNominalFrameRate": try await sourceTrack.load(.nominalFrameRate),
                "outputDurationSeconds": try await resultAsset.load(.duration).seconds,
                "outputNominalFrameRate": try await resultTrack.load(.nominalFrameRate),
                "outputWidth": size.width, "outputHeight": size.height,
                "audioPresent": !(try await resultAsset.loadTracks(withMediaType: .audio)).isEmpty,
                "coverPolicy": "independent still or decoded midpoint frame; no frame insertion",
                "motionMetadata": "reference template; not source sensor information",
                "wallpaperEligibility": "not determined by file generation"
            ]
            try JSONSerialization.data(withJSONObject: details, options: [.prettyPrinted, .sortedKeys]).write(to: report, options: .atomic)
            keepResources = true
            return [photo, movie, report]
        } catch {
            // Saving succeeded; diagnostics must not turn it into a reported save failure.
            logger.error("LiveBox: diagnostic export unavailable: \(error.localizedDescription, privacy: .public)")
            return []
        }

    }

}

extension LivePhotoMaker {
    // This profile follows device-tested open-source results; iOS is the final judge.
    // Fit either orientation inside the camera sample's video dimensions.
    static func wallpaperVideoSize(_ size: CGSize) -> CGSize {
        let scale = min(1, 1920 / max(size.width, size.height), 1440 / min(size.width, size.height))
        return CGSize(width: max(2, Int(size.width * scale) / 2 * 2),
                      height: max(2, Int(size.height * scale) / 2 * 2))
    }

    private static func writeWallpaper(_ source: URL, to output: URL, photo: URL,
                                       identifier: String, startTime: Double, coverImage: URL? = nil) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, startTime.isFinite,
              let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw Failure.invalidVideo
        }
        let sourceFrameDuration = try await track.load(.minFrameDuration)
        let sourceFrameRate = Double(try await track.load(.nominalFrameRate))
        guard sourceFrameRate.isFinite, sourceFrameRate > 0 else { throw Failure.invalidVideo }
        let frameDuration = CMTimeConvertScale(
            sourceFrameDuration.isNumeric && sourceFrameDuration.seconds > 0
                ? sourceFrameDuration : CMTime(seconds: 1 / sourceFrameRate, preferredTimescale: 60000),
            timescale: 60000, method: .roundHalfAwayFromZero)
        guard frameDuration.value > 0 else { throw Failure.invalidVideo }
        logger.notice("LiveBox: wallpaper source fps=\(sourceFrameRate), frame interval=\(frameDuration.seconds)")
        let frameCount = Int(floor(min(3, duration) / frameDuration.seconds + 0.000001))
        guard frameCount > 0 else { throw Failure.invalidVideo }
        let length = CMTime(seconds: min(3, duration), preferredTimescale: 60000)
        let start = CMTime(seconds: min(max(0, startTime), max(0, duration - length.seconds)), preferredTimescale: 600)
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width >= 2, bounds.height >= 2 else {
            throw Failure.invalidVideo
        }
        let canvas = wallpaperVideoSize(bounds.size)
        let composition = AVMutableComposition()
        guard let composedTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.invalidVideo
        }
        try composedTrack.insertTimeRange(CMTimeRange(start: start, duration: length), of: track, at: .zero)
        let renderTransform = transform.concatenating(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY)).concatenating(CGAffineTransform(scaleX: canvas.width / bounds.width, y: canvas.height / bounds.height))
        let videoContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        var composedAudio: AVMutableCompositionTrack?
        if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
            guard let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw Failure.invalidVideo }
            let audioRange = try await sourceAudio.load(.timeRange)
            let intersection = CMTimeRangeGetIntersection(CMTimeRange(start: start, duration: length), otherRange: audioRange)
            if intersection.duration.seconds > 0 {
                try audio.insertTimeRange(intersection, of: sourceAudio, at: CMTimeSubtract(intersection.start, start))
                composedAudio = audio
            }
        }
        let reader = try AVAssetReader(asset: composition)
        let videoOutput = AVAssetReaderTrackOutput(track: composedTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard reader.canAdd(videoOutput) else { throw Failure.invalidVideo }
        reader.add(videoOutput)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(canvas.width), AVVideoHeightKey: Int(canvas.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoExpectedSourceFrameRateKey: sourceFrameRate,
                AVVideoMaxKeyFrameIntervalKey: max(1, Int(sourceFrameRate.rounded())),
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        if let format = try await track.load(.formatDescriptions).first,
           let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String,
           transfer != AVVideoTransferFunction_ITU_R_2100_HLG && transfer != AVVideoTransferFunction_SMPTE_ST_2084_PQ,
           let primaries = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String,
           let matrix = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix) as? String {
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: primaries, AVVideoTransferFunctionKey: transfer, AVVideoYCbCrMatrixKey: matrix]
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw Failure.conversion("此设备无法编码壁纸所需的 HEVC 视频。")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.mediaTimeScale = 60000
        guard writer.canAdd(videoInput) else { throw Failure.invalidVideo }
        writer.add(videoInput)
        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(canvas.width),
            kCVPixelBufferHeightKey as String: Int(canvas.height)
        ])
        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let composedAudio {
            let output = AVAssetReaderTrackOutput(track: composedAudio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128000])
            guard reader.canAdd(output), writer.canAdd(input) else { throw Failure.conversion("无法保留视频声音。") }
            reader.add(output); writer.add(input)
            audioOutput = output; audioInput = input
        }
        let contentID = AVMutableMetadataItem()
        contentID.identifier = .quickTimeMetadataContentIdentifier
        contentID.value = identifier as NSString
        contentID.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [contentID]

        var keyFrameIndex: Int?
        var keyTime = CMTime.zero
        var frameTimes: [Double] = []
        guard writer.startWriting(), reader.startReading() else {
            writer.cancelWriting(); reader.cancelReading()
            throw writer.error ?? reader.error ?? Failure.invalidVideo
        }
        writer.startSession(atSourceTime: .zero)
        do {
            var videoFinished = false
            var audioFinished = audioOutput == nil
            var videoFrames = 0
            let clock = ContinuousClock()
            var lastProgress = clock.now
            while !videoFinished || !audioFinished {
                try Task.checkCancellation()
                guard writer.status == .writing, reader.status != .failed else {
                    throw writer.error ?? reader.error ?? Failure.invalidVideo
                }
                var progress = false
                if !videoFinished, videoInput.isReadyForMoreMediaData {
                    guard let sample = videoOutput.copyNextSampleBuffer() else {
                        videoInput.markAsFinished()
                        videoFinished = true
                        continue
                    }
                    let time = CMTimeConvertScale(CMTimeMaximum(.zero, CMSampleBufferGetPresentationTimeStamp(sample)), timescale: 60000, method: .roundHalfAwayFromZero)
                    guard time.seconds < length.seconds else { continue }
                    guard frameTimes.last.map({ time.seconds > $0 }) ?? true,
                          let pixel = CMSampleBufferGetImageBuffer(sample) else { throw Failure.invalidVideo }
                    let isKeyFrame = keyFrameIndex == nil && time.seconds >= length.seconds / 2
                    if isKeyFrame { keyFrameIndex = videoFrames; keyTime = time }
                    guard let pool = pixelAdaptor.pixelBufferPool else { throw Failure.invalidImage }
                    var renderedPixel: CVPixelBuffer?
                    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &renderedPixel) == kCVReturnSuccess,
                          let outputPixel = renderedPixel else { throw Failure.invalidImage }
                    videoContext.render(CIImage(cvPixelBuffer: pixel).transformed(by: renderTransform), to: outputPixel)
                    guard pixelAdaptor.append(outputPixel, withPresentationTime: time) else { throw writer.error ?? Failure.invalidVideo }
                    frameTimes.append(time.seconds)
                    videoFrames += 1
                    progress = true
                }
                if !audioFinished, let audioInput, let audioOutput, audioInput.isReadyForMoreMediaData {
                    if let sample = audioOutput.copyNextSampleBuffer() {
                        guard audioInput.append(sample) else { throw writer.error ?? Failure.invalidVideo }
                    } else {
                        audioInput.markAsFinished()
                        audioFinished = true
                    }
                    progress = true
                }
                if progress {
                    lastProgress = clock.now
                } else {
                    guard lastProgress.duration(to: clock.now) < .seconds(30) else {
                        throw Failure.conversion("壁纸编码长时间无响应，请重试。")
                    }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
            }
            guard reader.status == .completed, videoFrames > 0 else {
                throw reader.error ?? Failure.conversion("壁纸画面与动态元数据不匹配，请更换素材重试。")
            }
            writer.endSession(atSourceTime: length)
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? Failure.invalidVideo }
        } catch {
            reader.cancelReading(); writer.cancelWriting()
            throw error
        }
        guard let keyFrameIndex else { throw Failure.invalidVideo }
        try WallpaperMetadataInjector.inject(into: output, frameTimes: frameTimes, duration: length.seconds, keyFrame: keyFrameIndex)
        // Use the actual encoded key frame, so cover pixels, orientation and timing agree.
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        logger.notice("LiveBox: wallpaper video encoded; frames=\(frameTimes.count), cover time=\(keyTime.seconds)")
        let videoKeyFrame = try await generator.image(at: keyTime).image
        // The still resource has its own resolution, as in camera Live Photos.
        // A selected still is independent; it never replaces a video frame.
        let keyFrame: CGImage
        if let coverImage {
            guard let original = CIImage(contentsOf: coverImage, options: [.applyOrientationProperty: true]),
                  let fullResolution = CIContext().createCGImage(original, from: original.extent) else { throw Failure.invalidImage }
            keyFrame = fullResolution
        } else {
            keyFrame = videoKeyFrame
        }
        logger.notice("LiveBox: cover pixels width=\(keyFrame.width), height=\(keyFrame.height), bits/component=\(keyFrame.bitsPerComponent), bits/pixel=\(keyFrame.bitsPerPixel), bytes/row=\(keyFrame.bytesPerRow)")
        guard let destination = CGImageDestinationCreateWithURL(photo as CFURL, UTType.heic.identifier as CFString, 1, nil) else {
            throw Failure.invalidImage
        }
        var properties: [String: Any] = [:]
        var makerApple: [String: Any] = [:]
        if let coverImage, let imageSource = CGImageSourceCreateWithURL(coverImage as CFURL, nil),
           let originalProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] {
            // Preserve still-photo capture metadata rather than replacing it all
            // with the pairing ID. Pixel orientation and dimensions are updated.
            if var exif = originalProperties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                exif[kCGImagePropertyExifPixelXDimension as String] = keyFrame.width
                exif[kCGImagePropertyExifPixelYDimension as String] = keyFrame.height
                properties[kCGImagePropertyExifDictionary as String] = exif
            }
            if var tiff = originalProperties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                tiff[kCGImagePropertyTIFFOrientation as String] = 1
                properties[kCGImagePropertyTIFFDictionary as String] = tiff
            }
            makerApple = originalProperties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any] ?? [:]
        }
        makerApple["17"] = identifier
        properties[kCGImagePropertyMakerAppleDictionary as String] = makerApple
        properties[kCGImagePropertyOrientation as String] = 1
        properties[kCGImageDestinationLossyCompressionQuality as String] = 1.0
        CGImageDestinationAddImage(destination, keyFrame, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.invalidImage }
        // Verify the written cover can actually be decoded, rather than trusting
        // the encoder's success alone. Keep its pixels and timing unchanged.
        guard let savedSource = CGImageSourceCreateWithURL(photo as CFURL, nil),
              let savedCover = CGImageSourceCreateImageAtIndex(savedSource, 0, nil),
              savedCover.width == keyFrame.width, savedCover.height == keyFrame.height else {
            throw Failure.conversion("生成的壁纸封面无法正确解码。")
        }
        logger.notice("LiveBox: HEIC cover decoded successfully")
    }


}
