import Foundation

enum WorkingDirectory {
    /// A missing override inherits the project directory. Keep relative paths
    /// relative so moving the project also moves its service directories.
    static func normalizedOverride(_ path: String?) -> String? {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    static func resolve(_ override: String?, projectDirectory: String) -> URL {
        let projectPath = (projectDirectory.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true)
        guard let path = normalizedOverride(override) else {
            return projectURL.standardizedFileURL
        }
        return URL(fileURLWithPath: path, isDirectory: true, relativeTo: projectURL).standardizedFileURL
    }
}
