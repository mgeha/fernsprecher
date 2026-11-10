import AppKit
import OxoKit
import SwiftUI

/// Small floating window in the top-right corner while a call is ringing.
/// A non-activating panel: showing it does not activate the app, so the
/// current app keeps focus. Closes by itself once the call is answered or gone.
@MainActor
final class CallPopupController {
    private var panel: NSPanel?
    private var shown: ActiveCall?
    /// Calls the user dismissed; not shown again while they keep ringing.
    private var dismissed: Set<String> = []

    func update(ringing call: ActiveCall?, model: AppModel) {
        guard let call, model.popupEnabled, !dismissed.contains(call.callRef) else {
            hide()
            if call == nil { dismissed.removeAll() }
            return
        }
        // Same call with new details (e.g. from e_callChange): redraw.
        guard shown != call else { return }
        show(call, model: model)
    }

    private func show(_ call: ActiveCall, model: AppModel) {
        hide()
        let view = CallPopupView(
            call: call,
            name: call.name ?? model.name(for: call.number),
            route: model.route(of: call),
            answer: { [weak self] in
                model.answer(call)
                self?.hide()
            },
            dismiss: { [weak self] in
                self?.dismissed.insert(call.callRef)
                self?.hide()
            })
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // Measured inside the panel: outside a window the buttons come out
        // slightly narrower and their titles were cut off.
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        panel.setContentSize(size)

        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16,
                                         y: screen.maxY - size.height - 16))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        shown = call
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
        shown = nil
    }
}

private struct CallPopupView: View {
    let call: ActiveCall
    let name: String?
    let route: String?
    let answer: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.arrow.down.left")
                .font(.title)
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 2) {
                Text("Incoming call").font(.caption).foregroundStyle(.secondary)
                Text(name ?? call.number ?? String(localized: "Unknown"))
                    .font(.headline).lineLimit(1)
                if name != nil, let number = call.number {
                    Text(number).font(.callout).foregroundStyle(.secondary)
                }
                if let route {
                    Text(route).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(minWidth: 150, alignment: .leading)
            VStack(spacing: 6) {
                Button("Answer", action: answer)
                    .buttonStyle(PopupButtonStyle(fill: .green))
                Button("Ignore", action: dismiss)
                    .buttonStyle(PopupButtonStyle(fill: nil))
            }
            .fixedSize()
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        .padding(1)
    }
}

/// Draws its own background: the panel never becomes active, and macOS greys
/// out the system button styles in an inactive window.
private struct PopupButtonStyle: ButtonStyle {
    /// nil: neutral.
    let fill: Color?

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(fill == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.white))
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity)
            .background(fill.map(AnyShapeStyle.init) ?? AnyShapeStyle(.quaternary), in: shape)
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}
