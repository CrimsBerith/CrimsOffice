import Foundation
import LocalAuthentication
import Security

/// Thread-safe macOS Keychain wrapper storing provider API secrets outside plaintext config files.
final class KeychainStore: @unchecked Sendable {
    static let shared = KeychainStore(
        service: "com.crimsoffice.apikeys",
        fallbackServices: ["com.clawoffice.apikeys"]
    )

    private let service: String
    private let fallbackServices: [String]
    private let lock = NSLock()
    private let disableInteraction: Bool

    init(
        service: String,
        fallbackServices: [String] = [],
        disableInteraction: Bool = KeychainStore.isNonInteractiveProcess
    ) {
        self.service = service
        self.fallbackServices = fallbackServices
        self.disableInteraction = disableInteraction
    }

    static var isNonInteractiveProcess: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["XCTestBundlePath"] != nil
    }

    private func baseQuery(account: String, serviceName: String? = nil) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName ?? service,
            kSecAttrAccount as String: account
        ]
        if disableInteraction {
            let ctx = LAContext()
            ctx.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = ctx
        }
        return query
    }

    @discardableResult
    func setSecret(_ secret: String, forAccount account: String) -> Bool {
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else { return false }
        let trimmedSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSecret.isEmpty {
            deleteSecret(forAccount: trimmedAccount)
            return true
        }

        lock.lock()
        defer { lock.unlock() }

        let data = Data(trimmedSecret.utf8)
        let matchQuery = baseQuery(account: trimmedAccount)
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(matchQuery as CFDictionary, updateAttrs as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        if status == errSecItemNotFound {
            var addQuery = baseQuery(account: trimmedAccount)
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    func secret(forAccount account: String) -> String? {
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else { return nil }

        lock.lock()
        defer { lock.unlock() }

        for svc in [service] + fallbackServices {
            var query = baseQuery(account: trimmedAccount, serviceName: svc)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, let val = String(data: data, encoding: .utf8), !val.isEmpty {
                // Seamlessly migrate legacy ClawOffice Keychain secrets to Crims Office service
                if svc != service {
                    var addQuery = baseQuery(account: trimmedAccount, serviceName: service)
                    addQuery[kSecValueData as String] = data
                    addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                    _ = SecItemAdd(addQuery as CFDictionary, nil)
                }
                return val
            }
        }
        return nil
    }

    func deleteSecret(forAccount account: String) {
        let trimmedAccount = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccount.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        for svc in [service] + fallbackServices {
            SecItemDelete(baseQuery(account: trimmedAccount, serviceName: svc) as CFDictionary)
        }
    }
}
