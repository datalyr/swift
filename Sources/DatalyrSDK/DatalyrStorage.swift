import Foundation
import Security

// MARK: - Storage Protocol

/// Protocol for storage operations
internal protocol Storage {
    func getString(_ key: String) async -> String?
    func setString(_ key: String, value: String) async
    func getDouble(_ key: String) async -> Double?
    func setDouble(_ key: String, value: Double) async
    func getBool(_ key: String) async -> Bool?
    func setBool(_ key: String, value: Bool) async
    func getData(_ key: String) async -> Data?
    func setData(_ key: String, value: Data) async
    func removeValue(_ key: String) async
    func clear() async
}

// MARK: - Datalyr Storage

/// Storage manager for Datalyr SDK using UserDefaults.
///
/// IOS-23: a Keychain path used to live here and was **unreachable**.
/// `isSensitiveKey` compared against unprefixed names ("user_id", "visitor_id",
/// …) while every caller passes a `StorageKeys` constant, which is already
/// prefixed ("datalyr_user_id" — see DatalyrUtils.swift). The comparison was
/// therefore always false and nothing ever reached the Keychain, despite the
/// security code path existing.
///
/// It was DELETED rather than repaired, deliberately. Repairing it would move
/// identifiers into the Keychain, where they **survive app deletion** — so a
/// reinstall would stop minting a new visitor and would silently merge into the
/// previous identity. That changes `app_install` counts and attribution for
/// every install, diverges from the web SDK (localStorage) and React Native
/// (AsyncStorage) which both reset on uninstall, and would need a read-fallback
/// migration to avoid orphaning existing values.
///
/// **Identifiers reset when the app is deleted.** That is the current, intended
/// behaviour across all three client SDKs. If cross-reinstall identity is ever
/// wanted it should be an explicit opt-in with its own migration — not a side
/// effect of a cleanup.
internal class DatalyrStorage: Storage {
    static let shared = DatalyrStorage()
    
    private let userDefaults = UserDefaults.standard
    private let keyPrefix = "datalyr_"
    
    private init() {}
    
    // MARK: - String Storage
    
    func getString(_ key: String) async -> String? {
        let prefixedKey = keyPrefix + key
        
        // Try UserDefaults first
        if let value = userDefaults.string(forKey: prefixedKey) {
            return value
        }
        
        return nil
    }
    
    func setString(_ key: String, value: String) async {
        let prefixedKey = keyPrefix + key
        
        userDefaults.set(value, forKey: prefixedKey)
    }
    
    // MARK: - Double Storage
    
    func getDouble(_ key: String) async -> Double? {
        let prefixedKey = keyPrefix + key
        let value = userDefaults.double(forKey: prefixedKey)
        return userDefaults.object(forKey: prefixedKey) != nil ? value : nil
    }
    
    func setDouble(_ key: String, value: Double) async {
        let prefixedKey = keyPrefix + key
        userDefaults.set(value, forKey: prefixedKey)
    }
    
    // MARK: - Bool Storage
    
    func getBool(_ key: String) async -> Bool? {
        let prefixedKey = keyPrefix + key
        return userDefaults.object(forKey: prefixedKey) != nil ? userDefaults.bool(forKey: prefixedKey) : nil
    }
    
    func setBool(_ key: String, value: Bool) async {
        let prefixedKey = keyPrefix + key
        userDefaults.set(value, forKey: prefixedKey)
    }
    
    // MARK: - Data Storage
    
    func getData(_ key: String) async -> Data? {
        let prefixedKey = keyPrefix + key
        return userDefaults.data(forKey: prefixedKey)
    }
    
    func setData(_ key: String, value: Data) async {
        let prefixedKey = keyPrefix + key
        userDefaults.set(value, forKey: prefixedKey)
    }
    
    // MARK: - Remove and Clear
    
    func removeValue(_ key: String) async {
        let prefixedKey = keyPrefix + key
        userDefaults.removeObject(forKey: prefixedKey)
    }
    
    func clear() async {
        // Remove all Datalyr keys from UserDefaults
        let keys = userDefaults.dictionaryRepresentation().keys
        for key in keys {
            if key.hasPrefix(keyPrefix) {
                userDefaults.removeObject(forKey: key)
            }
        }
    }
    
    /// Get Codable object from storage
    func getCodable<T: Codable>(_ key: String, type: T.Type) async -> T? {
        guard let data = await getData(key) else { return nil }
        
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            errorLog("Failed to decode \(type) from storage", error: error)
            return nil
        }
    }
    
    /// Set Codable object to storage
    func setCodable<T: Codable>(_ key: String, value: T) async {
        do {
            let data = try JSONEncoder().encode(value)
            await setData(key, value: data)
        } catch {
            errorLog("Failed to encode \(type(of: value)) to storage", error: error)
        }
    }
    
    /// Get array of Codable objects from storage
    func getCodableArray<T: Codable>(_ key: String, type: T.Type) async -> [T]? {
        guard let data = await getData(key) else { return nil }
        
        do {
            return try JSONDecoder().decode([T].self, from: data)
        } catch {
            errorLog("Failed to decode [\(type)] from storage", error: error)
            return nil
        }
    }
    
    /// Set array of Codable objects to storage
    func setCodableArray<T: Codable>(_ key: String, value: [T]) async {
        do {
            let data = try JSONEncoder().encode(value)
            await setData(key, value: data)
        } catch {
            errorLog("Failed to encode [\(type(of: value))] to storage", error: error)
        }
    }
} 