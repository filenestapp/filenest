import Combine
import Foundation
import ServiceManagement

/// Keeps FileNest's login item setting synchronized with macOS.
@MainActor
final class LaunchAtLoginService: ObservableObject {
    enum Status: Equatable {
        case disabled
        case enabled
        case requiresApproval
        case unavailable
    }

    @Published private(set) var status: Status = .disabled
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?

    var isEnabled: Bool { status == .enabled }

    private let statusProvider: () -> SMAppService.Status
    private let registerAction: () throws -> Void
    private let unregisterAction: () async throws -> Void

    init(
        statusProvider: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        registerAction: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregisterAction: @escaping () async throws -> Void = {
            try await SMAppService.mainApp.unregister()
        }
    ) {
        self.statusProvider = statusProvider
        self.registerAction = registerAction
        self.unregisterAction = unregisterAction
        refresh()
    }

    func refresh() {
        switch statusProvider() {
        case .notRegistered:
            status = .disabled
        case .enabled:
            status = .enabled
        case .requiresApproval:
            status = .requiresApproval
        case .notFound:
            status = .unavailable
        @unknown default:
            status = .unavailable
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard !isUpdating, enabled != isEnabled else { return }
        isUpdating = true
        errorMessage = nil
        defer {
            refresh()
            isUpdating = false
        }

        do {
            if enabled {
                try registerAction()
            } else {
                try await unregisterAction()
            }
        } catch {
            errorMessage = "Could not update the login item. Please try again."
            AppLogService.shared.write(
                "launch at login update failed: \(error)",
                category: .appLifecycle,
                level: .error
            )
        }
    }
}
