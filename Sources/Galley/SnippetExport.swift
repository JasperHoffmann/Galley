// SnippetExport.swift
// A rectangular selection, already cropped to a one-page PDF by GalleyPDFView, as vector SVG and
// as an Excalidraw clipboard payload that carries a link back to its source.
//
// PDF -> SVG is delegated to Poppler's `pdftocairo` (Homebrew: `brew install poppler`), run as a
// separate program: the same conversion Inkscape uses, glyphs as outlines, so the snippet needs
// no fonts. Converting the cropped page keeps the SVG to the selection's size. Poppler is GPL;
// calling it as an external program keeps it out of Galley's own code.

import AppKit
import Foundation

enum SnippetExport {
    enum Failure: LocalizedError {
        case converterMissing
        case conversionFailed(String)

        var errorDescription: String? {
            switch self {
            case .converterMissing:
                return "pdftocairo was not found. Install Poppler with `brew install poppler`."
            case .conversionFailed(let detail):
                return "Converting the selection to SVG failed: \(detail)"
            }
        }
    }

    /// Where `pdftocairo` is: Homebrew's prefixes first, then the PATH Galley was started with.
    static func pdftocairoPath() -> String? {
        var candidates = ["/opt/homebrew/bin/pdftocairo", "/usr/local/bin/pdftocairo"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/pdftocairo" }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The cropped one-page PDF as SVG. Blocking; call it off the main thread.
    static func svg(fromPDF pdf: Data) throws -> Data {
        guard let tool = pdftocairoPath() else { throw Failure.converterMissing }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("galley-snippet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let input = dir.appendingPathComponent("snippet.pdf")
        let output = dir.appendingPathComponent("snippet.svg")
        try pdf.write(to: input)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-svg", input.path, output.path]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors  // Poppler warns about links that point off the snippet
        try process.run()
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let svg = try? Data(contentsOf: output) else {
            let detail = String(decoding: stderr, as: UTF8.self)
                .split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)"
            throw Failure.conversionFailed(detail)
        }
        return svg
    }

    /// `galleypdf://open?...` for the page the snippet came from: `rel=` relative to the papers
    /// root when the PDF lies under it (short, private, survives moves), `pdfpath=` otherwise.
    /// The rectangle, in PDF points from the page's lower left, rides along for a viewer that can
    /// centre on it; the arXiv ID or DOI for finding the paper anywhere else.
    static func sourceLink(pdf: URL, page: Int, rect: NSRect, info: PaperInfo) -> String {
        var components = URLComponents()
        components.scheme = "galleypdf"
        components.host = "open"
        let r = [rect.minX, rect.minY, rect.width, rect.height].map { String(format: "%.1f", $0) }
        let location = PaperLinks.relativePath(of: pdf).map { URLQueryItem(name: "rel", value: $0) }
            ?? URLQueryItem(name: "pdfpath", value: pdf.path)
        components.queryItems = [
            location,
            URLQueryItem(name: "page", value: String(page)),
            URLQueryItem(name: "rect", value: r.joined(separator: ",")),
        ]
        if let arxiv = info.arxiv { components.queryItems?.append(URLQueryItem(name: "arxiv", value: arxiv)) }
        if let doi = info.doi { components.queryItems?.append(URLQueryItem(name: "doi", value: doi)) }
        // URLComponents leaves "/" and "@" unescaped in queries; Excalidraw and LaunchServices
        // both accept that, so the link stays readable.
        return components.string ?? "galleypdf://open"
    }

    /// A caption under the snippet: its text, and a public link anyone can open.
    struct Caption {
        var text: String
        var link: String
    }

    /// Excalidraw's own clipboard format: one image element holding the SVG, its `link` set to
    /// the source, and optionally a small caption below it with a public link. The two are not
    /// grouped: a click on the snippet selects it alone, so its link is one click away. Pasted as
    /// text into Excalidraw it becomes those elements; elsewhere it is JSON.
    static func excalidrawClipboard(svg: Data, size: CGSize, link: String?, caption: Caption?) -> String {
        let fileId = "galley-" + UUID().uuidString.lowercased()
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let scale = 2.0  // PDF points to canvas pixels: readable at Excalidraw's 100 %
        let group = [String]()

        func base(_ type: String, x: Double, y: Double, width: Double, height: Double,
                  link: String?) -> [String: Any] {
            [
                "type": type, "id": UUID().uuidString.lowercased(),
                "x": x, "y": y, "width": width, "height": height, "angle": 0,
                "strokeColor": "transparent", "backgroundColor": "transparent",
                "fillStyle": "solid", "strokeWidth": 1, "strokeStyle": "solid", "roughness": 0,
                "opacity": 100, "groupIds": group, "frameId": NSNull(), "roundness": NSNull(),
                "seed": Int.random(in: 1..<Int(Int32.max)), "version": 1,
                "versionNonce": Int.random(in: 1..<Int(Int32.max)), "isDeleted": false,
                "boundElements": NSNull(), "updated": now,
                "link": link.map { $0 as Any } ?? NSNull(), "locked": false,
            ]
        }

        let width = size.width * scale, height = size.height * scale
        var image = base("image", x: 0, y: 0, width: width, height: height, link: link)
        image.merge(["fileId": fileId, "status": "saved", "scale": [1, 1]]) { $1 }
        var elements: [[String: Any]] = [image]

        if let caption {
            let fontSize = 14.0
            var text = base("text", x: 0, y: height + 6,
                            width: Double(caption.text.count) * fontSize * 0.55,
                            height: fontSize * 1.25, link: caption.link)
            text.merge([
                "strokeColor": "#868e96", "text": caption.text, "originalText": caption.text,
                "fontSize": fontSize, "fontFamily": 2, "textAlign": "left",
                "verticalAlign": "top", "containerId": NSNull(), "autoResize": true,
                "lineHeight": 1.25,
            ]) { $1 }
            elements.append(text)
        }

        let file: [String: Any] = [
            "id": fileId, "mimeType": "image/svg+xml", "created": now,
            "dataURL": "data:image/svg+xml;base64," + svg.base64EncodedString(),
        ]
        let payload: [String: Any] = [
            "type": "excalidraw/clipboard", "elements": elements, "files": [fileId: file],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
