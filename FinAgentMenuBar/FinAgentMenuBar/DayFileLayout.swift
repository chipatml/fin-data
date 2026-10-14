//
//  DayFileLayout.swift
//  FinAgentMenuBar
//
//  The local Data/YYYY-MM-DD/<label>.json tree is the source of truth.
//  Cloud Storage copies that layout under the configured object prefix.
//

import Foundation

enum DayFileLayout {
    /// `YYYY-MM-DD/<name>.json` paths currently on disk.
    static func inventory(_ root: URL) -> [(day: String, name: String, path: String)] {
        let fm = FileManager.default
        guard let dayNames = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }

        var found: [(day: String, name: String, path: String)] = []
        for day in dayNames where isDayFolder(day) {
            let dayURL = root.appendingPathComponent(day, isDirectory: true)
            let files = (try? fm.contentsOfDirectory(atPath: dayURL.path)) ?? []
            for file in files where file.hasSuffix(".json") {
                found.append((day: day, name: file, path: "\(day)/\(file)"))
            }
        }
        return found
    }

    static func isDayFolder(_ name: String) -> Bool {
        name.count == 10 && name.allSatisfy { $0.isNumber || $0 == "-" }
    }

    /// Object name inside the bucket. An empty prefix stores the day folder at the bucket root.
    static func objectName(prefix: String, day: String, name: String) -> String {
        let root = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if root.isEmpty { return "\(day)/\(name)" }
        return "\(root)/\(day)/\(name)"
    }
}
