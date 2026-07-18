import Foundation

struct ProfileFileStore {
    let directory: URL

    init(homeDirectory: String = NSHomeDirectory()) {
        directory = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".local/share/wgsense/profiles")
    }

    func listProfiles() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )) ?? []
        return files
            .filter { $0.pathExtension == "conf" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    func readProfile(_ name: String) -> String? {
        try? String(contentsOf: profileURL(name), encoding: .utf8)
    }

    func saveProfile(_ name: String, content: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try content.write(to: profileURL(name), atomically: true, encoding: .utf8)
    }

    func deleteProfile(_ name: String) throws {
        try FileManager.default.removeItem(at: profileURL(name))
    }

    func saveDefault(content: String) throws {
        try saveProfile("default", content: content)
    }

    private func profileURL(_ name: String) -> URL {
        directory.appendingPathComponent(name + ".conf")
    }
}
