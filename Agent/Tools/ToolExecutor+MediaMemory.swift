import Foundation

/// Configuration for the local media-memory footage service.
/// Mirrors mcp_server.py's MEDIA_MEMORY_URL (default http://127.0.0.1:8000/search).
/// The IP literal (not "localhost") keeps the cleartext call out of App Transport Security.
enum MediaMemoryConfig {
    static var searchURL: URL {
        if let raw = ProcessInfo.processInfo.environment["MEDIA_MEMORY_URL"],
           let url = URL(string: raw) {
            return url
        }
        return URL(string: "http://127.0.0.1:8000/search")!
    }

    static let requestTimeout: TimeInterval = 30

    /// The media-memory tool directory (holds ingest.py and the .venv-core Python env).
    /// Defaults to a repo-relative path, which holds when the app is launched via
    /// `swift run` from the repo root. Override with MEDIA_MEMORY_DIR for a packaged app.
    static var directory: URL {
        if let raw = ProcessInfo.processInfo.environment["MEDIA_MEMORY_DIR"], !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("media-memory")
    }

    static var venvPython: URL { directory.appendingPathComponent(".venv-core/bin/python") }
    static var ingestScript: URL { directory.appendingPathComponent("ingest.py") }
}

extension ToolExecutor {
    private static let searchMediaMemoryAllowedKeys: Set<String> =
        ["query", "has_speech", "after", "before", "near_gps", "limit", "import"]

    func searchMediaMemory(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.searchMediaMemoryAllowedKeys, path: "search_media_memory")
        let query = try args.requireString("query").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw ToolError("search_media_memory: query is empty") }
        let limit = min(max(args.int("limit") ?? 8, 1), 50)
        let doImport = args.bool("import") ?? true

        var body: [String: Any] = ["query": query, "limit": limit]
        if let hasSpeech = args.bool("has_speech") { body["has_speech"] = hasSpeech }
        if let after = args.string("after") { body["after"] = after }
        if let before = args.string("before") { body["before"] = before }
        if let gps = args["near_gps"] as? [Any] {
            let coords = gps.compactMap { ($0 as? NSNumber)?.doubleValue ?? ($0 as? Double) }
            if coords.count == 2 { body["near_gps"] = coords }
        }

        let clips: [[String: Any]]
        do {
            clips = try await fetchMemoryClips(body: body)
        } catch let err as MediaMemoryError {
            return .error(err.message)
        }

        if clips.isEmpty {
            return .ok(Self.jsonString(["clips": [], "note": "No footage in your library matched that query."]) ?? "{}")
        }

        var results: [[String: Any]] = []
        var importedCount = 0
        for clip in clips.prefix(limit) {
            var entry: [String: Any] = [:]
            if let caption = clip.string("caption") { entry["caption"] = caption }
            if let duration = clip.double("duration") { entry["duration"] = duration }
            if let hasSpeech = clip.bool("has_speech") { entry["has_speech"] = hasSpeech }
            if let score = clip.double("score") { entry["score"] = score }
            if let tStart = clip.double("t_start") { entry["t_start"] = tStart }
            if let tEnd = clip.double("t_end") { entry["t_end"] = tEnd }
            if let source = clip.string("source_path") { entry["source_path"] = source }

            if doImport {
                guard let assetPath = clip.string("asset_path") else {
                    entry["importError"] = "clip has no asset_path"
                    results.append(entry)
                    continue
                }
                do {
                    let asset = try importLocalFile(
                        editor: editor,
                        fileURL: URL(fileURLWithPath: assetPath),
                        name: clip.string("caption").map { String($0.prefix(60)) },
                        folderId: nil
                    )
                    entry["mediaRef"] = asset.id
                    importedCount += 1
                } catch let err as ToolError {
                    entry["importError"] = err.message
                }
            }
            results.append(entry)
        }

        var payload: [String: Any] = ["clips": results]
        if doImport {
            payload["imported"] = importedCount
            payload["note"] = "Imported \(importedCount) clip(s) into the project. Each entry's mediaRef is ready for add_clips (durationFrames = round(duration * fps))."
        } else {
            payload["note"] = "Preview only — nothing imported. Re-call without import=false (or with import=true) to bring chosen clips into the project."
        }

        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(payload, toPlaces: 3)) else {
            throw ToolError("search_media_memory: failed to encode results")
        }
        return .ok(json)
    }

    private func fetchMemoryClips(body: [String: Any]) async throws -> [[String: Any]] {
        var request = URLRequest(url: MediaMemoryConfig.searchURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = MediaMemoryConfig.requestTimeout
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw MediaMemoryError(
                "The footage-memory service isn't reachable at \(MediaMemoryConfig.searchURL.absoluteString). "
                + "Start it with `uvicorn serve:app --port 8000` (and make sure Redis is running), then try again."
            )
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw MediaMemoryError("The footage-memory service returned HTTP \(http.statusCode).")
        }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let clips = obj["clips"] as? [[String: Any]]
        else {
            throw MediaMemoryError("The footage-memory service returned an unexpected response.")
        }
        return clips
    }
}

private struct MediaMemoryError: Error { let message: String; init(_ m: String) { self.message = m } }
