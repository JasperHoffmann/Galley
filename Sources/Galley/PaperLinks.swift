// PaperLinks.swift
// Links to papers that survive moving the PDF: paths relative to one papers root, healed by
// Spotlight when the file has moved, and public IDs (arXiv, DOI) read from the paper itself.
//
// Resolving `rel=` takes, in order: root + rel, the location remembered from an earlier search,
// a Spotlight search for the file name under the root. Only when that finds none or several does
// the caller ask the user. Spotlight answers from its index; it never walks the folders.

import AppKit
import PDFKit

enum PaperLinks {
    static let rootKey = "papersRoot"
    static let movesKey = "papersRootMoves"  // rel -> absolute path where it was found last

    enum Resolution: Sendable {
        case found(URL, moved: Bool)
        case ambiguous([URL])
        case missing
    }

    /// The folder papers live under, set by File > Set Papers Root…; nil until set.
    static var root: URL? {
        guard let path = UserDefaults.standard.string(forKey: rootKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// `url` relative to the papers root, or nil when there is no root or it lies outside.
    static func relativePath(of url: URL) -> String? {
        guard let root else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// Where the paper at `rel` is now. Blocking (Spotlight): call it off the main thread.
    static func resolve(rel: String) -> Resolution {
        guard let root else { return .missing }
        let direct = root.appendingPathComponent(rel)
        if exists(direct) { return .found(direct, moved: false) }
        if let moved = (UserDefaults.standard.dictionary(forKey: movesKey) as? [String: String])?[rel],
           exists(URL(fileURLWithPath: moved)) {
            return .found(URL(fileURLWithPath: moved), moved: false)
        }
        let hits = spotlight(fileName: (rel as NSString).lastPathComponent, under: root)
        switch hits.count {
        case 0: return .missing
        case 1:
            remember(rel: rel, at: hits[0])
            return .found(hits[0], moved: true)
        default: return .ambiguous(hits)
        }
    }

    /// Remember that the paper linked as `rel` is now at `url`, so the next click goes straight there.
    static func remember(rel: String, at url: URL) {
        var moves = UserDefaults.standard.dictionary(forKey: movesKey) as? [String: String] ?? [:]
        moves[rel] = url.path
        UserDefaults.standard.set(moves, forKey: movesKey)
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)  // true for cloud-only files too
    }

    /// Files named exactly `fileName` anywhere under `root`, by Spotlight's index.
    private static func spotlight(fileName: String, under root: URL) -> [URL] {
        let escaped = fileName.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", root.path, "kMDItemFSName == \"\(escaped)\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
            .filter { exists($0) }
    }
}

/// What identifies a paper beyond its path: its arXiv ID or DOI, and a title for captions.
struct PaperInfo {
    var arxiv: String?
    var doi: String?
    var title: String?

    /// From the file name and the text of the first page, where arXiv stamps its ID and journals
    /// print their DOI.
    init(document: PDFDocument?, url: URL?) {
        let name = url?.deletingPathExtension().lastPathComponent ?? ""
        let firstPage = document?.page(at: 0)?.string ?? ""
        arxiv = Self.firstMatch(#"^(\d{4}\.\d{4,5}(?:v\d+)?)$"#, in: name)
            ?? Self.firstMatch(#"arXiv:\s*(\d{4}\.\d{4,5}(?:v\d+)?)"#, in: firstPage)
        doi = arxiv == nil
            ? Self.firstMatch(#"(10\.\d{4,9}/[^\s"<>]+)"#, in: firstPage)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;)")) }
            : nil
        let attributeTitle = document?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        title = attributeTitle.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    /// The public page of the paper, opened at `page` where the address allows it.
    func publicLink(page: Int) -> String? {
        if let arxiv { return "https://arxiv.org/pdf/\(arxiv)#page=\(page)" }
        if let doi { return "https://doi.org/\(doi)" }
        return nil
    }

    /// "[Title · arXiv:2403.07815v3 · p. 6]", the title shortened and left out when the PDF has
    /// none (the file name would only repeat the ID); nil without a public ID.
    func caption(page: Int) -> String? {
        guard let id = arxiv.map({ "arXiv:\($0)" }) ?? doi.map({ "doi:\($0)" }) else { return nil }
        guard var name = title else { return "[\(id) · p. \(page)]" }
        if name.count > 70 { name = String(name.prefix(67)) + "…" }
        return "[\(name) · \(id) · p. \(page)]"
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
