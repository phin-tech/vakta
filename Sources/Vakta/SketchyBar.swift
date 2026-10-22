//
//  SketchyBar.swift
//  Vakta
//
//  Pure decisions for Vakta's SketchyBar item: what it shows (herdr.sh
//  style -- `!waiting ✓done working`, icon coloured by the most urgent
//  state), the `sketchybar` argv that draws or removes it, when to resend,
//  and where the session menu opens under the bar when the item is clicked
//  (`vakta://menu`).
//

import CoreGraphics
import Foundation

struct SketchyBarItemAppearance: Equatable {
    /// SketchyBar's `0xAARRGGBB`.
    var iconColor: String
    /// Nil hides the label (`label.drawing=off`).
    var label: String?
}

enum SketchyBarItemPlanner {
    static let attentionColor = "0xfff7768e"
    static let doneColor = "0xff9ece6a"
    static let workingColor = "0xffe0af68"
    static let idleColor = "0x66ffffff"

    static func appearance(for statuses: [AgentStatus]) -> SketchyBarItemAppearance {
        let waiting = statuses.filter { $0 == .attention }.count
        let done = statuses.filter { $0 == .done }.count
        let working = statuses.filter { $0 == .working }.count

        var parts: [String] = []
        if waiting > 0 { parts.append("!\(waiting)") }
        if done > 0 { parts.append("✓\(done)") }
        if working > 0 { parts.append("\(working)") }

        let color: String
        if waiting > 0 {
            color = attentionColor
        } else if done > 0 {
            color = doneColor
        } else if working > 0 {
            color = workingColor
        } else {
            color = idleColor
        }
        return SketchyBarItemAppearance(iconColor: color, label: parts.isEmpty ? nil : parts.joined(separator: " "))
    }
}

enum SketchyBarCommand {
    static let itemName = "vakta"
    /// nf-md-console.
    static let icon = "\u{F018D}"
    static let clickScript = "open -g vakta://menu"
    static let queryBarArguments = ["--query", "bar"]

    /// `--add` on an existing item is a no-op that exits 0, so one command
    /// both creates the item and updates it.
    static func publishArguments(_ appearance: SketchyBarItemAppearance) -> [String] {
        [
            "--add", "item", itemName, "right",
            "--set", itemName,
            "icon=\(icon)",
            "icon.color=\(appearance.iconColor)",
            "label=\(appearance.label ?? "")",
            "label.drawing=\(appearance.label == nil ? "off" : "on")",
            "click_script=\(clickScript)",
        ]
    }

    static let removeArguments = ["--remove", itemName]
}

/// What Vakta last sent to SketchyBar.
struct SketchyBarSyncState: Equatable {
    var shown: SketchyBarItemAppearance?
    var sentAt: Date?
}

enum SketchyBarSyncAction: Equatable {
    case none
    case publish(SketchyBarItemAppearance)
    case remove
}

enum SketchyBarSyncPlanner {
    /// An unchanged item is resent after this long, so it comes back after a
    /// `sketchybar --reload` drops it.
    static let reassertInterval: TimeInterval = 60

    static func action(
        _ state: SketchyBarSyncState, enabled: Bool, desired: SketchyBarItemAppearance, at date: Date
    ) -> SketchyBarSyncAction {
        guard enabled else { return state.shown == nil ? .none : .remove }
        guard state.shown == desired, let sentAt = state.sentAt else { return .publish(desired) }
        return date >= sentAt.addingTimeInterval(reassertInterval) ? .publish(desired) : .none
    }
}

enum SketchyBarBarPosition: Equatable {
    case top
    case bottom
}

/// The parts of `sketchybar --query bar` that place the menu.
struct SketchyBarGeometry: Equatable {
    var position: SketchyBarBarPosition
    var height: CGFloat
    var yOffset: CGFloat

    static func parse(_ json: String) -> SketchyBarGeometry? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let height = (object["height"] as? NSNumber)?.doubleValue, height.isFinite, height > 0
        else { return nil }
        let yOffset = (object["y_offset"] as? NSNumber)?.doubleValue ?? 0
        return SketchyBarGeometry(
            position: (object["position"] as? String) == "bottom" ? .bottom : .top,
            height: CGFloat(height),
            yOffset: yOffset.isFinite ? CGFloat(yOffset) : 0
        )
    }
}

enum SketchyBarMenuPlacement {
    /// Height assumed when the bar can't be queried.
    static let fallbackBarHeight: CGFloat = 32

    /// The menu's top-left in screen coordinates: at the pointer's x, just
    /// clear of the bar.
    static func origin(mouseX: CGFloat, screenFrame: CGRect, bar: SketchyBarGeometry?) -> CGPoint {
        let bar = bar ?? SketchyBarGeometry(position: .top, height: fallbackBarHeight, yOffset: 0)
        switch bar.position {
        case .top: return CGPoint(x: mouseX, y: screenFrame.maxY - bar.yOffset - bar.height)
        case .bottom: return CGPoint(x: mouseX, y: screenFrame.minY + bar.yOffset + bar.height)
        }
    }
}

enum SketchyBarLocator {
    static let candidates = ["/opt/homebrew/bin/sketchybar", "/usr/local/bin/sketchybar"]

    static func executable(candidates: [String], isExecutable: (String) -> Bool) -> String? {
        candidates.first(where: isExecutable)
    }
}

enum VaktaURLCommand: Equatable {
    case showMenu
}

enum VaktaURLRouter {
    static let scheme = "vakta"

    static func command(for url: URL) -> VaktaURLCommand? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        switch url.host?.lowercased() {
        case "menu": return .showMenu
        default: return nil
        }
    }
}
