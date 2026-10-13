//
//  DayFileMirror.swift
//  FinAgentMenuBar
//
//  The local Data/YYYY-MM-DD/<label>.json tree is the source of truth.
//  A mirror copies that layout to a remote store. Cloud Storage is the
//  default mirror; Google Drive remains available behind the same calls.
//

import Foundation

@MainActor
protocol DayFileMirror: AnyObject {
    func markWritten(day: String, fileName: String)
    func markDeleted(day: String, fileName: String)
    func markDayRemoved(day: String)
    func flush(localRoot: URL) async
    func reset()
}

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

    /// Remote object name. `prefix` is the old Drive folder name, kept as a
    /// GCS object prefix so `FinAgentMenuBar/2026-08-01/Visa.json` still lines up.
    static func objectName(prefix: String, day: String, name: String) -> String {
        let root = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if root.isEmpty { return "\(day)/\(name)" }
        return "\(root)/\(day)/\(name)"
    }
}
