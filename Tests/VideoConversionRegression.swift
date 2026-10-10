import AVFoundation
import CoreMedia
import Foundation
import CoreImage
import VideoToolbox

@main struct Regression {
    static func main() async throws {
        let directory = URL(fileURLWithPath: "/tmp/livebox-regression-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let silent = directory.appendingPathComponent("silent.mov")
        let writer = try AVAssetWriter(outputURL: silent, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240, AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for frame in 0..<180 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pixel: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixel)
            let image = CIImage(color: CIColor(red: Double(frame) / 180, green: 0.2, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 240))
            context.render(image, to: pixel!)
            guard adaptor.append(pixel!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw writer.error! }
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error! }
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: silent)
        let audioAsset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 6, preferredTimescale: 600))
        let videoTrack = try await videoAsset.loadTracks(withMediaType: .video)[0]
        let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio)[0]
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(range, of: audioTrack, at: .zero)
        let audible = directory.appendingPathComponent("audible.mov")
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        try await exporter.export(to: audible, as: .mov)
        let shortComposition = AVMutableComposition()
        try shortComposition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(
            CMTimeRange(start: .zero, duration: CMTime(seconds: 2.01, preferredTimescale: 600)), of: videoTrack, at: .zero)
        let short = directory.appendingPathComponent("short.mov")
        try await AVAssetExportSession(asset: shortComposition, presetName: AVAssetExportPresetHighestQuality)!.export(to: short, as: .mov)
        let rotatedComposition = AVMutableComposition()
        let rotatedTrack = rotatedComposition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try rotatedTrack.insertTimeRange(range, of: videoTrack, at: .zero)
        rotatedTrack.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0)
        let rotated = directory.appendingPathComponent("rotated.mov")
        try await AVAssetExportSession(asset: rotatedComposition, presetName: AVAssetExportPresetPassthrough)!.export(to: rotated, as: .mov)
        let native60 = directory.appendingPathComponent("native60.mov")
        let writer60 = try AVAssetWriter(outputURL: native60, fileType: .mov)
        let input60 = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240, AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
        let adaptor60 = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input60, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        writer60.add(input60)
        guard writer60.startWriting() else { throw writer60.error! }
        writer60.startSession(atSourceTime: .zero)
        for frame in 0..<360 {
            while !input60.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pixel: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor60.pixelBufferPool!, &pixel)
            let image = CIImage(color: CIColor(red: Double(frame) / 360, green: 0.2, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 240))
            context.render(image, to: pixel!)
            guard adaptor60.append(pixel!, withPresentationTime: CMTime(value: Int64(frame), timescale: 60)) else { throw writer60.error! }
        }
        input60.markAsFinished()
        await writer60.finishWriting()
        guard writer60.status == .completed else { throw writer60.error! }
        // Synthetic 4K HLG/Main10 input exercises the HDR reader/converter path.
        // This is not a Dolby Vision camera fixture or a visual tone-mapping oracle.
        let hdr = directory.appendingPathComponent("4k-hlg.mov")
        let hdrWriter = try AVAssetWriter(outputURL: hdr, fileType: .mov)
        let hdrInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: 3840, AVVideoHeightKey: 2160,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020],
            AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel]
        ])
        let hdrAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: hdrInput, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelBufferWidthKey as String: 3840, kCVPixelBufferHeightKey as String: 2160])
        hdrWriter.add(hdrInput)
        guard hdrWriter.startWriting() else { throw hdrWriter.error! }
        hdrWriter.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !hdrInput.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pixel: CVPixelBuffer?
            guard let pool = hdrAdaptor.pixelBufferPool else { throw hdrWriter.error ?? LivePhotoMaker.Failure.invalidVideo }
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { fatalError("HDR test pixel allocation failed") }
            context.render(CIImage(color: CIColor(red: 0.2 + Double(frame) / 50, green: 0.2, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 3840, height: 2160)), to: pixel)
            guard hdrAdaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { throw hdrWriter.error! }
        }
        hdrInput.markAsFinished()
        await hdrWriter.finishWriting()
        guard hdrWriter.status == .completed else { throw hdrWriter.error! }
        let hdrTrack = try await AVURLAsset(url: hdr).loadTracks(withMediaType: .video)[0]
        let hdrFormat = try await hdrTrack.load(.formatDescriptions)[0]
        guard CMFormatDescriptionGetExtension(hdrFormat, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String == AVVideoTransferFunction_ITU_R_2100_HLG else { fatalError("Fixture is not HLG") }
        let customCover = directory.appendingPathComponent("cover.png")
        let coverImage = context.createCGImage(CIImage(color: CIColor(red: 0.05, green: 0.8, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 80, height: 40)), from: CGRect(x: 0, y: 0, width: 80, height: 40))!
        let destination = CGImageDestinationCreateWithURL(customCover as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, coverImage, [kCGImagePropertyOrientation as String: 6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { fatalError("Test cover encoding failed") }
        let wallpaperCases: [(URL, Double, URL?)] = [
            (silent, 0, nil), (audible, 1.25, nil), (silent, 3, nil),
            (silent, 99, nil), (short, 0, nil), (rotated, 1.25, nil), (native60, 0, nil), (native60, 1.25, nil),
            (silent, 1.25, customCover), (audible, 1.25, customCover), (rotated, 1.25, customCover), (native60, 1.25, customCover), (hdr, 0, nil)
        ]
        for (source, requestedStart, selectedCover) in wallpaperCases {
            let output = directory.appendingPathComponent(UUID().uuidString + ".mov")
            let photo = directory.appendingPathComponent(UUID().uuidString + ".heic")
            let id = UUID().uuidString
            try await LivePhotoMaker.writeWallpaper(source, to: output, photo: photo, identifier: id, startTime: requestedStart, coverImage: selectedCover)
            let result = AVURLAsset(url: output)
            let duration = try await result.load(.duration).seconds
            let sourceFPS = Double(try await AVURLAsset(url: source).loadTracks(withMediaType: .video)[0].load(.nominalFrameRate))
            var frames = Int(ceil(duration * sourceFPS - 0.00001))
            guard duration > 0, duration <= 3.001 else { fatalError("Wallpaper duration invalid") }
            let outputAudio = try await result.loadTracks(withMediaType: .audio)
            guard outputAudio.isEmpty == (source != audible) else { fatalError("Source audio presence changed") }
            if let audioTrack = outputAudio.first {
                let audioReader = try AVAssetReader(asset: result)
                let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                audioReader.add(audioOutput)
                guard audioReader.startReading() else { throw audioReader.error! }
                var hasSound = false
                var firstAudio: Double?
                var audioEnd = 0.0
                while let sample = audioOutput.copyNextSampleBuffer() {
                    if let block = CMSampleBufferGetDataBuffer(sample) {
                        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
                        let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
                        guard status == kCMBlockBufferNoErr else { fatalError("Cannot decode audio content") }
                        hasSound = hasSound || bytes.contains(where: { $0 != 0 })
                    }
                    let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    firstAudio = firstAudio ?? time
                    audioEnd = time + CMSampleBufferGetDuration(sample).seconds
                }
                guard hasSound, audioReader.status == .completed, let firstAudio, abs(firstAudio) < 0.06, abs(audioEnd - duration) < 0.06 else { fatalError("Audio timing differs from selected video") }
            }
            let video = try await result.loadTracks(withMediaType: .video)[0]
            let format = try await video.load(.formatDescriptions)[0]
            if source == hdr {
                let size = try await video.load(.naturalSize)
                guard size.width == 1920, size.height == 1080 else { fatalError("4K input did not automatically fit wallpaper dimensions") }
            }
            guard CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC else { fatalError("Wallpaper is not HEVC") }
            let outputFPS = Double(try await video.load(.nominalFrameRate))
            guard abs(outputFPS - sourceFPS) < 1 else { fatalError("Wallpaper source frame rate changed: source=\(source.lastPathComponent), in=\(sourceFPS), out=\(outputFPS), frames=\(frames), duration=\(duration)") }
            guard try await video.load(.preferredTransform) == .identity else { fatalError("Wallpaper retains rotation transform") }
            // Decode the entire movie: frame-rate tags alone cannot detect freezes,
            // timestamp gaps, or the loss of the end of the selected action.
            let frameReader = try AVAssetReader(asset: result)
            let frameOutput = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            frameReader.add(frameOutput)
            guard frameReader.startReading() else { throw frameReader.error! }
            let sourceDuration = try await AVURLAsset(url: source).load(.duration).seconds
            let sourceStart = min(requestedStart, max(0, sourceDuration - duration))
            let sourceAsset = AVURLAsset(url: source)
            let sourceReader = try AVAssetReader(asset: sourceAsset)
            let sourceTrack = try await sourceAsset.loadTracks(withMediaType: .video)[0]
            let sourceOutput = AVAssetReaderTrackOutput(track: sourceTrack, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            sourceReader.add(sourceOutput)
            guard sourceReader.startReading() else { throw sourceReader.error! }
            var sourceColors: [(Double, Double)] = []
            while let sample = sourceOutput.copyNextSampleBuffer() {
                let pixel = CMSampleBufferGetImageBuffer(sample)!
                CVPixelBufferLockBaseAddress(pixel, .readOnly)
                let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
                sourceColors.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, Double(bytes[2]) / 255))
                CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
            }
            guard sourceReader.status == .completed else { throw sourceReader.error! }
            let expectedTimes = sourceColors.enumerated().filter { index, frame in
                let end = index + 1 < sourceColors.count ? sourceColors[index + 1].0 : sourceDuration
                return frame.0 < sourceStart + duration - 0.00001 && end > sourceStart + 0.00001
            }.map { max(0, $0.element.0 - sourceStart) }
            let expectedKeyIndex = expectedTimes.firstIndex(where: { $0 >= duration / 2 })!
            var videoTimestamps: [Double] = []
            var decodedCount = 0
            while let sample = frameOutput.copyNextSampleBuffer() {
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard decodedCount < expectedTimes.count && abs(timestamp - expectedTimes[decodedCount]) < 0.0001 else { fatalError("Video frame timestamp gap at \(decodedCount): \(timestamp)") }
                let pixel = CMSampleBufferGetImageBuffer(sample)!
                CVPixelBufferLockBaseAddress(pixel, .readOnly)
                let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
                let red = Double(bytes[2]) / 255
                CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
                let expectedRed = sourceColors.last(where: { $0.0 <= sourceStart + timestamp + 0.001 })!.1
                guard source == hdr || abs(red - expectedRed) < 0.025 else { fatalError("Video action skipped or frozen at \(timestamp)") }
                videoTimestamps.append(timestamp)
                decodedCount += 1
            }
            frames = decodedCount
            guard frameReader.status == .completed, decodedCount == expectedTimes.count else { fatalError("Decoded video frame count mismatch") }
            let fileMetadata = try await result.load(.metadata)
            guard fileMetadata.first(where: { $0.identifier == .quickTimeMetadataContentIdentifier })?.stringValue == id else { fatalError("Wallpaper content ID mismatch") }
            let metadata = try await result.loadTracks(withMediaType: .metadata)
            let allTypes = try await result.load(.tracks).map { $0.mediaType.rawValue }
            guard metadata.count == 2 else { fatalError("Wallpaper metadata tracks missing: \(metadata.count), all: \(allTypes)") }
            var keyTime = 0.0
            for track in metadata {
                let format = try await track.load(.formatDescriptions)[0]
                let identifiers = CMMetadataFormatDescriptionGetIdentifiers(format) as! [String]
                let isInfo = identifiers.contains("mdta/com.apple.quicktime.live-photo-info")
                let reader = try AVAssetReader(asset: result)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                reader.add(output)
                let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
                reader.startReading()
                var count = 0
                while let group = adaptor.nextTimedMetadataGroup() {
                    guard !group.items.isEmpty else { continue }
                    let timestamp = group.timeRange.start.seconds
                    if isInfo {
                        guard abs(timestamp - videoTimestamps[count]) < 0.001 else { fatalError("Metadata frame timing mismatch: index \(count) time \(timestamp)") }
                        // AVAssetReader exposes these opaque metadata samples as instantaneous.
                        // Check the track range and every adjacent timestamp for coverage instead.
                    } else {
                        keyTime = timestamp
                        let marker = group.items.first { $0.identifier?.rawValue == "mdta/com.apple.quicktime.still-image-time" }
                        guard marker?.numberValue?.intValue == -1 else { fatalError("Wallpaper still marker value changed") }
                        guard abs(timestamp - videoTimestamps[expectedKeyIndex]) < 0.001 else { fatalError("Wallpaper key time mismatch: \(timestamp), frames \(frames), count \(count)") }
                    }
                    count += 1
                }
                guard reader.status == .completed, count == (isInfo ? frames : 1) else { fatalError("Metadata sample count mismatch") }
                if isInfo {
                    let range = try await track.load(.timeRange)
                    guard abs(range.start.seconds) < 0.001, abs(range.duration.seconds - duration) < 0.001 else { fatalError("Metadata timeline does not cover video") }
                }
                let references = try await track.loadAssociatedTracks(ofType: .metadataReferent)
                guard references.contains(where: { $0.trackID == video.trackID }) else { fatalError("Missing metadata video reference") }
            }
            func mdatPayloads(_ data: Data) -> [Data] {
                var offset = 0
                var payloads: [Data] = []
                func number(_ start: Int, _ count: Int) -> Int {
                    Int(data[start..<(start + count)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
                }
                while offset < data.count {
                    guard data.count - offset >= 8 else { fatalError("Truncated MOV atom") }
                    let shortSize = number(offset, 4)
                    let header = shortSize == 1 ? 16 : 8
                    let size = shortSize == 1 ? number(offset + 8, 8) : (shortSize == 0 ? data.count - offset : shortSize)
                    guard size >= header, offset <= data.count - size else { fatalError("Invalid MOV atom size") }
                    if String(data: data[(offset + 4)..<(offset + 8)], encoding: .ascii) == "mdat" {
                        payloads.append(Data(data[(offset + header)..<(offset + size)]))
                    }
                    offset += size
                }
                return payloads
            }
            let originalPayload = mdatPayloads(WallpaperMetadata.movie)[0]
            var expectedPayload = Data()
            for _ in 0..<frames { expectedPayload.append(originalPayload.prefix(144)) }
            expectedPayload.append(originalPayload.suffix(89))
            guard mdatPayloads(try Data(contentsOf: output)).last == expectedPayload else { fatalError("Opaque metadata bytes changed") }
            let photoSource = CGImageSourceCreateWithURL(photo as CFURL, nil)!
            let properties = CGImageSourceCopyPropertiesAtIndex(photoSource, 0, nil) as! [String: Any]
            let makerApple = properties[kCGImagePropertyMakerAppleDictionary as String] as! [String: Any]
            guard makerApple["17"] as? String == id else { fatalError("HEIC content ID mismatch") }
            let dimensions = CMVideoFormatDescriptionGetDimensions(try await video.load(.formatDescriptions)[0])
            if source == rotated {
                guard dimensions.width == 240, dimensions.height == 320 else { fatalError("Portrait dimensions not rendered") }
            }
            let expectedCoverWidth = selectedCover == nil ? Int(dimensions.width) : 40
            let expectedCoverHeight = selectedCover == nil ? Int(dimensions.height) : 80
            guard (properties[kCGImagePropertyPixelWidth as String] as! NSNumber).intValue == expectedCoverWidth,
                  (properties[kCGImagePropertyPixelHeight as String] as! NSNumber).intValue == expectedCoverHeight else { fatalError("Independent cover resolution changed") }
            let cover = CGImageSourceCreateImageAtIndex(photoSource, 0, nil)!
            let generator = AVAssetImageGenerator(asset: result)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let keyFrame = try await generator.image(at: CMTime(seconds: keyTime, preferredTimescale: 600)).image
            func pixelColor(_ image: CGImage) -> [UInt8] {
                var bytes = [UInt8](repeating: 0, count: 4)
                let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return bytes
            }
            let coverColor = pixelColor(cover)
            let videoColor = pixelColor(keyFrame)
            if selectedCover != nil {
                guard coverColor[1] > 170, coverColor[0] < 70, coverColor[2] < 90 else { fatalError("Selected cover colors changed") }
            } else {
                guard zip(coverColor, videoColor).allSatisfy({ abs(Int($0.0) - Int($0.1)) < 10 }) else { fatalError("Video-derived cover is not the marked frame") }
                guard source == hdr || (videoColor[1] < 90 && videoColor[2] > 90) else { fatalError("Video cover changed") }
            }
            print("PASS wallpaper start=\(requestedStart) duration=\(duration) infoFrames=\(frames) cover=HEIC key=\(keyTime)")
        }
        for (input, expected) in [
            (CGSize(width: 4032, height: 3024), CGSize(width: 1920, height: 1440)),
            (CGSize(width: 3024, height: 4032), CGSize(width: 1440, height: 1920)),
            (CGSize(width: 2000, height: 2000), CGSize(width: 1440, height: 1440)),
            (CGSize(width: 1920, height: 1440), CGSize(width: 1920, height: 1440)),
            (CGSize(width: 1080, height: 1920), CGSize(width: 1080, height: 1920)),
            (CGSize(width: 640, height: 480), CGSize(width: 640, height: 480))
        ] {
            guard LivePhotoMaker.wallpaperVideoSize(input) == expected else { fatalError("Wallpaper size bounds or orientation incorrect") }
        }
        print("PASS automatic wallpaper bounds, portrait, square and no upscaling")
    }
}
