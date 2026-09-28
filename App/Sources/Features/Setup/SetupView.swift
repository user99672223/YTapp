import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import Core

/// First run (and cookie re-entry): shows a QR code for the setup page served by the TV.
struct SetupView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = SetupController()

    var body: some View {
        HStack(alignment: .center, spacing: 80) {
            VStack(spacing: 24) {
                if let url = controller.url, let image = QRCode.image(for: url) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 440, height: 440)
                        .padding(24)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 24))
                    Text(url).font(.title3.monospaced()).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 140)).foregroundStyle(.secondary)
                    Text("No network address yet").font(.headline)
                }
            }
            .frame(width: 560)

            VStack(alignment: .leading, spacing: 28) {
                Text("Connect your YouTube account").font(.largeTitle.bold())
                VStack(alignment: .leading, spacing: 16) {
                    step(1, "On a computer or phone on the same Wi-Fi, scan the code or open the address shown.")
                    step(2, "In a private (incognito) browser window, sign in to youtube.com and export its cookies.")
                    step(3, "Paste them on the page and press “Send to TV”.")
                    step(4, "Close the private window afterwards. Don't sign out of YouTube there.")
                }
                .font(.title3)
                statusView
                HStack(spacing: 30) {
                    if controller.serverProblem != nil {
                        Button("Retry") { controller.restartServer() }
                    }
                    Button("Refresh address") { controller.refreshAddress() }
                    if model.isSignedIn {
                        Button("Cancel") { model.cancelCookieReentry() }
                    }
                }
            }
            .frame(maxWidth: 1000, alignment: .leading)
        }
        .padding(80)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear { controller.start(model: model) }
        .onDisappear { controller.stop() }
        // tvOS tears down a suspended app's listening socket, and onAppear/onDisappear don't
        // fire for the app going to the background and back.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: controller.stop()
            case .active: controller.resume()
            default: break
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text("\(number)").font(.title3.bold()).frame(width: 44, height: 44)
                .background(Color.red, in: Circle())
            Text(text)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        if let problem = controller.serverProblem {
            Label(problem, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        } else {
            cookieStatus
        }
    }

    @ViewBuilder
    private var cookieStatus: some View {
        switch controller.phase {
        case .waiting:
            Label("Waiting for your cookies…", systemImage: "hourglass").foregroundStyle(.secondary)
        case .checking:
            HStack(spacing: 16) {
                ProgressView()
                Text("Checking the cookies with YouTube…")
            }
        case .success(let name):
            Label("Signed in as \(name)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .error(let message):
            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}

@MainActor
final class SetupController: ObservableObject {
    enum Phase: Equatable {
        case waiting
        case checking
        case success(String)
        case error(String)
    }

    @Published var url: String?
    @Published var phase: Phase = .waiting
    /// Why the setup page isn't being served (shown with a Retry button).
    @Published private(set) var serverProblem: String?
    private let server = SetupServer()

    func start(model: AppModel) {
        refreshAddress()
        server.onStatus = { [weak self] status in
            guard let self else { return }
            switch status {
            case .failed(let message): self.serverProblem = message
            case .listening:
                self.serverProblem = nil
                // The TV may have had no address yet when the screen appeared.
                self.refreshAddress()
            case .starting: break
            }
        }
        server.onCookies = { [weak self, weak model] raw in
            guard let model else { return .failure(message: "The app is restarting. Try again.") }
            await MainActor.run { self?.phase = .checking }
            do {
                let account = try await model.submitCookies(raw)
                await MainActor.run { self?.phase = .success(account.name) }
                return .success(accountName: account.name)
            } catch {
                let message = (error as? BridgeError)?.userMessage ?? error.localizedDescription
                await MainActor.run { self?.phase = .error(message) }
                return .failure(message: message)
            }
        }
        server.start()
    }

    func refreshAddress() {
        url = NetworkInfo.setupURL
    }

    func restartServer() {
        server.restart()
        refreshAddress()
    }

    /// Back from the background: serve the page again (no-op if it's still running).
    func resume() {
        server.start()
        refreshAddress()
    }

    func stop() {
        server.stop()
    }
}

enum QRCode {
    static func image(for text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
