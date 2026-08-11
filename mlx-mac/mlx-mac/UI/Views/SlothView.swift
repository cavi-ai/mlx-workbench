import SwiftUI

// MARK: - SlothView
// Check connectivity to a Sloth AI server and count scannable models to sync.

struct SlothView: View {
    @ObservedObject var appHost: AppHost

    @State private var address = "http://localhost:3000"
    @State private var isChecking = false
    @State private var health: [String: Any]?
    @State private var connected: Bool?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    TextField("Sloth AI address", text: $address)
                        .textFieldStyle(.roundedBorder)
                    Button("Check Connection") { check() }
                        .disabled(isChecking)
                    Spacer()
                }
                if isChecking {
                    ProgressView("Connecting…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                }
                ErrorBanner(text: errorMessage)
                if let connected {
                    Label(
                        connected ? "Connected to Sloth AI" : "Not reachable",
                        systemImage: connected ? "checkmark.circle" : "xmark.circle"
                    )
                    .foregroundColor(connected ? .green : .red)
                }
                if let health {
                    VStack(alignment: .leading, spacing: 4) {
                        SectionTitle(text: "Health")
                        PreviewDictView(value: health)
                    }
                    .formSection {}
                }
                Spacer()
            }
            .padding()
        }
    }

    private func check() {
        errorMessage = nil
        health = nil
        connected = nil
        isChecking = true
        let url = address.hasPrefix("http") ? address : "http://\(address)"
        Task {
            defer { isChecking = false }
            do {
                health = try await Self.fetchHealth(url)
                connected = health != nil
                if health == nil {
                    errorMessage = "Server did not return health JSON."
                }
            } catch {
                connected = false
                errorMessage = "Could not connect to Sloth AI at \(url)."
            }
        }
    }

    static func fetchHealth(_ address: String) async throws -> [String: Any]? {
        guard let url = URL(string: address.hasSuffix("/health") ? address : address + "/api/health") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}