//
//  RightSidebarRail.swift
//  Vakta
//
//  The right sidebar's collapsed icon rail: one icon per available Panel
//  View, in link order, decorated with that Extension's own Status Item
//  (the same push-based data `status/set` already delivers -- see
//  `ExtensionStatusItems.swift`) as a short badge. Reusing that data means an
//  Extension's rail icon stays live while collapsed without a second
//  protocol message.
//

import VaktaExtensionKit

struct RightSidebarRailIcon: Equatable, Identifiable {
    var ref: PanelViewRef
    var symbol: String
    var title: String
    var badgeText: String?
    var tint: StatusSegment.Tint?
    var isActive: Bool
    var id: PanelViewRef { ref }
}

enum RightSidebarRail {
    static let maxBadgeLength = 4

    /// One icon per `options`, in order, paired with its Extension's first
    /// Status Item segment if it has one. `activeMode` marks the icon of the
    /// Panel View currently showing (nothing is active in Files/Changes).
    static func icons(options: [PanelViewOption], statusItems: [StatusBarExtensionItem], activeMode: FileSidebarMode) -> [RightSidebarRailIcon] {
        let statusByExtension = Dictionary(uniqueKeysWithValues: statusItems.map { ($0.extensionID, $0) })
        return options.map { option in
            let segment = statusByExtension[option.ref.extensionID]?.segments.first
            return RightSidebarRailIcon(
                ref: option.ref,
                symbol: option.symbol,
                title: option.title,
                badgeText: segment.map { ExtensionStatusItems.truncate($0.text, to: maxBadgeLength) },
                tint: segment?.tint,
                isActive: activeMode == .extensionView(option.ref)
            )
        }
    }
}
