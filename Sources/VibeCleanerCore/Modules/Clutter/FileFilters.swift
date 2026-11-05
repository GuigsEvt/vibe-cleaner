import Foundation
import UniformTypeIdentifiers

/// File families of the "par type" filters.
enum FileKind: String, CaseIterable, Sendable {
    case applications, archives, audio, documents, pictures, videos, other

    var title: String {
        switch self {
        case .applications: "Applications"
        case .archives: "Archives"
        case .audio: "Audio"
        case .documents: "Documents"
        case .pictures: "Images"
        case .videos: "Vidéos"
        case .other: "Autres"
        }
    }

    var symbol: String {
        switch self {
        case .applications: "app"
        case .archives: "archivebox"
        case .audio: "music.note"
        case .documents: "doc.text"
        case .pictures: "photo"
        case .videos: "film"
        case .other: "doc"
        }
    }

    init(_ type: UTType?) {
        guard let t = type else { self = .other; return }
        if t.conforms(to: .image) { self = .pictures }
        else if t.conforms(to: .movie) || t.conforms(to: .video) { self = .videos }
        else if t.conforms(to: .audio) { self = .audio }
        else if t.conforms(to: .archive) || t.conforms(to: .diskImage) || t.identifier == "com.apple.installer-package-archive" { self = .archives }
        else if t.conforms(to: .application) || t.conforms(to: .applicationBundle) { self = .applications }
        else if [UTType.pdf, .text, .spreadsheet, .presentation, .compositeContent, .rtfd].contains(where: t.conforms(to:))
                    || t.identifier.hasPrefix("com.apple.iwork.") { self = .documents }
        else { self = .other }
    }

    /// From the file name only: no disk access.
    init(url: URL) {
        self.init(UTType(filenameExtension: url.pathExtension.lowercased()))
    }
}

/// Filters of the Manager: last access, size and kind, as groups of the same items.
enum FileFilters {
    enum Filter { case access, size, kind }

    static let day: TimeInterval = 86_400

    /// Disjoint access buckets: under a week, a week to a month, a month to six months, six months to a year, over a year.
    static func accessBucket(_ date: Date?, now: Date) -> (order: Int, title: String) {
        guard let date else { return (5, "Date d'ouverture inconnue") }
        let age = now.timeIntervalSince(date)
        if age < 7 * day { return (0, "Ouverts la semaine dernière") }
        if age < 30 * day { return (1, "Ouverts il y a plus d'une semaine") }
        if age < 182 * day { return (2, "Ouverts il y a plus d'un mois") }
        if age < 365 * day { return (3, "Ouverts il y a plus de six mois") }
        return (4, "Ouverts il y a plus d'un an")
    }

    /// Small 50–250 MB, average 250 MB–1 GB, huge from 1 GB.
    static func sizeBucket(_ bytes: Int64) -> (order: Int, title: String) {
        if bytes >= 1_000_000_000 { return (2, "Énormes (plus de 1 Go)") }
        if bytes >= 250_000_000 { return (1, "Moyens (250 Mo à 1 Go)") }
        return (0, "Petits (moins de 250 Mo)")
    }

    /// One group per bucket under `id`; items keep their ids, so selecting here selects everywhere.
    static func group(_ items: [ResultItem], by filter: Filter, id: String, title: String, subtitle: String? = nil,
                      now: Date) -> ResultGroup {
        var buckets: [String: (order: Int, title: String, symbol: String, items: [ResultItem])] = [:]
        for item in items {
            let key: String, b: (order: Int, title: String), symbol: String
            switch filter {
            case .access:
                b = accessBucket(item.date, now: now); key = "\(b.order)"; symbol = "calendar"
            case .size:
                b = sizeBucket(item.size); key = "\(b.order)"; symbol = "externaldrive"
            case .kind:
                let k = item.url.map(FileKind.init(url:)) ?? .other
                b = (FileKind.allCases.firstIndex(of: k) ?? 0, k.title); key = k.rawValue; symbol = k.symbol
            }
            buckets[key, default: (b.order, b.title, symbol, [])].items.append(item)
        }
        let groups = buckets.sorted { $0.value.order < $1.value.order }.map { key, b in
            ResultGroup(id: "\(id).\(key)", title: b.title, symbol: b.symbol, items: b.items.sorted { $0.size > $1.size }, autoSelect: false)
        }
        let symbol = filter == .access ? "calendar" : filter == .size ? "externaldrive" : "square.grid.3x3"
        return ResultGroup(id: id, title: title, subtitle: subtitle, symbol: symbol, groups: groups, autoSelect: false)
    }
}
