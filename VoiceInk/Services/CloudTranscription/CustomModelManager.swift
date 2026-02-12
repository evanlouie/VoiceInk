import Foundation
import os

class CustomModelManager: ObservableObject {
    static let shared = CustomModelManager()
    
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "CustomModelManager")
    private let userDefaults = UserDefaults.standard
    private let customModelsKey = "customCloudModels"
    
    @Published var customModels: [CustomCloudModel] = []
    
    private init() {
        loadCustomModels()
    }
    
    // MARK: - CRUD Operations
    
    func addCustomModel(_ model: CustomCloudModel) {
        customModels.append(model)
        saveCustomModels()
    }

    func removeCustomModel(withId id: UUID) {
        customModels.removeAll { $0.id == id }
        saveCustomModels()
        APIKeyManager.shared.deleteCustomModelAPIKey(forModelId: id)
    }

    func updateCustomModel(_ updatedModel: CustomCloudModel) {
        if let index = customModels.firstIndex(where: { $0.id == updatedModel.id }) {
            customModels[index] = updatedModel
            saveCustomModels()
        }
    }
    
    // MARK: - Persistence
    
    private func loadCustomModels() {
        guard let data = userDefaults.data(forKey: customModelsKey) else {
            return
        }
        
        do {
            customModels = try JSONDecoder().decode([CustomCloudModel].self, from: data)
        } catch {
            logger.error("Failed to decode custom models: \(error.localizedDescription)")
            customModels = []
        }
    }
    
    func saveCustomModels() {
        do {
            let data = try JSONEncoder().encode(customModels)
            userDefaults.set(data, forKey: customModelsKey)
        } catch {
            logger.error("Failed to encode custom models: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Validation
    
    func validateModel(name: String, displayName: String, apiEndpoint: String, apiKey: String, modelName: String) -> [String] {
        var errors: [String] = []
        
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Name cannot be empty")
        }
        
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Display name cannot be empty")
        }
        
        if apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("API endpoint cannot be empty")
        } else if !isValidURL(apiEndpoint) {
            errors.append("API endpoint must use HTTPS (HTTP is only allowed for localhost)")
        }
        
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("API key cannot be empty")
        }
        
        if modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Model name cannot be empty")
        }
        
        // Check for duplicate names
        if customModels.contains(where: { $0.name == name }) {
            errors.append("A model with this name already exists")
        }
        
        return errors
    }
    
    func validateModel(name: String, displayName: String, apiEndpoint: String, apiKey: String, modelName: String, excludingId: UUID? = nil) -> [String] {
        var errors: [String] = []
        
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Name cannot be empty")
        }
        
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Display name cannot be empty")
        }
        
        if apiEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("API endpoint cannot be empty")
        } else if !isValidURL(apiEndpoint) {
            errors.append("API endpoint must use HTTPS (HTTP is only allowed for localhost)")
        }
        
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("API key cannot be empty")
        }
        
        if modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Model name cannot be empty")
        }
        
        // Check for duplicate names, excluding the specified ID
        if customModels.contains(where: { $0.name == name && $0.id != excludingId }) {
            errors.append("A model with this name already exists")
        }
        
        return errors
    }
    
    private func isValidURL(_ string: String) -> Bool {
        guard let components = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return false
        }

        if scheme == "https" {
            return true
        }

        if scheme == "http" {
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        }

        return false
    }
} 
