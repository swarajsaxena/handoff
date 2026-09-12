import Foundation

/// Reads past Claude Code sessions from disk — specifically from
/// ~/.claude/projects/*/*.jsonl (one file per session, filename = session_id,
/// mtime = last activity). Does NOT touch SessionStore; just returns plain
/// values for the caller to publish.
///
/// ponytail: bounded 12×~16KB scan per call; no caching until measurably needed.
enum SessionHistoryReader {

  static func load(limit: Int = 12) async -> [PastSession] {
    let fm = FileManager.default
    let projectsURL = fm.homeDirectoryForCurrentUser
      .appending(path: ".claude/projects")

    guard
      let projectDirs = try? fm.contentsOfDirectory(
        at: projectsURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: .skipsHiddenFiles
      )
    else { return [] }

    // Collect all .jsonl files with their mtimes across every project dir
    var files: [(url: URL, mtime: Date)] = []
    for dir in projectDirs {
      let isDir = (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
      guard isDir else { continue }
      guard
        let children = try? fm.contentsOfDirectory(
          at: dir,
          includingPropertiesForKeys: [.contentModificationDateKey],
          options: .skipsHiddenFiles
        )
      else { continue }
      for file in children where file.pathExtension == "jsonl" {
        let mtime =
          (try? file.resourceValues(forKeys: [.contentModificationDateKey]))
          .flatMap(\.contentModificationDate) ?? .distantPast
        files.append((file, mtime))
      }
    }

    let topFiles = files.sorted { $0.mtime > $1.mtime }.prefix(limit)

    return topFiles.compactMap { parse(url: $0.url, mtime: $0.mtime) }
  }

  // MARK: - Parsing

  private static func parse(url: URL, mtime: Date) -> PastSession? {
    let sessionId = url.deletingPathExtension().lastPathComponent

    // Read a bounded prefix — first 16 KB is enough to find cwd + title
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    let data = (try? handle.read(upToCount: 16 * 1024)) ?? Data()
    try? handle.close()
    guard let text = String(data: data, encoding: .utf8) else { return nil }

    var cwd: String?
    var aiTitle: String?
    var firstUserText: String?
    var gitBranch: String?
    var lineCount = 0

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
      lineCount += 1
      if lineCount > 200 { break }

      guard
        let d = try? JSONSerialization.jsonObject(
          with: Data(rawLine.utf8)
        ) as? [String: Any]
      else { continue }

      if cwd == nil, let v = d["cwd"] as? String, !v.isEmpty { cwd = v }
      if gitBranch == nil, let v = d["gitBranch"] as? String, !v.isEmpty { gitBranch = v }
      if aiTitle == nil, let v = d["aiTitle"] as? String, !v.isEmpty { aiTitle = v }
      if firstUserText == nil, (d["type"] as? String) == "user" {
        firstUserText = extractUserText(from: d)
      }

      if cwd != nil && aiTitle != nil && firstUserText != nil && gitBranch != nil { break }
    }

    let effectiveCwd = cwd ?? inferCwd(from: url)
    let repo = URL(fileURLWithPath: effectiveCwd).lastPathComponent
    let title = aiTitle ?? firstUserText ?? repo

    return PastSession(
      id: sessionId,
      title: title,
      cwd: effectiveCwd,
      repo: repo,
      branch: gitBranch,
      lastActive: mtime
    )
  }

  private static func extractUserText(from d: [String: Any]) -> String? {
    guard let msg = d["message"] as? [String: Any] else { return nil }
    if let s = msg["content"] as? String, !s.isEmpty {
      return String(s.prefix(80))
    }
    if let arr = msg["content"] as? [[String: Any]] {
      for block in arr {
        if (block["type"] as? String) == "text", let t = block["text"] as? String, !t.isEmpty {
          return String(t.prefix(80))
        }
      }
    }
    return nil
  }

  /// Last-resort cwd from the project directory name.
  /// Claude Code escapes cwd by replacing / with - and prefixing -.
  /// Lossy for paths that contain hyphens, but better than nothing.
  private static func inferCwd(from jsonlURL: URL) -> String {
    let dirName = jsonlURL.deletingLastPathComponent().lastPathComponent
    guard dirName.hasPrefix("-") else { return dirName }
    return "/" + String(dirName.dropFirst()).replacingOccurrences(of: "-", with: "/")
  }
}
