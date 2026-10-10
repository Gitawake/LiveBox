@main struct InspectRealVideo {
 static func main() async throws {
  let input = URL(fileURLWithPath: CommandLine.arguments[1])
  let output = URL(fileURLWithPath: CommandLine.arguments[2])
  let start = Double(CommandLine.arguments[3])!
  try await LivePhotoMaker.writeWallpaper(input, to: output.appendingPathComponent("video.mov"), photo: output.appendingPathComponent("photo.heic"), identifier: "11111111-2222-3333-4444-555555555555", startTime: start, coverImage: CommandLine.arguments.count > 4 ? URL(fileURLWithPath: CommandLine.arguments[4]) : nil)
  let photoURL = output.appendingPathComponent("photo.heic")
  guard let photoSource = CGImageSourceCreateWithURL(photoURL as CFURL, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(photoSource, 0, nil) as? [String: Any],
        let maker = properties[kCGImagePropertyMakerAppleDictionary as String] as? [String: Any],
        CGImageSourceCreateImageAtIndex(photoSource, 0, nil) != nil else { throw LivePhotoMaker.Failure.invalidImage }
  print("PHOTO", properties[kCGImagePropertyPixelWidth as String]!, properties[kCGImagePropertyPixelHeight as String]!)
  let asset = AVURLAsset(url: output.appendingPathComponent("video.mov"))
  let contentID = try await asset.load(.metadata).first { $0.identifier == .quickTimeMetadataContentIdentifier }?.stringValue
  guard contentID == maker["17"] as? String else { throw LivePhotoMaker.Failure.invalidVideo }
  print("PAIR_IDS_MATCH", true)
  for track in try await asset.load(.tracks) {
   print("TRACK", track.trackID, track.mediaType.rawValue, try await track.load(.timeRange))
  }
  let video = try await asset.loadTracks(withMediaType: .video)[0]
  let reader = try AVAssetReader(asset: asset)
  let decoded = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
  reader.add(decoded); guard reader.startReading() else { throw reader.error! }
  var times:[Double] = []
  while let sample = decoded.copyNextSampleBuffer() { times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds) }
  guard reader.status == .completed else { throw reader.error! }
  print("FRAMES", times.count, "FIRST", times.first!, "LAST", times.last!, "MAX_GAP", zip(times.dropFirst(), times).map { $0-$1 }.max()!)
  for track in try await asset.loadTracks(withMediaType: .metadata) {
   let reader = try AVAssetReader(asset:asset)
   let raw = AVAssetReaderTrackOutput(track:track, outputSettings:nil)
   reader.add(raw); let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput:raw)
   reader.startReading()
   var count = 0
   while let group = adaptor.nextTimedMetadataGroup() {
    if !group.items.isEmpty {
     if group.items.contains(where: { $0.identifier?.rawValue == "mdta/com.apple.quicktime.live-photo-info" }) {
      guard count < times.count, abs(group.timeRange.start.seconds - times[count]) < 0.0001 else { throw LivePhotoMaker.Failure.invalidVideo }
     }
     if let marker = group.items.first(where: { $0.identifier?.rawValue == "mdta/com.apple.quicktime.still-image-time" }) {
      guard marker.numberValue?.intValue == -1, times.contains(where: { abs($0 - group.timeRange.start.seconds) < 0.0001 }) else { throw LivePhotoMaker.Failure.invalidVideo }
     }
     count += 1; if count == 1 { print("METADATA", track.trackID, group.timeRange, group.items.map { $0.identifier?.rawValue ?? "" }) } }
   }
   print("METADATA_COUNT",track.trackID,count)
  }
 }
}
