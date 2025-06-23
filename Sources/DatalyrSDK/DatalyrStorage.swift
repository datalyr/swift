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

/// Storage manager for Datalyr SDK using UserDefaults and Keychain
internal class DatalyrStorage: Storage {
    static let shared = DatalyrStorage()
    
    private let userDefaults = UserDefaults.standard
    private let keyPrefix = "datalyr_"
    private let keychainService = "com.datalyr.sdk"
    
    private init() {}
    
    // MARK: - String Storage
    
    func getString(_ key: String) async -> String? {
        let prefixedKey = keyPrefix + key
        
        // Try UserDefaults first
        if let value = userDefaults.string(forKey: prefixedKey) {
            return value
        }
        
        // If it's a sensitive key, try Keychain
        if isSensitiveKey(key) {
            return getKeychainString(key)
        }
        
        return nil
    }
    
    func setString(_ key: String, value: String) async {
        let prefixedKey = keyPrefix + key
        
        if isSensitiveKey(key) {
            // Store sensitive data in Keychain
            setKeychainString(key, value: value)
        } else {
            // Store regular data in UserDefaults
            userDefaults.set(value, forKey: prefixedKey)
        }
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
        
        if isSensitiveKey(key) {
            removeKeychainValue(key)
        }
    }
    
    func clear() async {
        // Remove all Datalyr keys from UserDefaults
        let keys = userDefaults.dictionaryRepresentation().keys
        for key in keys {
            if key.hasPrefix(keyPrefix) {
                userDefaults.removeObject(forKey: key)
            }
        }
        
        // Clear Keychain items
        clearKeychain()
    }
    
    // MARK: - Keychain Operations
    
    private func isSensitiveKey(_ key: String) -> Bool {
        // Keys that should be stored in Keychain for security
        let sensitiveKeys = [
            "api_key",
            "user_id",
            "device_id",
            "visitor_id"
        ]
        return sensitiveKeys.contains(key)
    }
    
    private func getKeychainString(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        
        return String(data: data, encoding: .utf8)
    }
    
    private func setKeychainString(_ key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key,
            kSecValueData as String: data
        ]
        
        // Delete any existing item
        SecItemDelete(query as CFDictionary)
        
        // Add new item
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            debugLog("Failed to save to Keychain: \(status)")
        }
    }
    
    private func removeKeychainValue(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: key
        ]
        
        SecItemDelete(query as CFDictionary)
    }
    
    private func clearKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Convenience Extensions

extension DatalyrStorage {
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