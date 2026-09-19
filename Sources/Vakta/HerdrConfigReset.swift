//
//  HerdrConfigReset.swift
//  Vakta
//
//  Pure bulk "reset to defaults" for the herdr config editor: removes catalog
//  keys from the document so herdr falls back to its own defaults. Keys the
//  catalog doesn't know, comments, and `[[keys.command]]` blocks are untouched.
//  Runs through the store like any edit, so it stays unsaved (and gated by
//  `herdr config check`) until the user saves. Deliberately does not use
//  `herdr config reset-keys`, which writes the file directly.

import Foundation

enum HerdrConfigReset {
    static func settings(in document: HerdrConfigDocument, group: HerdrConfigGroup?) -> HerdrConfigDocument {
        setSettingPaths(in: document, group: group).reduce(document) { $0.unsetting($1) }
    }

    static func keys(in document: HerdrConfigDocument, group: HerdrKeyGroup?) -> HerdrConfigDocument {
        setKeyPaths(in: document, group: group).reduce(document) { $0.unsetting($1) }
    }

    /// Catalog paths (optionally within one group) that the file currently sets.
    static func setSettingPaths(in document: HerdrConfigDocument, group: HerdrConfigGroup?) -> [String] {
        HerdrConfigCatalog.entries
            .filter { group == nil || $0.group == group }
            .map(\.path)
            .filter { document.value(at: $0) != nil }
    }

    static func setKeyPaths(in document: HerdrConfigDocument, group: HerdrKeyGroup?) -> [String] {
        HerdrKeyActionCatalog.actions
            .filter { group == nil || $0.group == group }
            .map(\.path)
            .filter { document.value(at: $0) != nil }
    }
}
