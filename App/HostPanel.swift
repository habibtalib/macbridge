import AppKit
import BridgeCore
import Combine
import SwiftUI

/// Small panels that float above everything on the Mac being controlled:
/// who is in control (with End Session), and Accept / Decline for a Mac set to "ask first".
@MainActor
final class HostPanels {
    private let model: BridgeModel
    private var sessionPanel: NSPanel?
    private var askPanel: NSPanel?
    private var subscriptions: Set<AnyCancellable> = []

    init(model: BridgeModel) {
        self.model = model
        // DispatchQueue, not RunLoop: the run loop's default mode waits while a menu is open.
        model.$hostStatus.combineLatest(model.$hostSince, model.$hostDisplay.map { $0?.id }.removeDuplicates())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status, since, display in self?.showSession(status, since: since, on: display) }
            .store(in: &subscriptions)
        model.$pendingRequest
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in self?.showAsk(request) }
            .store(in: &subscriptions)
    }

    /// On the display being shown, so whoever is in control sees it too.
    private func showSession(_ status: BridgeModel.HostStatus, since: Date?, on display: CGDirectDisplayID?) {
        sessionPanel?.close()
        sessionPanel = nil
        guard case let .sharing(peer) = status else { return }
        let view = HostPanelView(name: model.displayName(peer), started: since ?? Date()) { [weak model] in model?.endHostSession() }
        sessionPanel = Self.panel(view, size: CGSize(width: 320, height: 76), corner: .topRight, on: display.flatMap(Self.screen))
    }

    private static func screen(_ id: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }

    private func showAsk(_ request: BridgeModel.PendingRequest?) {
        askPanel?.close()
        askPanel = nil
        guard let request else { return }
        let view = AskPanelView(name: model.displayName(request.peer), deadline: request.deadline,
                                accept: { [weak model] in model?.acceptRequest() },
                                decline: { [weak model] in model?.declineRequest() })
        askPanel = Self.panel(view, size: CGSize(width: 360, height: 150), corner: .center)
        NSSound.beep()
    }

    private enum Corner { case topRight, center }

    private static func panel(_ view: some View, size: CGSize, corner: Corner, on screen: NSScreen? = nil) -> NSPanel {
        // Non-activating: it must not take the keyboard from what the person at this Mac is doing.
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        if let screen = (screen ?? NSScreen.main)?.visibleFrame {
            switch corner {
            case .topRight:
                panel.setFrameOrigin(CGPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 16))
            case .center:
                panel.setFrameOrigin(CGPoint(x: screen.midX - size.width / 2, y: screen.midY + screen.height / 6))
            }
        }
        panel.orderFrontRegardless()
        return panel
    }
}

struct HostPanelView: View {
    let name: String
    let started: Date
    let end: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.title2).foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(name) is controlling this Mac").font(.callout.weight(.semibold)).lineLimit(2)
                Text(started, style: .timer).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("End", action: end).controlSize(.small)
                .help("End the session now")
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.red.opacity(0.5)))
    }
}

struct AskPanelView: View {
    let name: String
    let deadline: Date
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.questionmark").font(.title).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(name) wants to control this Mac").font(.headline).lineLimit(2)
                    Text("It will see this screen and use the pointer and keyboard.").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Text("Declines by itself in \(deadline, style: .timer)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Decline", action: decline)
                Button("Accept", action: accept).buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
    }
}
