//
//  AttentionTransitionPolicy.swift
//  Vakta
//
//  Pure decision for what handling one session's agent-status transition
//  should cause -- no `UNUserNotificationCenter`/`NSApp` calls. Previously
//  this decision lived inline in `AttentionNotifier.handleTransition`,
//  interleaved with the actual OS delivery calls, making the policy itself
//  (which transitions notify, which are silenced) untestable without a real
//  notification center and app bundle.

import Foundation

/// What one transition should cause. `bannerBody`/`playSound` are only
/// meaningful when `shouldBanner` is true.
struct AttentionDecision: Equatable {
    var shouldBanner: Bool
    var bannerBody: String?
    var playSound: Bool
    var shouldBounceDock: Bool

    static let silent = AttentionDecision(shouldBanner: false, bannerBody: nil, playSound: false, shouldBounceDock: false)
}

enum AttentionTransitionPolicy {
    /// - First observation (`from == nil`): silent. On launch Vakta
    ///   reattaches to still-running sessions whose agents may already be
    ///   waiting; notifying then would spam a banner per reattached agent
    ///   for state the user didn't just cause.
    /// - The session the user is already looking at (`isSelected &&
    ///   appActive`): silent -- there is nothing to alert them to.
    /// - `to == .attention` from anything else: the "needs attention" event,
    ///   gated independently by `notifyOnAttention` (banner) and
    ///   `bounceDock` (Dock). Repeated identical observations (`from ==
    ///   .attention` already) don't re-fire, since there's no transition.
    /// - `to == .done` from `.working` specifically: the "finished" event --
    ///   tied to herdr's own real completion signal (`AgentStatus.init(herdr:)`
    ///   maps "done"/"complete" to `.done`, distinct from plain `.idle`
    ///   ("idle"/"ready": never ran, or reset), so a working agent merely
    ///   going idle -- without herdr itself reporting completion -- is not
    ///   treated as "finished"). Also not tied to merely no-longer-being
    ///   `.attention` (an `.attention -> .done` transition, e.g. the user
    ///   answered a prompt and the agent then finished without ever
    ///   "working" again by herdr's own accounting, is not treated as a
    ///   completion either).
    /// - Anything else (e.g. `.idle -> .working`, `.working -> .idle`,
    ///   unknown/malformed-status transitions that `AgentStatus.init(herdr:)`
    ///   already normalized upstream): silent.
    static func decide(
        from: AgentStatus?,
        to: AgentStatus,
        isSelected: Bool,
        appActive: Bool,
        notifyOnAttention: Bool,
        notifyOnFinished: Bool,
        bounceDock: Bool
    ) -> AttentionDecision {
        guard let from else { return .silent }
        let alreadyFocused = isSelected && appActive

        if to == .attention, from != .attention {
            guard !alreadyFocused else { return .silent }
            return AttentionDecision(
                shouldBanner: notifyOnAttention,
                bannerBody: notifyOnAttention ? "Needs your attention" : nil,
                playSound: notifyOnAttention,
                shouldBounceDock: bounceDock
            )
        }

        if to == .done, from == .working {
            guard notifyOnFinished, !alreadyFocused else { return .silent }
            return AttentionDecision(
                shouldBanner: true,
                bannerBody: "Agent finished",
                playSound: false,
                shouldBounceDock: false
            )
        }

        return .silent
    }
}
