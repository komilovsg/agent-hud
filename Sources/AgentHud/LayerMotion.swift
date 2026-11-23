import AppKit
import QuartzCore
import SwiftUI

/// Endless animations via Core Animation. They are computed by the system render server,
/// not by SwiftUI in our process (SwiftUI would tick 120 times a second and eat CPU).
enum LayerMotionKind: Hashable {
    case none
    /// Swaying while the agent works: endless, the phase is continuous (see MotionClock).
    case sway(amplitude: CGFloat, duration: Double, delay: Double)
    /// Bouncing when the agent is waiting for you: a short burst of attention, then calm.
    case bounce(amplitude: CGFloat, duration: Double, delay: Double)
    /// Pulse of the "!" badge: a few flashes, then the badge simply stays lit.
    case pulse
}

/// Shared animation clock and the re-attach counter (for --uitest).
enum MotionClock {
    /// Reference point of the sway phase: an animation attached anew continues from the same phase - without a jerk.
    static let epoch = CACurrentMediaTime()
    /// How many times an animation was attached to a layer. Grows only when the kind of motion changes
    /// (or if AppKit itself removed the animation), not on every layout.
    static var installs = 0
    /// How many repeats the attention burst makes (bounce, pulse).
    static let bounceRepeats: Float = 4      // ≈ 2.6 s at 0.32 s there and back
    static let pulseRepeats: Float = 3       // ≈ 5 s
}

struct LayerMotion<Content: View>: NSViewRepresentable {
    let kind: LayerMotionKind
    let content: Content

    init(_ kind: LayerMotionKind, @ViewBuilder content: () -> Content) {
        self.kind = kind
        self.content = content()
    }

    func makeNSView(context: Context) -> MotionHostView<Content> {
        MotionHostView(rootView: content)
    }

    func updateNSView(_ v: MotionHostView<Content>, context: Context) {
        v.host.rootView = content
        v.apply(kind)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MotionHostView<Content>, context: Context) -> CGSize? {
        nsView.host.fittingSize
    }
}

final class MotionHostView<Content: View>: NSView {
    let host: NSHostingView<Content>
    private var current: LayerMotionKind = .none

    init(rootView: Content) {
        host = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        host.wantsLayer = true
        host.layer?.masksToBounds = false
        host.autoresizingMask = [.width, .height]
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        host.frame = bounds
        // Previously the animation was removed and re-attached on EVERY layout. Layout runs on every frame of
        // any window animation (a session appeared, a window opened) - the icons jerked and "stuck".
        // Now we re-attach only if AppKit itself removed the animation from the layer.
        ensureInstalled()
    }

    /// Clicks pass through to the SwiftUI button outside.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ kind: LayerMotionKind) {
        guard kind != current else { ensureInstalled(); return }
        current = kind
        install()
    }

    private func ensureInstalled() {
        guard current != .none, let layer = host.layer, layer.animation(forKey: "motion") == nil else { return }
        // An attention burst that has already played stays on the layer (isRemovedOnCompletion = false),
        // so we get here only if the layer really lost the animation.
        install()
    }

    private func install() {
        guard let layer = host.layer else { return }
        layer.removeAnimation(forKey: "motion")
        switch current {
        case .none:
            return
        case .sway(let amp, let dur, let delay):
            let a = loop("transform.translation.y", to: amp, dur: dur, timing: .easeInEaseOut)
            // Phase from the shared clock: re-attaching doesn't reset the sway to zero.
            a.beginTime = layer.convertTime(MotionClock.epoch + delay, from: nil)
            layer.add(a, forKey: "motion")
        case .bounce(let amp, let dur, let delay):
            let g = CAAnimationGroup()
            g.animations = [
                loop("transform.translation.y", to: amp, dur: dur, timing: .easeOut),
                loop("transform.scale.y", to: 0.05, dur: dur, timing: .easeOut),
            ]
            g.duration = dur
            g.autoreverses = true
            g.repeatCount = MotionClock.bounceRepeats
            g.beginTime = layer.convertTime(CACurrentMediaTime() + delay * 0.3, from: nil)
            g.fillMode = .forwards
            g.isRemovedOnCompletion = false
            layer.add(g, forKey: "motion")
        case .pulse:
            let a = CABasicAnimation(keyPath: "opacity")
            a.fromValue = 1
            a.toValue = 0.55
            a.duration = 0.8
            a.autoreverses = true
            a.repeatCount = MotionClock.pulseRepeats
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            layer.add(a, forKey: "motion")
        }
        MotionClock.installs += 1
    }

    /// Additive there-and-back animation: on top of the original value, the layer model is untouched.
    private func loop(_ path: String, to: CGFloat, dur: Double, timing: CAMediaTimingFunctionName) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: path)
        a.isAdditive = true
        a.fromValue = 0
        a.toValue = to
        a.duration = dur
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = CAMediaTimingFunction(name: timing)
        a.isRemovedOnCompletion = false
        return a
    }
}
