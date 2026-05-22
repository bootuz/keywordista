import Fluent
import Foundation

protocol SettingsRepositoryProtocol: Sendable {
    func get(_ key: String) async throws -> String?
    func getMany(keys: [String]) async throws -> [String: String]
    func set(_ key: String, value: String) async throws
    func delete(_ key: String) async throws
}

struct FluentSettingsRepository: SettingsRepositoryProtocol {
    let db: any Database

    func get(_ key: String) async throws -> String? {
        try await Setting.query(on: db).filter(\.$key == key).first()?.value
    }

    func getMany(keys: [String]) async throws -> [String: String] {
        let rows = try await Setting.query(on: db).filter(\.$key ~~ keys).all()
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.value) })
    }

    func set(_ key: String, value: String) async throws {
        if let existing = try await Setting.query(on: db).filter(\.$key == key).first() {
            existing.value = value
            try await existing.save(on: db)
        } else {
            try await Setting(key: key, value: value).save(on: db)
        }
    }

    func delete(_ key: String) async throws {
        try await Setting.query(on: db).filter(\.$key == key).delete()
    }
}
