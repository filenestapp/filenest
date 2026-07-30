import AppKit
import Foundation
import ImageIO
import PDFKit

enum PDFContentMode: String, Equatable, Sendable {
    case text
    case scanned
    case mixed
}

struct PDFContentAnalysis: Equatable, Sendable {
    struct Page: Equatable, Sendable {
        let number: Int
        let embeddedCharacterCount: Int
        var requiresOCR: Bool { embeddedCharacterCount < PDFContentAnalysis.minimumTextCharacters }
    }

    static let minimumTextCharacters = 24
    let pages: [Page]
    let mode: PDFContentMode

    var scannedPageNumbers: [Int] { pages.filter(\.requiresOCR).map(\.number) }
    var textRatio: Double {
        guard !pages.isEmpty else { return 0 }
        return Double(pages.filter { !$0.requiresOCR }.count) / Double(pages.count)
    }
    var scannedRatio: Double { 1 - textRatio }
}

/// Resizes images or scanned PDF pages before sending them to the configured OCR provider.
/// Skips OCR for text-based PDFs to avoid duplicate work and unnecessary model cost.
enum OCRDocumentProcessor {
    private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "tiff", "tif", "webp", "bmp"
    ]
    private static let maxPDFPages = 200
    private static let maxOCRCharacters = 60_000
    private static let overviewMaxPixelSize = 2_000
    private static let tilePixelSize = 2_048
    private static let tileOverlap = 288
    private static let maxTileCount = 32
    private static let largeImagePixelCount = 12_000_000
    private static let largeImageLongEdge = 4_000
    private static let panoramicAspectRatio = 3.0
    private static let failureCooldown: TimeInterval = 10 * 60
    private static let stateLock = NSLock()
    private static var failedUntil = [String: Date]()
    private static var providerFailedUntil = [String: Date]()
    private static let executionLane = AsyncPermitPool(limit: 1)

    struct ImagePlan {
        let usesTiling: Bool
        let processingScale: CGFloat
        let tileRects: [CGRect]
    }

    struct PositionedObservation {
        enum Source: Equatable {
            case overview
            case tile
        }

        let text: String
        let confidence: Double?
        let bounds: OCRBoundingBox
        let source: Source
    }

    private struct EncodedRegion {
        let data: Data
        let sourceRect: CGRect
        let pixelWidth: Int
        let pixelHeight: Int
        let source: PositionedObservation.Source
    }

    static func isRasterImage(extension ext: String) -> Bool {
        imageExtensions.contains(ext.lowercased())
    }

    static func requiresRecognition(ext: String, pdfAnalysis: PDFContentAnalysis?) -> Bool {
        let normalized = ext.lowercased()
        if imageExtensions.contains(normalized) { return true }
        return normalized == "pdf" && pdfAnalysis?.mode != .text
    }

    static func imagePlan(width: Int, height: Int) -> ImagePlan {
        guard width > 0, height > 0 else {
            return ImagePlan(usesTiling: false, processingScale: 1, tileRects: [])
        }
        let pixelCount = width.multipliedReportingOverflow(by: height)
        let aspectRatio = Double(max(width, height)) / Double(min(width, height))
        let usesTiling = pixelCount.overflow || pixelCount.partialValue > largeImagePixelCount
            || max(width, height) > largeImageLongEdge
            || aspectRatio > panoramicAspectRatio
        guard usesTiling else {
            return ImagePlan(usesTiling: false, processingScale: 1, tileRects: [])
        }

        var scale: CGFloat = 1
        var scaledWidth = max(1, Int((CGFloat(width) * scale).rounded(.up)))
        var scaledHeight = max(1, Int((CGFloat(height) * scale).rounded(.up)))
        var tileCount = gridTileCount(width: scaledWidth, height: scaledHeight)
        while tileCount > maxTileCount {
            let reduction = sqrt(CGFloat(maxTileCount) / CGFloat(tileCount)) * 0.98
            scale *= min(0.95, reduction)
            scaledWidth = max(1, Int((CGFloat(width) * scale).rounded(.up)))
            scaledHeight = max(1, Int((CGFloat(height) * scale).rounded(.up)))
            tileCount = gridTileCount(width: scaledWidth, height: scaledHeight)
        }

        let xPositions = tilePositions(length: scaledWidth)
        let yPositions = tilePositions(length: scaledHeight)
        let tileRects = yPositions.flatMap { scaledY in
            xPositions.map { scaledX in
                let scaledRect = CGRect(
                    x: CGFloat(scaledX),
                    y: CGFloat(scaledY),
                    width: CGFloat(min(tilePixelSize, scaledWidth - scaledX)),
                    height: CGFloat(min(tilePixelSize, scaledHeight - scaledY))
                )
                return CGRect(
                    x: scaledRect.minX / scale,
                    y: scaledRect.minY / scale,
                    width: scaledRect.width / scale,
                    height: scaledRect.height / scale
                ).intersection(CGRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(width),
                    height: CGFloat(height)
                ))
            }
        }
        return ImagePlan(usesTiling: true, processingScale: scale, tileRects: tileRects)
    }

    private static func gridTileCount(width: Int, height: Int) -> Int {
        tilePositions(length: width).count * tilePositions(length: height).count
    }

    private static func tilePositions(length: Int) -> [Int] {
        guard length > tilePixelSize else { return [0] }
        let stride = tilePixelSize - tileOverlap
        var positions = Array(Swift.stride(
            from: 0,
            through: max(0, length - tilePixelSize),
            by: stride
        ))
        let finalPosition = length - tilePixelSize
        if positions.last != finalPosition { positions.append(finalPosition) }
        return positions
    }

    static func recognizeIfNeeded(
        url: URL,
        ext: String,
        provider: OCRProvider?,
        forceImageOCR _: Bool = false,
        checkpoint: (@Sendable () async -> Bool)? = nil
    ) async -> String? {
        guard let provider else { return nil }
        guard !isCoolingDown(url: url, provider: provider) else {
            AppLogService.shared.write(
                "OCR skipped while this processing route is in failure cooldown",
                category: .indexExtraction,
                level: .warning,
                metadata: ["file": url.lastPathComponent, "provider": provider.name]
            )
            return nil
        }
        let normalizedExtension = ext.lowercased()

        if imageExtensions.contains(normalizedExtension) {
            // Raster images always go through the configured OCR provider. A Vision fast-mode
            // preflight used to suppress OCR for stylized, curved, or low-contrast text (for
            // example company seals), which left the index with metadata only.
            guard await checkpoint?() ?? !Task.isCancelled else { return nil }
            return await recognizeRasterImage(
                at: url,
                provider: provider,
                checkpoint: checkpoint
            )
        }

        guard normalizedExtension == "pdf", let document = PDFDocument(url: url),
              let analysis = analyze(document), analysis.mode != .text else { return nil }

        var pages = [String]()
        for pageNumber in analysis.scannedPageNumbers.prefix(maxPDFPages) {
            guard await checkpoint?() ?? !Task.isCancelled else { return nil }
            guard let page = document.page(at: pageNumber - 1),
                  let data = jpegData(from: page.thumbnail(
                    of: CGSize(width: 1_600, height: 2_200),
                    for: .mediaBox
                  )),
                  let text = await recognize(data: data, provider: provider, url: url),
                  !text.isEmpty else { continue }
            pages.append("[Page \(pageNumber)]\n\(text)")
            if pages.reduce(0, { $0 + $1.count }) >= maxOCRCharacters { break }
        }
        let result = String(pages.joined(separator: "\n\n").prefix(maxOCRCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func recognizeRasterImage(
        at url: URL,
        provider: OCRProvider,
        checkpoint: (@Sendable () async -> Bool)?
    ) async -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: max(
                    sourceWidth.intValue,
                    sourceHeight.intValue
                ),
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary) else { return nil }

        let plan = imagePlan(width: image.width, height: image.height)
        guard plan.usesTiling else {
            guard let normalizedImage = resizedImage(
                image,
                maximumPixelSize: overviewMaxPixelSize
            ), let data = pngData(from: normalizedImage) else { return nil }
            return await recognize(
                data: data,
                mimeType: "image/png",
                provider: provider,
                url: url
            )
        }

        AppLogService.shared.write(
            "large image OCR plan created",
            category: .indexExtraction,
            metadata: [
                "file": url.lastPathComponent,
                "dimensions": "\(image.width)x\(image.height)",
                "scale": String(format: "%.3f", Double(plan.processingScale)),
                "tiles": "\(plan.tileRects.count)",
            ]
        )

        await executionLane.acquire()
        defer { Task { await executionLane.release() } }
        do {
            var observations = [PositionedObservation]()
            if let overview = encodedOverview(from: image) {
                let result = try await provider.recognizeResult(
                    imageData: overview.data,
                    mimeType: "image/png"
                )
                observations.append(contentsOf: positionedObservations(
                    from: result,
                    region: overview
                ))
            }

            var processedTiles = 0
            for tileRect in plan.tileRects {
                guard await checkpoint?() ?? !Task.isCancelled else { return nil }
                guard let region = encodedTile(
                    from: image,
                    sourceRect: tileRect,
                    processingScale: plan.processingScale
                ) else { continue }
                let result = try await provider.recognizeResult(
                    imageData: region.data,
                    mimeType: "image/png"
                )
                observations.append(contentsOf: positionedObservations(
                    from: result,
                    region: region
                ))
                processedTiles += 1
            }

            let text = String(mergedText(from: observations).prefix(maxOCRCharacters))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            clearFailure(url: url, provider: provider)
            AppLogService.shared.write(
                "large image OCR completed",
                category: .indexExtraction,
                metadata: [
                    "characters": "\(text.count)",
                    "file": url.lastPathComponent,
                    "observations": "\(observations.count)",
                    "processedTiles": "\(processedTiles)",
                ]
            )
            return text.isEmpty ? nil : text
        } catch {
            recordFailure(url: url, provider: provider)
            AppLogService.shared.write(
                "large image OCR failed: \(error.localizedDescription)",
                category: .indexExtraction,
                level: .warning,
                metadata: ["file": url.lastPathComponent, "provider": provider.name]
            )
            return nil
        }
    }

    static func mergedText(from observations: [PositionedObservation]) -> String {
        let ranked = observations.sorted { lhs, rhs in
            if lhs.source != rhs.source { return lhs.source == .tile }
            return (lhs.confidence ?? 0) > (rhs.confidence ?? 0)
        }
        var selected = [PositionedObservation]()
        for candidate in ranked {
            let duplicate = selected.contains { existing in
                let overlap = overlapRatio(candidate.bounds, existing.bounds)
                return overlap >= 0.25 && (
                    candidate.source == .overview && existing.source == .tile
                        || textsAreDuplicates(candidate.text, existing.text)
                )
            }
            if !duplicate, !isIsolatedASCIIFragment(candidate.text) {
                selected.append(candidate)
            }
        }
        return selected.sorted { lhs, rhs in
            if abs(lhs.bounds.minY - rhs.bounds.minY) > 1 {
                return lhs.bounds.minY < rhs.bounds.minY
            }
            return lhs.bounds.minX < rhs.bounds.minX
        }.map(\.text).joined(separator: "\n")
    }

    private static func positionedObservations(
        from result: OCRRecognitionResult,
        region: EncodedRegion
    ) -> [PositionedObservation] {
        let sourceObservations = result.observations.isEmpty
            ? [OCRTextObservation(text: result.text, confidence: nil, bounds: nil)]
            : result.observations
        var positioned = [PositionedObservation]()
        for observation in sourceObservations {
            let lines = observation.bounds == nil
                ? observation.text.split(whereSeparator: \.isNewline).map(String.init)
                : [observation.text]
            guard !lines.isEmpty else { continue }
            for (lineIndex, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                let bounds: OCRBoundingBox
                if let localBounds = observation.bounds {
                    let scaleX = region.sourceRect.width / CGFloat(region.pixelWidth)
                    let scaleY = region.sourceRect.height / CGFloat(region.pixelHeight)
                    bounds = OCRBoundingBox(
                        x: Double(region.sourceRect.minX + CGFloat(localBounds.x) * scaleX),
                        y: Double(region.sourceRect.minY + CGFloat(localBounds.y) * scaleY),
                        width: Double(CGFloat(localBounds.width) * scaleX),
                        height: Double(CGFloat(localBounds.height) * scaleY)
                    )
                } else {
                    let lineHeight = region.sourceRect.height / CGFloat(lines.count)
                    bounds = OCRBoundingBox(
                        x: Double(region.sourceRect.minX),
                        y: Double(region.sourceRect.minY + CGFloat(lineIndex) * lineHeight),
                        width: Double(region.sourceRect.width),
                        height: Double(lineHeight)
                    )
                }
                positioned.append(PositionedObservation(
                    text: trimmed,
                    confidence: observation.confidence,
                    bounds: bounds,
                    source: region.source
                ))
            }
        }
        return positioned
    }

    private static func overlapRatio(_ lhs: OCRBoundingBox, _ rhs: OCRBoundingBox) -> Double {
        let width = max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
        let height = max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
        let intersection = width * height
        let minimumArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
        return minimumArea > 0 ? intersection / minimumArea : 0
    }

    private static func textSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let left = normalizedComparisonText(lhs)
        let right = normalizedComparisonText(rhs)
        guard !left.isEmpty, !right.isEmpty else { return 0 }
        if left == right { return 1 }
        let leftCharacters = Array(left)
        let rightCharacters = Array(right)
        var previous = Array(0...rightCharacters.count)
        for (leftIndex, leftCharacter) in leftCharacters.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in rightCharacters.enumerated() {
                current.append(Swift.min(
                    current[rightIndex] + 1,
                    Swift.min(
                        previous[rightIndex + 1] + 1,
                        previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                    )
                ))
            }
            previous = current
        }
        return 1 - Double(previous.last ?? 0) / Double(max(leftCharacters.count, rightCharacters.count))
    }

    private static func textsAreDuplicates(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedComparisonText(lhs)
        let right = normalizedComparisonText(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        if textSimilarity(left, right) >= 0.80 { return true }
        let shorter = left.count <= right.count ? left : right
        let longer = left.count <= right.count ? right : left
        return shorter.count >= 4
            && Double(shorter.count) / Double(longer.count) >= 0.35
            && longer.contains(shorter)
    }

    private static func isIsolatedASCIIFragment(_ text: String) -> Bool {
        let normalized = normalizedComparisonText(text)
        return normalized.count == 1 && normalized.unicodeScalars.allSatisfy(\.isASCII)
    }

    private static func normalizedComparisonText(_ text: String) -> String {
        text.lowercased().unicodeScalars.compactMap {
            CharacterSet.alphanumerics.contains($0) ? String($0) : nil
        }.joined()
    }

    private static func recognize(data: Data,
                                  mimeType: String = "image/jpeg",
                                  provider: OCRProvider,
                                  url: URL) async -> String? {
        await executionLane.acquire()
        defer { Task { await executionLane.release() } }
        do {
            let text = try await provider.recognizeResult(imageData: data, mimeType: mimeType)
                .text.trimmingCharacters(in: .whitespacesAndNewlines)
            clearFailure(url: url, provider: provider)
            return text.isEmpty ? nil : String(text.prefix(maxOCRCharacters))
        } catch {
            recordFailure(url: url, provider: provider)
            AppLogService.shared.write(
                "OCR request failed: \(error.localizedDescription)",
                category: .indexExtraction,
                level: .warning,
                metadata: ["file": url.lastPathComponent, "provider": provider.name]
            )
            return nil
        }
    }

    private static func isCoolingDown(url: URL, provider: OCRProvider) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let now = Date()
        let path = url.standardizedFileURL.path
        let providerScope = providerFailureScope(url: url, provider: provider)
        if let deadline = providerFailedUntil[providerScope] {
            if deadline > now { return true }
            providerFailedUntil.removeValue(forKey: providerScope)
        }
        if let deadline = failedUntil[path] {
            if deadline > now { return true }
            failedUntil.removeValue(forKey: path)
        }
        return false
    }

    private static func recordFailure(url: URL, provider: OCRProvider) {
        stateLock.lock()
        let deadline = Date().addingTimeInterval(failureCooldown)
        failedUntil[url.standardizedFileURL.path] = deadline
        providerFailedUntil[providerFailureScope(url: url, provider: provider)] = deadline
        stateLock.unlock()
    }

    private static func clearFailure(url: URL, provider: OCRProvider) {
        stateLock.lock()
        failedUntil.removeValue(forKey: url.standardizedFileURL.path)
        providerFailedUntil.removeValue(
            forKey: providerFailureScope(url: url, provider: provider)
        )
        stateLock.unlock()
    }

    /// A timeout caused by a very large raster image must not disable OCR for scanned PDFs.
    /// Keep provider circuit breakers isolated by the materially different processing routes.
    private static func providerFailureScope(url: URL, provider: OCRProvider) -> String {
        let route = url.pathExtension.lowercased() == "pdf" ? "pdf" : "image"
        return "\(provider.name)|\(route)"
    }

    static func analyzePDF(at url: URL) -> PDFContentAnalysis? {
        guard let document = PDFDocument(url: url) else { return nil }
        return analyze(document)
    }

    static func analyze(_ document: PDFDocument) -> PDFContentAnalysis? {
        guard document.pageCount > 0 else { return nil }
        let pages = (0..<document.pageCount).map { index in
            PDFContentAnalysis.Page(
                number: index + 1,
                embeddedCharacterCount: document.page(at: index)?.string?
                    .trimmingCharacters(in: .whitespacesAndNewlines).count ?? 0
            )
        }
        return classify(pages)
    }

    static func classify(_ pages: [PDFContentAnalysis.Page]) -> PDFContentAnalysis? {
        guard !pages.isEmpty else { return nil }
        let textPages = pages.filter { !$0.requiresOCR }.count
        let textRatio = Double(textPages) / Double(pages.count)
        let scannedRatio = 1 - textRatio
        let mode: PDFContentMode
        if textRatio >= 0.8 {
            mode = .text
        } else if scannedRatio >= 0.8 {
            mode = .scanned
        } else {
            mode = .mixed
        }
        return PDFContentAnalysis(pages: pages, mode: mode)
    }

    static func isScanned(_ document: PDFDocument) -> Bool {
        analyze(document)?.mode == .scanned
    }

    private static func encodedOverview(from image: CGImage) -> EncodedRegion? {
        guard let overview = resizedImage(image, maximumPixelSize: overviewMaxPixelSize),
              let data = pngData(from: overview) else { return nil }
        return EncodedRegion(
            data: data,
            sourceRect: CGRect(
                x: 0,
                y: 0,
                width: CGFloat(image.width),
                height: CGFloat(image.height)
            ),
            pixelWidth: overview.width,
            pixelHeight: overview.height,
            source: .overview
        )
    }

    private static func encodedTile(from image: CGImage,
                                    sourceRect: CGRect,
                                    processingScale: CGFloat) -> EncodedRegion? {
        let imageBounds = CGRect(
            x: 0,
            y: 0,
            width: CGFloat(image.width),
            height: CGFloat(image.height)
        )
        let cropRect = CGRect(
            x: floor(sourceRect.minX),
            y: floor(sourceRect.minY),
            width: ceil(sourceRect.width),
            height: ceil(sourceRect.height)
        ).intersection(imageBounds)
        guard !cropRect.isEmpty, let cropped = image.cropping(to: cropRect) else { return nil }
        let targetWidth = max(1, Int((cropRect.width * processingScale).rounded()))
        let targetHeight = max(1, Int((cropRect.height * processingScale).rounded()))
        guard let tile = resizedImage(cropped, width: targetWidth, height: targetHeight),
              containsVisualContent(tile),
              let data = pngData(from: tile) else { return nil }
        return EncodedRegion(
            data: data,
            sourceRect: cropRect,
            pixelWidth: tile.width,
            pixelHeight: tile.height,
            source: .tile
        )
    }

    private static func resizedImage(_ image: CGImage,
                                     maximumPixelSize: Int) -> CGImage? {
        let longestEdge = max(image.width, image.height)
        guard longestEdge > maximumPixelSize else { return image }
        let scale = CGFloat(maximumPixelSize) / CGFloat(longestEdge)
        return resizedImage(
            image,
            width: max(1, Int((CGFloat(image.width) * scale).rounded())),
            height: max(1, Int((CGFloat(image.height) * scale).rounded()))
        )
    }

    private static func resizedImage(_ image: CGImage,
                                     width: Int,
                                     height: Int) -> CGImage? {
        guard width != image.width || height != image.height else { return image }
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
            x: 0,
            y: 0,
            width: CGFloat(width),
            height: CGFloat(height)
        ))
        return context.makeImage()
    }

    private static func containsVisualContent(_ image: CGImage) -> Bool {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let background = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB) else {
            return true
        }
        var backgroundRed: CGFloat = 0
        var backgroundGreen: CGFloat = 0
        var backgroundBlue: CGFloat = 0
        var backgroundAlpha: CGFloat = 0
        background.getRed(
            &backgroundRed,
            green: &backgroundGreen,
            blue: &backgroundBlue,
            alpha: &backgroundAlpha
        )
        let xStep = max(1, image.width / 128)
        let yStep = max(1, image.height / 128)
        var differingSamples = 0
        for y in Swift.stride(from: 0, to: image.height, by: yStep) {
            for x in Swift.stride(from: 0, to: image.width, by: xStep) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    return true
                }
                let difference = [
                    abs(color.redComponent - backgroundRed),
                    abs(color.greenComponent - backgroundGreen),
                    abs(color.blueComponent - backgroundBlue),
                    abs(color.alphaComponent - backgroundAlpha)
                ].max() ?? 0
                if difference > 0.08 {
                    differingSamples += 1
                    if differingSamples >= 3 { return true }
                }
            }
        }
        return false
    }

    private static func pngData(from image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    private static func jpegData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }
}

private actor AsyncPermitPool {
    private var permits: Int
    private var waiters = [CheckedContinuation<Void, Never>]()

    init(limit: Int) { permits = max(1, limit) }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
