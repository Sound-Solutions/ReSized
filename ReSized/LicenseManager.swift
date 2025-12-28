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

    func validateLicense(completion: @escaping (Bool, String?) -> Void) {
        guard !licenseKey.isEmpty else {
            completion(false, "Please enter a license key")
            return
        }

        isValidating = true
        validationError = nil

        // TODO: Replace with actual Lemon Squeezy API call when store is live
        // For now, this is a placeholder that simulates validation

        /*
        Actual implementation will be:

        let url = URL(string: "https://api.lemonsqueezy.com/v1/licenses/validate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["license_key": licenseKey]
        request.httpBody = try? JSONEncoder().encode(body)

        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                self.isValidating = false

                if let error = error {
                    self.validationError = error.localizedDescription
                    completion(false, error.localizedDescription)
                    return
                }

                guard let data = data,
                      let result = try? JSONDecoder().decode(LemonSqueezyResponse.self, from: data) else {
                    self.validationError = "Invalid response"
                    completion(false, "Invalid response from server")
                    return
                }

                if result.valid {
                    self.setLicenseValid(true)
                    completion(true, nil)
                } else {
                    self.validationError = "Invalid license key"
                    completion(false, "Invalid license key")
                }
            }
        }.resume()
        */

        // Placeholder: simulate network delay and validation
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.isValidating = false

            // For testing: accept any key that starts with "RESIZED-"
            if self.licenseKey.uppercased().hasPrefix("RESIZED-") {
                self.setLicenseValid(true)
                completion(true, nil)
            } else {
                self.validationError = "Invalid license key (use RESIZED-XXXX for testing)"
                completion(false, "Invalid license key")
            }
        }
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
        initializeTrialIfNeeded()
        licenseKey = ""
        updateLicenseState()
    }
}

// MARK: - Lemon Squeezy Response (for future use)

struct LemonSqueezyValidationResponse: Codable {
    let valid: Bool
    let error: String?
    let licenseKey: LicenseKeyData?

    enum CodingKeys: String, CodingKey {
        case valid
        case error
        case licenseKey = "license_key"
    }
}

struct LicenseKeyData: Codable {
    let id: Int
    let status: String
    let key: String
    let activationLimit: Int?
    let activationsCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, status, key
        case activationLimit = "activation_limit"
        case activationsCount = "activations_count"
    }
}
