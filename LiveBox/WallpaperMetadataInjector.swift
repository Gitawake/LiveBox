import Foundation

// Adapted from live-photo-batch's metadata-only MOV injection (MIT).
// Copyright (c) 2026 Haoning Wu. See ThirdPartyNotices.md.
enum WallpaperMetadataInjector {
    private struct Box {
        let type: String
        let offset: Int
        let size: Int
        let header: Int
        var payload: Int { offset + header }
        var end: Int { offset + size }
    }

    static func inject(into url: URL, frameTimes: [Double], duration: Double, keyFrame: Int) throws {
        let frames = frameTimes.count
        guard duration.isFinite, duration > 0, frames > 0, keyFrame >= 0, keyFrame < frames,
              frameTimes.first == 0, frameTimes.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < duration }) else { throw failure() }
        let ticks = frameTimes.map { UInt64(($0 * 60000).rounded()) } + [UInt64((duration * 60000).rounded())]
        let intervals = zip(ticks.dropFirst(), ticks).map { $0 > $1 ? $0 - $1 : 0 }
        guard intervals.allSatisfy({ $0 > 0 }) else { throw failure() }
        var movie = try Data(contentsOf: url)
        let top = try boxes(movie, from: 0, to: movie.count)
        guard let originalMoov = top.first(where: { $0.type == "moov" }) else { throw failure() }
        var moov = Data(movie[originalMoov.offset..<originalMoov.end])
        let moovBox = try root(moov)
        guard moovBox.header == 8 else { throw failure() }
        let tracks = try children(moov, moovBox).filter { $0.type == "trak" }
        guard let video = try tracks.first(where: { track in
            let handler = try descendant(moov, track, ["mdia", "hdlr"])
            return String(data: moov[(handler.payload + 8)..<(handler.payload + 12)], encoding: .ascii) == "vide"
        }) else { throw failure() }
        let maximumTrackID = try tracks.map { track -> UInt64 in
            let header = try child(moov, track, "tkhd")
            return try read(moov, at: header.payload + (moov[header.payload] == 1 ? 20 : 12), count: 4)
        }.max() ?? 0
        let handler = try descendant(moov, video, ["mdia", "hdlr"])
        guard String(data: moov[(handler.payload + 8)..<(handler.payload + 12)], encoding: .ascii) == "vide" else { throw failure() }
        let videoSamples = try descendant(moov, video, ["mdia", "minf", "stbl", "stsz"])
        guard try read(moov, at: videoSamples.payload + 8, count: 4) == UInt64(frames) else { throw failure() }
        let videoHeader = try child(moov, video, "tkhd")
        let videoID = try read(moov, at: videoHeader.payload + (moov[videoHeader.payload] == 1 ? 20 : 12), count: 4)
        let movieHeader = try child(moov, moovBox, "mvhd")
        let scale = try read(moov, at: movieHeader.payload + (moov[movieHeader.payload] == 1 ? 20 : 12), count: 4)
        guard scale > 0 else { throw failure() }

        let template = WallpaperMetadata.movie
        let templateMoov = try boxes(template, from: 0, to: template.count).first { $0.type == "moov" }
        guard let templateMoov else { throw failure() }
        let metadataTracks = try children(template, templateMoov).filter { $0.type == "trak" }
        guard metadataTracks.count == 2 else { throw failure() }
        var payload = Data()
        var additions = Data()
        // Append a second mdat and a replacement moov. Original video offsets stay valid
        // whether the encoder wrote moov before or after its video mdat.
        let payloadStart = movie.count + 8
        for (index, track) in metadataTracks.enumerated() {
            var clone = Data(template[track.offset..<track.end])
            let box = try root(clone)
            let stbl = try descendant(clone, box, ["mdia", "minf", "stbl"])
            let stco = try child(clone, stbl, "stco")
            let stsz = try child(clone, stbl, "stsz")
            let sampleOffset = Int(try read(clone, at: stco.payload + 8, count: 4))
            let sampleSize = Int(try read(clone, at: stsz.payload + 4, count: 4))
            guard sampleSize > 0, sampleOffset >= 0, sampleOffset <= template.count - sampleSize else { throw failure() }
            let sample = Data(template[sampleOffset..<(sampleOffset + sampleSize)])
            let isInfo = index == 0
            let count = isInfo ? frames : 1
            let metadataScaleBox = try descendant(clone, box, ["mdia", "mdhd"])
            // Express both tracks in the output video's timebase, including
            // fractional source rates such as 29.97 fps.
            let metadataScale: UInt64 = 60000
            let scaleOffset = metadataScaleBox.payload + (clone[metadataScaleBox.payload] == 1 ? 20 : 12)
            try write(&clone, at: scaleOffset, value: metadataScale, count: 4)
            let sampleDuration: UInt64 = isInfo ? intervals[0] : 100
            let leading = isInfo ? UInt64(0) : UInt64((frameTimes[keyFrame] * Double(scale)).rounded())
            let presentationDuration = isInfo ? UInt64((duration * Double(scale)).rounded()) : max(1, scale / 600)
            let tkhd = try child(clone, box, "tkhd")
            let version = clone[tkhd.payload]
            try write(&clone, at: tkhd.payload + (version == 1 ? 20 : 12), value: maximumTrackID + UInt64(index) + 1, count: 4)
            try write(&clone, at: tkhd.payload + (version == 1 ? 28 : 20), value: leading + presentationDuration, count: version == 1 ? 8 : 4)
            let mediaVersion = clone[metadataScaleBox.payload]
            try write(&clone, at: metadataScaleBox.payload + (mediaVersion == 1 ? 24 : 16), value: isInfo ? ticks.last! : sampleDuration, count: mediaVersion == 1 ? 8 : 4)
            let stts = try child(clone, stbl, "stts")
            let stsc = try child(clone, stbl, "stsc")
            guard try read(clone, at: stts.payload + 4, count: 4) == 1,
                  try read(clone, at: stsc.payload + 4, count: 4) == 1,
                  try read(clone, at: stco.payload + 4, count: 4) == 1 else { throw failure() }
            try write(&clone, at: stts.payload + 8, value: UInt64(count), count: 4)
            try write(&clone, at: stts.payload + 12, value: sampleDuration, count: 4)
            try write(&clone, at: stsc.payload + 12, value: UInt64(count), count: 4)
            try write(&clone, at: stsz.payload + 8, value: UInt64(count), count: 4)
            try write(&clone, at: stco.payload + 8, value: UInt64(payloadStart + payload.count), count: 4)
            let elst = try descendant(clone, box, ["edts", "elst"])
            guard try read(clone, at: elst.payload + 4, count: 4) == 2 else { throw failure() }
            let editWidth = clone[elst.payload] == 1 ? 8 : 4
            try write(&clone, at: elst.payload + 8, value: leading, count: editWidth)
            try write(&clone, at: elst.payload + 8 + (editWidth == 8 ? 20 : 12), value: presentationDuration, count: editWidth)
            if isInfo {
                var entries: [(UInt64, UInt64)] = []
                for interval in intervals {
                    if entries.last?.1 == interval { entries[entries.count - 1].0 += 1 }
                    else { entries.append((1, interval)) }
                }
                var table = Data(count: 4)
                try appendInteger(&table, UInt64(entries.count), count: 4)
                for (count, delta) in entries {
                    try appendInteger(&table, count, count: 4)
                    try appendInteger(&table, delta, count: 4)
                }
                clone = try replacing(clone, path: ["mdia", "minf", "stbl", "stts"], with: atom("stts", payload: table))
            }
            var reference = Data()
            try appendInteger(&reference, videoID, count: 4)
            clone.append(try atom("tref", payload: atom("cdsc", payload: reference)))
            try write(&clone, at: 0, value: UInt64(clone.count), count: 4)
            additions.append(clone)
            for _ in 0..<count { payload.append(sample) }
        }
        moov.append(additions)
        try write(&moov, at: 0, value: UInt64(moov.count), count: 4)
        try write(&moov, at: movieHeader.end - 4, value: maximumTrackID + 3, count: 4)
        movie.replaceSubrange((originalMoov.offset + 4)..<(originalMoov.offset + 8), with: Data("free".utf8))
        movie.append(try atom("mdat", payload: payload))
        movie.append(moov)
        try movie.write(to: url, options: .atomic)
    }

    private static func replacing(_ data: Data, path: [String], with replacement: Data) throws -> Data {
        let container = try root(data)
        guard let first = path.first else { return replacement }
        let target = try child(data, container, first)
        let updated = try replacing(Data(data[target.offset..<target.end]), path: Array(path.dropFirst()), with: replacement)
        var result = data
        result.replaceSubrange(target.offset..<target.end, with: updated)
        try write(&result, at: 0, value: UInt64(result.count), count: 4)
        return result
    }

    private static func root(_ data: Data) throws -> Box {
        guard let box = try boxes(data, from: 0, to: data.count).first else { throw failure() }
        return box
    }

    private static func children(_ data: Data, _ box: Box) throws -> [Box] {
        try boxes(data, from: box.payload, to: box.end)
    }

    private static func child(_ data: Data, _ box: Box, _ type: String) throws -> Box {
        guard let result = try children(data, box).first(where: { $0.type == type }) else { throw failure() }
        return result
    }

    private static func descendant(_ data: Data, _ box: Box, _ path: [String]) throws -> Box {
        var result = box
        for type in path { result = try child(data, result, type) }
        return result
    }

    private static func boxes(_ data: Data, from start: Int, to end: Int) throws -> [Box] {
        guard start >= 0, end <= data.count, start <= end else { throw failure() }
        var offset = start
        var result: [Box] = []
        while offset < end {
            guard end - offset >= 8 else { throw failure() }
            let size32 = try read(data, at: offset, count: 4)
            let header = size32 == 1 ? 16 : 8
            let size = size32 == 1 ? try read(data, at: offset + 8, count: 8) : (size32 == 0 ? UInt64(end - offset) : size32)
            guard size >= header, size <= end - offset,
                  let type = String(data: data[(offset + 4)..<(offset + 8)], encoding: .ascii) else { throw failure() }
            result.append(Box(type: type, offset: offset, size: Int(size), header: header))
            offset += Int(size)
        }
        return result
    }

    private static func read(_ data: Data, at offset: Int, count: Int) throws -> UInt64 {
        guard offset >= 0, count <= 8, offset <= data.count - count else { throw failure() }
        return data[offset..<(offset + count)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

    private static func write(_ data: inout Data, at offset: Int, value: UInt64, count: Int) throws {
        guard offset >= 0, count <= 8, offset <= data.count - count,
              count == 8 || value < (UInt64(1) << (count * 8)) else { throw failure() }
        for index in 0..<count { data[offset + index] = UInt8(truncatingIfNeeded: value >> ((count - index - 1) * 8)) }
    }

    private static func appendInteger(_ data: inout Data, _ value: UInt64, count: Int) throws {
        let offset = data.count
        data.append(Data(count: count))
        try write(&data, at: offset, value: value, count: count)
    }

    private static func atom(_ type: String, payload: Data) throws -> Data {
        var result = Data()
        try appendInteger(&result, UInt64(payload.count + 8), count: 4)
        result.append(Data(type.utf8))
        result.append(payload)
        return result
    }

    private static func failure() -> LivePhotoMaker.Failure {
        .conversion("壁纸 MOV 结构或动态元数据不符合预期。")
    }
}
