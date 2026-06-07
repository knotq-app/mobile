import SwiftUI

// Component declarations were split into focused files to keep modules small.

// MARK: - Onboarding spotlight targets

/// A live UI element the onboarding tour can spotlight. Controls tag themselves
/// with `.onboardingTarget(_:)`; the overlay resolves their on-screen frames
/// through an anchor preference, mirroring the desktop spotlight walkthrough
/// instead of showing static walls of text.
///
/// Each case rings the *content of the navigated pane* — the tour switches to the
/// real Calendar / Scheme / Daily view (like desktop) and the spotlight hugs what's
/// now on screen, rather than pointing at Home-screen entry points.
enum OnboardingTarget: Hashable {
    case calendar
    case scheme
    case daily
    case upcoming
}

struct OnboardingAnchorKey: PreferenceKey {
    static let defaultValue: [OnboardingTarget: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [OnboardingTarget: Anchor<CGRect>],
        nextValue: () -> [OnboardingTarget: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    /// Marks this view as a spotlight target so the onboarding tour can ring it.
    func onboardingTarget(_ target: OnboardingTarget) -> some View {
        anchorPreference(key: OnboardingAnchorKey.self, value: .bounds) { [target: $0] }
    }
}

enum OnboardingPhase {
    case account
    case guide
}

// MARK: - Tour steps

private struct OnboardingStep {
    let title: String
    let body: String
    /// The control to spotlight, or `nil` for a centered intro card.
    let target: OnboardingTarget?
    /// The pane to switch to so the highlighted control matches what's behind it.
    let focusPane: MobilePane?
}

// Mirrors the desktop spotlight walkthrough — same concepts, same order. Each step
// navigates into the real pane (like desktop) so the spotlight rings live content;
// Upcoming lives on Home on mobile, so it stays there.
private let onboardingSteps: [OnboardingStep] = [
    OnboardingStep(
        title: "Welcome to KnotQ",
        body: "KnotQ is a single app for calendar events, reminders, assignments, and general notes. It aims to be simple yet functional.",
        target: nil,
        focusPane: .home
    ),
    OnboardingStep(
        title: "Calendar",
        body: "Your calendar holds events, assignments, and reminders. Tap to add a reminder, long-press for an assignment, or drag to block out an event.",
        target: .calendar,
        focusPane: .calendar
    ),
    OnboardingStep(
        title: "Schemes",
        body: "Schemes are editable outlines for projects, notes, and plans. Add start and end times to any line to turn it into a calendar item.",
        target: .scheme,
        focusPane: .scheme
    ),
    OnboardingStep(
        title: "Daily",
        body: "Daily is a special, default scheme. Write an optimistic task list each day and check off the ones you complete.",
        target: .daily,
        focusPane: .daily
    ),
    OnboardingStep(
        title: "Upcoming",
        body: "Upcoming gathers nearby events, assignments, and reminders. You can mark tasks complete right from here.",
        target: .upcoming,
        focusPane: .home
    )
]

// MARK: - Spotlight overlay

struct OnboardingOverlay: View {
    @EnvironmentObject private var model: AppModel
    let theme: KnotQTheme
    let size: CGSize
    /// Resolves a target into its on-screen rect (in the overlay's coordinate
    /// space), or `nil` when the control isn't currently on screen.
    let resolve: (OnboardingTarget) -> CGRect?
    @Binding var phase: OnboardingPhase
    @Binding var step: Int
    let onFocus: (MobilePane?) -> Void
    let onComplete: () -> Void

    var body: some View {
        ZStack {
            switch phase {
            case .account:
                accountPhase
            case .guide:
                guidePhase
            }
        }
        .foregroundStyle(theme.textPrimary)
        .tint(theme.accent)
    }

    /// Sign-in happens in the browser; advance to the guide once a session lands.
    private func authenticate(mode: SyncAuthMode) {
        Task {
            await model.beginBrowserSignIn(mode: mode)
            if model.syncSession != nil {
                beginGuide()
            }
        }
    }

    // MARK: Account phase

    private var accountPhase: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {} // swallow taps to the app behind the scrim

            accountCard
                .frame(maxWidth: 460)
                .padding(.horizontal, 24)
        }
    }

    private var accountCard: some View {
        VStack(spacing: 18) {
            Image("BrandLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)

            VStack(spacing: 6) {
                Text("KnotQ")
                    .font(.system(size: 30, weight: .bold))
                Text("Local-first planning with optional sync.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.textSoft)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 10) {
                onboardingAction(
                    title: "Create Sync Account",
                    detail: "Sign up in your browser and sync across devices.",
                    icon: "person.crop.circle.badge.plus"
                ) {
                    authenticate(mode: .createAccount)
                }

                onboardingAction(
                    title: "Sign In",
                    detail: "Connect an existing KnotQ account in your browser.",
                    icon: "person.crop.circle"
                ) {
                    authenticate(mode: .signIn)
                }

                Button {
                    beginGuide()
                } label: {
                    Label("Local for Now", systemImage: "internaldrive")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                }
                .buttonStyle(.bordered)
                .disabled(model.syncAuthInProgress)
            }

            Text("You can add or remove sync later from Settings.")
                .font(.footnote)
                .foregroundStyle(theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .background(theme.bgModal, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.borderOverlay.opacity(0.7), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 22, y: 10)
    }

    private func onboardingAction(
        title: String,
        detail: String,
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(theme.accent)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                    Text(detail)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textMuted)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.textDim)
            }
            .padding(12)
            .background(theme.bgApp, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.borderOverlay.opacity(0.7), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Guide phase (spotlight)

    private var guidePhase: some View {
        let current = onboardingSteps[min(step, onboardingSteps.count - 1)]
        let targetRect = current.target.flatMap(resolve)
        return ZStack {
            spotlightScrim(targetRect: targetRect)
            if let rect = targetRect {
                highlightRing(rect)
            }
            tooltip(current, targetRect: targetRect)
        }
        .ignoresSafeArea()
    }

    private func spotlightScrim(targetRect: CGRect?) -> some View {
        Color.black.opacity(0.62)
            .reverseMask {
                if let rect = padded(targetRect) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {} // the tour is driven by Back / Next / Skip
    }

    private func highlightRing(_ rect: CGRect) -> some View {
        let r = padded(rect) ?? rect
        return RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(theme.accent, lineWidth: 2.5)
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
    }

    private func padded(_ rect: CGRect?) -> CGRect? {
        rect.map { $0.insetBy(dx: -7, dy: -7) }
    }

    @ViewBuilder
    private func tooltip(_ current: OnboardingStep, targetRect: CGRect?) -> some View {
        if let rect = targetRect {
            if rect.midY < size.height * 0.5 {
                // Target sits high: drop the card just below it.
                VStack(spacing: 0) {
                    Spacer().frame(height: min(rect.maxY + 16, size.height - 200))
                    tooltipCard(current)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
            } else {
                // Target sits low: float the card above it.
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    tooltipCard(current)
                    Spacer().frame(height: max(20, size.height - rect.minY + 16))
                }
                .padding(.horizontal, 16)
            }
        } else {
            tooltipCard(current)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, 16)
        }
    }

    private func tooltipCard(_ current: OnboardingStep) -> some View {
        let isLast = step >= onboardingSteps.count - 1
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                ForEach(onboardingSteps.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? theme.accent : theme.borderOverlay.opacity(0.5))
                        .frame(width: index == step ? 22 : 6, height: 6)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(current.title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                Text(current.body)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.textSoft)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }

            HStack(spacing: 10) {
                if step > 0 {
                    Button {
                        goBack()
                    } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.bordered)
                }

                Button("Skip") {
                    onComplete()
                }
                .font(.system(size: 14, weight: .medium))
                .buttonStyle(.plain)
                .foregroundStyle(theme.textMuted)

                Spacer(minLength: 0)

                Button {
                    advance()
                } label: {
                    Text(isLast ? "Done" : "Next")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 18)
                        .frame(height: 40)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: min(330, size.width - 32))
        .background(theme.bgModal, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(theme.borderOverlay.opacity(0.7), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.3), radius: 18, y: 8)
    }

    // MARK: Navigation

    private func beginGuide() {
        onFocus(onboardingSteps[0].focusPane)
        withAnimation(.snappy(duration: 0.24)) {
            step = 0
            phase = .guide
        }
    }

    private func advance() {
        if step >= onboardingSteps.count - 1 {
            onComplete()
            return
        }
        let next = step + 1
        onFocus(onboardingSteps[next].focusPane)
        withAnimation(.snappy(duration: 0.22)) {
            step = next
        }
    }

    private func goBack() {
        guard step > 0 else {
            withAnimation(.snappy(duration: 0.22)) {
                phase = .account
            }
            return
        }
        let previous = step - 1
        onFocus(onboardingSteps[previous].focusPane)
        withAnimation(.snappy(duration: 0.22)) {
            step = previous
        }
    }
}

private extension View {
    /// Punches a hole through `self` shaped by the supplied mask content.
    @ViewBuilder
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .topLeading) {
                    mask().blendMode(.destinationOut)
                }
        }
    }
}
