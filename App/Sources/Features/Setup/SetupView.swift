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
        // Inside tvOS's own safe area, which already keeps it off the edges of the TV.
        HStack(alignment: .center, spacing: Theme.Spacing.section) {
            VStack(spacing: Theme.Spacing.titleToContent) {
                if let url = controller.url, let image = QRCode.image(for: url) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 400, height: 400)
                        // The white margin a phone camera needs around the code to find it.
                        .padding(24)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: Theme.Radius.floating, style: .continuous))
                    // Always one line: shrink a long address rather than break it after "http://".
                    Text(url)
                        .font(.headline.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                } else {
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 140)).foregroundStyle(.secondary)
                    Text("No network address yet").font(.headline)
                }
            }
            .frame(width: 500)

            VStack(alignment: .leading, spacing: Theme.Spacing.titleToContent) {
                Text("Connect your YouTube account").font(.title2.bold())
                VStack(alignment: .leading, spacing: Theme.Spacing.row) {
                    step(1, "On a computer or phone on the same Wi-Fi, scan the code or open the address shown.")
                    step(2, "In a private (incognito) browser window, sign in to youtube.com and export its cookies.")
                    step(3, "Paste them on the page and press “Send to TV”.")
                    step(4, "Close the private window afterwards. Don't sign out of YouTube there.")
                }
                .font(.headline.weight(.regular))
                statusView
                HStack(spacing: Theme.Spacing.titleToContent) {
                    if controller.serverProblem != nil {
                        Button("Retry") { controller.restartServer() }
                    }
                    Button("Refresh address") { controller.refreshAddress() }
                    if model.isSignedIn {
                        Button("Cancel") { model.cancelCookieReentry() }
                    }
                }
                // Room above for the focused button to grow into.
                .padding(.top, Theme.Spacing.row)
            }
            // Every line at its full height: in a stack that's short of room, Text truncates with
            // "…" instead of wrapping.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 1100, alignment: .leading)
        }
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
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.row) {
            Text("\(number)").font(.headline).frame(width: 52, height: 52)
                .background(Color.red, in: Circle())
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
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
