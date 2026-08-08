import Foundation
import SwiftUI

// MARK: - License State

enum LicenseState {
    case trial(daysRemaining: Int)
    case trialExpired
    case licensed
}

// MARK: - License Manager

class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    /// Master switch for the whole trial/licensing system.
    ///
    /// Currently OFF: the app runs unrestricted — no trial clock, no expiry
    /// overlay, and Settings hides the License section rather than claiming a
    /// licence that doesn't exist. While off, no trial start date is written, so
    /// turning this back on starts the 7 days from that point instead of
    /// retroactively burning them. Nothing was deleted; flip to true to restore.
    static let isEnabled = false

    private let trialStartKey = "ReSized_TrialStartDate"
    private let licenseKeyKey = "ReSized_LicenseKey"
    private let licenseValidKey = "ReSized_LicenseValid"

    private let trialDays = 7

    // Lemon Squeezy configuration
    let storeURL = "https://resized.lemonsqueezy.com/buy/748344"  // Update with your actual store URL
    let productID = "748344"

    @Published var licenseState: LicenseState = .trial(daysRemaining: 7)
    @Published var licenseKey: String = ""
    @Published var isValidating: Bool = false
    @Published var validationError: String?

    init() {
        guard Self.isEnabled else {
            // Deliberately does not stamp a trial start date — see isEnabled.
            licenseState = .licensed
            return
        }
        initializeTrialIfNeeded()
        loadLicenseKey()
        updateLicenseState()
    }

    // MARK: - Trial Management

    private func initializeTrialIfNeeded() {
        if UserDefaults.standard.object(forKey: trialStartKey) == nil {
            UserDefaults.standard.set(Date(), forKey: trialStartKey)
        }
    }

    var trialStartDate: Date {
        UserDefaults.standard.object(forKey: trialStartKey) as? Date ?? Date()
    }

    var trialDaysRemaining: Int {
        let elapsed = Calendar.current.dateComponents([.day], from: trialStartDate, to: Date()).day ?? 0
        return max(0, trialDays - elapsed)
    }

    var isTrialExpired: Bool {
        trialDaysRemaining <= 0
    }

    // MARK: - License Key Management

    private func loadLicenseKey() {
        licenseKey = UserDefaults.standard.string(forKey: licenseKeyKey) ?? ""
    }

    func saveLicenseKey(_ key: String) {
        licenseKey = key
        UserDefaults.standard.set(key, forKey: licenseKeyKey)
    }

    var isLicensed: Bool {
        UserDefaults.standard.bool(forKey: licenseValidKey)
    }

    private func setLicenseValid(_ valid: Bool) {
        UserDefaults.standard.set(valid, forKey: licenseValidKey)
        updateLicenseState()
    }

    // MARK: - License State

    func updateLicenseState() {
        guard Self.isEnabled else {
            licenseState = .licensed
            return
        }
        if isLicensed {
            licenseState = .licensed
        } else if isTrialExpired {
            licenseState = .trialExpired
        } else {
            licenseState = .trial(daysRemaining: trialDaysRemaining)
        }
        objectWillChange.send()
    }

    var canUseApp: Bool {
        switch licenseState {
        case .trial, .licensed:
            return true
        case .trialExpired:
            return false
        }
    }

    // MARK: - License Validation

    private let instanceIDKey = "ReSized_InstanceID"

    private var instanceID: String? {
        get { UserDefaults.standard.string(forKey: instanceIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: instanceIDKey) }
    }

    private func getInstanceName() -> String {
        Host.current().localizedName ?? "Mac"
    }

    func validateLicense(completion: @escaping (Bool, String?) -> Void) {
        guard !licenseKey.isEmpty else {
            completion(false, "Please enter a license key")
            return
        }

        isValidating = true
        validationError = nil

        // If we have an instance ID, validate it; otherwise activate
        if let existingInstanceID = instanceID {
            validateExistingLicense(instanceID: existingInstanceID, completion: completion)
        } else {
            activateLicense(completion: completion)
        }
    }

    private func activateLicense(completion: @escaping (Bool, String?) -> Void) {
        let url = URL(string: "https://api.lemonsqueezy.com/v1/licenses/activate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyString = "license_key=\(licenseKey)&instance_name=\(getInstanceName().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Mac")"
        request.httpBody = bodyString.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                self.isValidating = false

                if let error = error {
                    self.validationError = "Network error: \(error.localizedDescription)"
                    completion(false, self.validationError)
                    return
                }

                guard let data = data else {
                    self.validationError = "No response from server"
                    completion(false, self.validationError)
                    return
                }

                do {
                    let result = try JSONDecoder().decode(LemonSqueezyActivationResponse.self, from: data)

                    if result.activated {
                        self.instanceID = result.instance?.id
                        self.saveLicenseKey(self.licenseKey)
                        self.setLicenseValid(true)
                        completion(true, nil)
                    } else {
                        self.validationError = result.error ?? "Activation failed"
                        completion(false, self.validationError)
                    }
                } catch {
                    // Try to parse error response
                    if let errorResponse = try? JSONDecoder().decode(LemonSqueezyErrorResponse.self, from: data) {
                        self.validationError = errorResponse.error ?? "Invalid license key"
                    } else {
                        self.validationError = "Failed to parse response"
                    }
                    completion(false, self.validationError)
                }
            }
        }.resume()
    }

    private func validateExistingLicense(instanceID: String, completion: @escaping (Bool, String?) -> Void) {
        let url = URL(string: "https://api.lemonsqueezy.com/v1/licenses/validate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyString = "license_key=\(licenseKey)&instance_id=\(instanceID)"
        request.httpBody = bodyString.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                self.isValidating = false

                if let error = error {
                    // Network error - allow offline use if previously validated
                    if self.isLicensed {
                        completion(true, nil)
                    } else {
                        self.validationError = "Network error: \(error.localizedDescription)"
                        completion(false, self.validationError)
                    }
                    return
                }

                guard let data = data else {
                    self.validationError = "No response from server"
                    completion(false, self.validationError)
                    return
                }

                do {
                    let result = try JSONDecoder().decode(LemonSqueezyValidationResponse.self, from: data)

                    if result.valid {
                        self.setLicenseValid(true)
                        completion(true, nil)
                    } else {
                        // License no longer valid - clear stored data
                        self.instanceID = nil
                        self.setLicenseValid(false)
                        self.validationError = result.error ?? "License is no longer valid"
                        completion(false, self.validationError)
                    }
                } catch {
                    if let errorResponse = try? JSONDecoder().decode(LemonSqueezyErrorResponse.self, from: data) {
                        self.validationError = errorResponse.error ?? "Validation failed"
                    } else {
                        self.validationError = "Failed to parse response"
                    }
                    completion(false, self.validationError)
                }
            }
        }.resume()
    }

    func deactivateLicense(completion: ((Bool) -> Void)? = nil) {
        guard let existingInstanceID = instanceID, !licenseKey.isEmpty else {
            completion?(true)
            return
        }

        let url = URL(string: "https://api.lemonsqueezy.com/v1/licenses/deactivate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyString = "license_key=\(licenseKey)&instance_id=\(existingInstanceID)"
        request.httpBody = bodyString.data(using: .utf8)

        URLSession.shared.dataTask(with: request) { _, _, _ in
            DispatchQueue.main.async {
                self.instanceID = nil
                self.setLicenseValid(false)
                completion?(true)
            }
        }.resume()
    }

    // MARK: - Purchase

    func openPurchasePage() {
        if let url = URL(string: storeURL) {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Reset (for testing)

    func resetTrial() {
        UserDefaults.standard.removeObject(forKey: trialStartKey)
        UserDefaults.standard.removeObject(forKey: licenseKeyKey)
        UserDefaults.standard.removeObject(forKey: licenseValidKey)
        UserDefaults.standard.removeObject(forKey: instanceIDKey)
        initializeTrialIfNeeded()
        licenseKey = ""
        updateLicenseState()
    }
}

// MARK: - Lemon Squeezy API Responses

struct LemonSqueezyValidationResponse: Codable {
    let valid: Bool
    let error: String?
    let licenseKey: LicenseKeyInfo?
    let instance: InstanceInfo?
    let meta: MetaInfo?

    enum CodingKeys: String, CodingKey {
        case valid, error, instance, meta
        case licenseKey = "license_key"
    }
}

struct LemonSqueezyActivationResponse: Codable {
    let activated: Bool
    let error: String?
    let licenseKey: LicenseKeyInfo?
    let instance: InstanceInfo?
    let meta: MetaInfo?

    enum CodingKeys: String, CodingKey {
        case activated, error, instance, meta
        case licenseKey = "license_key"
    }
}

struct LemonSqueezyErrorResponse: Codable {
    let error: String?
}

struct LicenseKeyInfo: Codable {
    let id: Int
    let status: String
    let key: String
    let activationLimit: Int
    let activationUsage: Int
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id, status, key
        case activationLimit = "activation_limit"
        case activationUsage = "activation_usage"
        case expiresAt = "expires_at"
    }
}

struct InstanceInfo: Codable {
    let id: String
    let name: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdAt = "created_at"
    }
}

struct MetaInfo: Codable {
    let storeId: Int?
    let productId: Int?
    let productName: String?
    let variantId: Int?
    let variantName: String?
    let customerId: Int?
    let customerName: String?
    let customerEmail: String?

    enum CodingKeys: String, CodingKey {
        case storeId = "store_id"
        case productId = "product_id"
        case productName = "product_name"
        case variantId = "variant_id"
        case variantName = "variant_name"
        case customerId = "customer_id"
        case customerName = "customer_name"
        case customerEmail = "customer_email"
    }
}
