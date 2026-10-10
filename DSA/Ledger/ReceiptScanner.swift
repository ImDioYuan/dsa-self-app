import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 小票识别：缩小图片 → Worker /receipt（Claude 读图）→ 记一笔的预填内容
enum ReceiptScanner {
    enum ScanError: LocalizedError {
        case unreadableImage
        case notReceipt

        var errorDescription: String? {
            switch self {
            case .unreadableImage: "图片读取失败"
            case .notReceipt: "这张图片看起来不是小票，可以手动记一笔"
            }
        }
    }

    /// - Parameters:
    ///   - imageData: 原图（JPEG / HEIC / PNG 都可以）
    ///   - categories: 可选的支出分类
    static func scan(_ imageData: Data, categories: [DSAClient.CategoryRef]) async throws -> EntryDraft {
        guard let jpeg = downscaledJPEG(imageData) else { throw ScanError.unreadableImage }
        let client = try DSAClient.fromSettings()
        let result = try await client.receipt(jpeg: jpeg, categories: categories, currencyHint: LedgerSettings.lastCurrency)
        guard result.isReceipt else { throw ScanError.notReceipt }

        var draft = EntryDraft(source: .receipt, receiptImage: jpeg)
        draft.merchant = result.merchant
        draft.note = result.note
        draft.categoryID = result.categoryId
        draft.currency = Currency(rawValue: result.currency) ?? LedgerSettings.lastCurrency
        if let total = result.total, total > 0 {
            // 按币种的小数位四舍五入，避免 12.499999 这种浮点误差
            let digits = (draft.currency ?? .base).fractionDigits
            draft.amount = Decimal(string: String(format: "%.\(digits)f", total))
        }
        if let raw = result.date, let date = parseDate(raw) { draft.date = date }
        return draft
    }

    /// "2026-10-02T13:45" / "2026-10-02"。只有日期时：今天用当前时间，其他日子用中午 12 点
    static func parseDate(_ raw: String, now: Date = .now, calendar: Calendar = .current) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = calendar.timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = format
            if let date = f.date(from: raw) { return date }
        }
        f.dateFormat = "yyyy-MM-dd"
        guard let day = f.date(from: raw) else { return nil }
        if calendar.isDate(day, inSameDayAs: now) { return now }
        // 未来的日期多半是读错了，忽略
        guard day < now else { return nil }
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)
    }

    /// 缩到长边 1280px、JPEG 质量 0.7（Claude 读小票足够，一张约 150–300 KB）
    static func downscaledJPEG(_ data: Data, maxPixel: Int = 1280) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
