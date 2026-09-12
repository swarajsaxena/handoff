import Foundation

/// Reads the current branch name straight from `.git/HEAD`, no `git`
/// shell-out — matches the plan's "no subprocess spawning" preference and
/// is fast enough to call synchronously on every hook event.
enum GitBranchReader {
  static func branch(atRepoPath cwd: String) -> String? {
    guard let headPath = resolveHeadPath(forRepoAt: cwd),
      let contents = try? String(contentsOfFile: headPath, encoding: .utf8)
    else {
      return nil
    }
    let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("ref:") {
      return
        trimmed
        .replacingOccurrences(of: "ref:", with: "")
        .trimmingCharacters(in: .whitespaces)
        .components(separatedBy: "/")
        .last
    }
    // Detached HEAD: short SHA.
    return trimmed.isEmpty ? nil : String(trimmed.prefix(7))
  }

  /// Resolves `.git/HEAD`, following the `gitdir: <path>` indirection used
  /// by worktrees and submodules where `.git` is a file, not a directory.
  private static func resolveHeadPath(forRepoAt cwd: String) -> String? {
    let gitPath = (cwd as NSString).appendingPathComponent(".git")
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory) else {
      return nil
    }

    if isDirectory.boolValue {
      return (gitPath as NSString).appendingPathComponent("HEAD")
    }

    guard let contents = try? String(contentsOfFile: gitPath, encoding: .utf8),
      let gitdirLine = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
    else {
      return nil
    }
    let resolvedPath =
      gitdirLine
      .replacingOccurrences(of: "gitdir:", with: "")
      .trimmingCharacters(in: .whitespaces)
    return (resolvedPath as NSString).appendingPathComponent("HEAD")
  }
}
