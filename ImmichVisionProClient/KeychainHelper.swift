//
//  KeychainHelper.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 2/6/26.
//

import Foundation
import Security

class KeychainHelper {
    static let shared = KeychainHelper()

    private let service = "com.juliangraymedia.Vimmich"

    private init() {}

    // MARK: - Access Token

    func saveAccessToken(_ token: String) -> Bool {
        return save(key: "accessToken", value: token)
    }

    func getAccessToken() -> String? {
        return get(key: "accessToken")
    }

    func deleteAccessToken() {
        delete(key: "accessToken")
    }

    // MARK: - Server URL (stored in UserDefaults since it's not sensitive)

    func saveServerURL(_ url: String) {
        UserDefaults.standard.set(url, forKey: "serverURL")
    }

    func getServerURL() -> String? {
        return UserDefaults.standard.string(forKey: "serverURL")
    }

    func deleteServerURL() {
        UserDefaults.standard.removeObject(forKey: "serverURL")
    }

    // MARK: - User Email (for display purposes)

    func saveUserEmail(_ email: String) {
        UserDefaults.standard.set(email, forKey: "userEmail")
    }

    func getUserEmail() -> String? {
        return UserDefaults.standard.string(forKey: "userEmail")
    }

    func deleteUserEmail() {
        UserDefaults.standard.removeObject(forKey: "userEmail")
    }

    // MARK: - Locked Folder PIN

    func deletePIN() {
        delete(key: "lockedFolderPIN")
    }

    // MARK: - Clear All

    func clearAll() {
        deleteAccessToken()
        deleteServerURL()
        deleteUserEmail()
        deletePIN()
    }

    // MARK: - Generic Keychain Operations

    private func save(key: String, value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        // Delete any existing item first
        delete(key: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private func get(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    private func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        SecItemDelete(query as CFDictionary)
    }
}
