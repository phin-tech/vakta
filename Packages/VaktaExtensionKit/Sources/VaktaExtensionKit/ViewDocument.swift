//
//  ViewDocument.swift
//  VaktaExtensionKit
//
//  What an Extension sends to describe a Panel View or Popover, and the
//  Effects it returns from a Callback. Vakta draws documents natively and
//  carries out Effects itself; a document never names a program to run.
//  Unknown kinds and types decode to `.unsupported` so a newer Extension
//  degrades on an older host instead of failing the whole message.

import Foundation

public indirect enum ViewDocument: Equatable, Sendable {
    case list(ListView)
    case detail(DetailView)
    case form(FormView)
    case unsupported(kind: String)
}

public struct ListView: Codable, Equatable, Sendable {
    public var title: String?
    public var searchPlaceholder: String?
    public var emptyText: String?
    /// View-level buttons (like "New Issue…"), shown above the sections.
    public var buttons: [ViewButton]
    public var sections: [ListSection]

    public init(
        title: String?, searchPlaceholder: String?, emptyText: String?, buttons: [ViewButton] = [], sections: [ListSection]
    ) {
        self.title = title
        self.searchPlaceholder = searchPlaceholder
        self.emptyText = emptyText
        self.buttons = buttons
        self.sections = sections
    }
}

public struct ListSection: Codable, Equatable, Sendable {
    public var title: String?
    public var items: [ListItem]

    public init(title: String?, items: [ListItem]) {
        self.title = title
        self.items = items
    }
}

public struct ListItem: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String?
    public var symbol: String?
    public var accessories: [Accessory]
    /// Shown when the row is selected.
    public var detail: ViewDocument?
    public var buttons: [ViewButton]

    public init(
        id: String, title: String, subtitle: String?, symbol: String?,
        accessories: [Accessory], detail: ViewDocument?, buttons: [ViewButton]
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.accessories = accessories
        self.detail = detail
        self.buttons = buttons
    }
}

public struct Accessory: Codable, Equatable, Sendable {
    public var text: String
    public var symbol: String?

    public init(text: String, symbol: String?) {
        self.text = text
        self.symbol = symbol
    }
}

public struct DetailView: Codable, Equatable, Sendable {
    public struct Field: Codable, Equatable, Sendable {
        public var label: String
        public var value: String

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    public var title: String
    public var markdown: String?
    public var fields: [Field]
    public var buttons: [ViewButton]

    public init(title: String, markdown: String?, fields: [Field], buttons: [ViewButton]) {
        self.title = title
        self.markdown = markdown
        self.fields = fields
        self.buttons = buttons
    }
}

public struct FormView: Codable, Equatable, Sendable {
    public var title: String
    public var fields: [FormField]
    public var submit: ViewButton

    public init(title: String, fields: [FormField], submit: ViewButton) {
        self.title = title
        self.fields = fields
        self.submit = submit
    }
}

public struct FormField: Equatable, Sendable {
    public struct Option: Codable, Equatable, Sendable {
        public var value: String
        public var label: String

        public init(value: String, label: String) {
            self.value = value
            self.label = label
        }
    }

    public enum Kind: Equatable, Sendable {
        case text(placeholder: String?, value: String?)
        case multiline(placeholder: String?, value: String?)
        case picker(options: [Option], selected: String?)
        case toggle(isOn: Bool)
        case unsupported(kind: String)
    }

    public var id: String
    public var label: String
    public var required: Bool
    public var kind: Kind

    public init(id: String, label: String, required: Bool, kind: Kind) {
        self.id = id
        self.label = label
        self.required = required
        self.kind = kind
    }
}

public struct ViewButton: Equatable, Sendable {
    public enum Style: String, Sendable {
        case `default`, primary, destructive
    }

    public struct Confirm: Codable, Equatable, Sendable {
        public var title: String
        public var message: String?
        public var button: String

        public init(title: String, message: String?, button: String) {
            self.title = title
            self.message = message
            self.button = button
        }
    }

    public var title: String
    public var symbol: String?
    /// The Callback name sent back to the Extension.
    public var callback: String
    public var payload: JSONValue?
    public var style: Style
    public var confirm: Confirm?
    /// Active only while the containing view has focus.
    public var shortcut: String?

    public init(
        title: String, symbol: String?, callback: String, payload: JSONValue?,
        style: Style, confirm: Confirm?, shortcut: String?
    ) {
        self.title = title
        self.symbol = symbol
        self.callback = callback
        self.payload = payload
        self.style = style
        self.confirm = confirm
        self.shortcut = shortcut
    }
}

public indirect enum Effect: Equatable, Sendable {
    case refresh
    case replace(ViewDocument)
    case push(ViewDocument)
    case pop
    case toast(text: String)
    case notify(title: String, body: String?)
    case openURL(String)
    /// `command` is argv, never shell text.
    case openPane(cwd: String?, command: [String], title: String?)
    case openSession(cwd: String?, command: [String], title: String?)
    case unsupported(type: String)
}

// MARK: - Codable
//
// Encoding omits absent optionals and always writes collections, styles and
// `required`, so encoding is deterministic. Decoding treats omitted
// collections as empty: authors write only what they mean.

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

private func discriminator(_ key: String, in decoder: Decoder, for what: String) throws -> String {
    let container = try decoder.container(keyedBy: AnyKey.self)
    guard let value = try container.decodeIfPresent(String.self, forKey: AnyKey(key)) else {
        throw ExtensionProtocolError.payloadMismatch("\(what) without \"\(key)\"")
    }
    return value
}

private func writeDiscriminator(_ key: String, _ value: String, to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: AnyKey.self)
    try container.encode(value, forKey: AnyKey(key))
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let bool): try container.encode(bool)
        case .number(let number):
            // Whole numbers as integers, so `2` stays `2` and decodes as Int.
            if number.rounded() == number, abs(number) < 9_007_199_254_740_992 {
                try container.encode(Int64(number))
            } else {
                try container.encode(number)
            }
        case .string(let string): try container.encode(string)
        case .array(let array): try container.encode(array)
        case .object(let object): try container.encode(object)
        }
    }
}

extension JSONRPCID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let number): try container.encode(number)
        case .string(let string): try container.encode(string)
        }
    }
}

extension ViewDocument: Codable {
    public init(from decoder: Decoder) throws {
        switch try discriminator("kind", in: decoder, for: "View Document") {
        case "list": self = .list(try ListView(from: decoder))
        case "detail": self = .detail(try DetailView(from: decoder))
        case "form": self = .form(try FormView(from: decoder))
        case let kind: self = .unsupported(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .list(let view):
            try view.encode(to: encoder)
            try writeDiscriminator("kind", "list", to: encoder)
        case .detail(let view):
            try view.encode(to: encoder)
            try writeDiscriminator("kind", "detail", to: encoder)
        case .form(let view):
            try view.encode(to: encoder)
            try writeDiscriminator("kind", "form", to: encoder)
        case .unsupported(let kind):
            try writeDiscriminator("kind", kind, to: encoder)
        }
    }
}

extension ListView {
    private enum CodingKeys: String, CodingKey {
        case title, searchPlaceholder, emptyText, buttons, sections
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try container.decodeIfPresent(String.self, forKey: .title),
            searchPlaceholder: try container.decodeIfPresent(String.self, forKey: .searchPlaceholder),
            emptyText: try container.decodeIfPresent(String.self, forKey: .emptyText),
            buttons: try container.decodeIfPresent([ViewButton].self, forKey: .buttons) ?? [],
            sections: try container.decodeIfPresent([ListSection].self, forKey: .sections) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(searchPlaceholder, forKey: .searchPlaceholder)
        try container.encodeIfPresent(emptyText, forKey: .emptyText)
        try container.encode(buttons, forKey: .buttons)
        try container.encode(sections, forKey: .sections)
    }
}

extension ListSection {
    private enum CodingKeys: String, CodingKey {
        case title, items
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try container.decodeIfPresent(String.self, forKey: .title),
            items: try container.decodeIfPresent([ListItem].self, forKey: .items) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(items, forKey: .items)
    }
}

extension ListItem {
    private enum CodingKeys: String, CodingKey {
        case id, title, subtitle, symbol, accessories, detail, buttons
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            subtitle: try container.decodeIfPresent(String.self, forKey: .subtitle),
            symbol: try container.decodeIfPresent(String.self, forKey: .symbol),
            accessories: try container.decodeIfPresent([Accessory].self, forKey: .accessories) ?? [],
            detail: try container.decodeIfPresent(ViewDocument.self, forKey: .detail),
            buttons: try container.decodeIfPresent([ViewButton].self, forKey: .buttons) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encodeIfPresent(symbol, forKey: .symbol)
        try container.encode(accessories, forKey: .accessories)
        try container.encodeIfPresent(detail, forKey: .detail)
        try container.encode(buttons, forKey: .buttons)
    }
}

extension DetailView {
    private enum CodingKeys: String, CodingKey {
        case title, markdown, fields, buttons
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try container.decode(String.self, forKey: .title),
            markdown: try container.decodeIfPresent(String.self, forKey: .markdown),
            fields: try container.decodeIfPresent([Field].self, forKey: .fields) ?? [],
            buttons: try container.decodeIfPresent([ViewButton].self, forKey: .buttons) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(markdown, forKey: .markdown)
        try container.encode(fields, forKey: .fields)
        try container.encode(buttons, forKey: .buttons)
    }
}

extension FormView {
    private enum CodingKeys: String, CodingKey {
        case title, fields, submit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try container.decode(String.self, forKey: .title),
            fields: try container.decodeIfPresent([FormField].self, forKey: .fields) ?? [],
            submit: try container.decode(ViewButton.self, forKey: .submit)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(fields, forKey: .fields)
        try container.encode(submit, forKey: .submit)
    }
}

extension FormField: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, label, required, kind, placeholder, value, options, selected, isOn
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kindName = try discriminator("kind", in: decoder, for: "form field")
        let kind: Kind
        switch kindName {
        case "text":
            kind = .text(
                placeholder: try container.decodeIfPresent(String.self, forKey: .placeholder),
                value: try container.decodeIfPresent(String.self, forKey: .value))
        case "multiline":
            kind = .multiline(
                placeholder: try container.decodeIfPresent(String.self, forKey: .placeholder),
                value: try container.decodeIfPresent(String.self, forKey: .value))
        case "picker":
            kind = .picker(
                options: try container.decodeIfPresent([Option].self, forKey: .options) ?? [],
                selected: try container.decodeIfPresent(String.self, forKey: .selected))
        case "toggle":
            kind = .toggle(isOn: try container.decodeIfPresent(Bool.self, forKey: .isOn) ?? false)
        default:
            kind = .unsupported(kind: kindName)
        }
        self.init(
            id: try container.decode(String.self, forKey: .id),
            label: try container.decode(String.self, forKey: .label),
            required: try container.decodeIfPresent(Bool.self, forKey: .required) ?? false,
            kind: kind
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(label, forKey: .label)
        try container.encode(required, forKey: .required)
        switch kind {
        case let .text(placeholder, value):
            try container.encode("text", forKey: .kind)
            try container.encodeIfPresent(placeholder, forKey: .placeholder)
            try container.encodeIfPresent(value, forKey: .value)
        case let .multiline(placeholder, value):
            try container.encode("multiline", forKey: .kind)
            try container.encodeIfPresent(placeholder, forKey: .placeholder)
            try container.encodeIfPresent(value, forKey: .value)
        case let .picker(options, selected):
            try container.encode("picker", forKey: .kind)
            try container.encode(options, forKey: .options)
            try container.encodeIfPresent(selected, forKey: .selected)
        case let .toggle(isOn):
            try container.encode("toggle", forKey: .kind)
            try container.encode(isOn, forKey: .isOn)
        case let .unsupported(kindName):
            try container.encode(kindName, forKey: .kind)
        }
    }
}

extension ViewButton: Codable {
    private enum CodingKeys: String, CodingKey {
        case title, symbol, callback, payload, style, confirm, shortcut
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let styleName = try container.decodeIfPresent(String.self, forKey: .style)
        self.init(
            title: try container.decode(String.self, forKey: .title),
            symbol: try container.decodeIfPresent(String.self, forKey: .symbol),
            callback: try container.decode(String.self, forKey: .callback),
            payload: try container.decodeIfPresent(JSONValue.self, forKey: .payload),
            style: styleName.flatMap(Style.init(rawValue:)) ?? .default,
            confirm: try container.decodeIfPresent(Confirm.self, forKey: .confirm),
            shortcut: try container.decodeIfPresent(String.self, forKey: .shortcut)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(symbol, forKey: .symbol)
        try container.encode(callback, forKey: .callback)
        try container.encodeIfPresent(payload, forKey: .payload)
        try container.encode(style.rawValue, forKey: .style)
        try container.encodeIfPresent(confirm, forKey: .confirm)
        try container.encodeIfPresent(shortcut, forKey: .shortcut)
    }
}

extension Effect: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, document, text, title, body, url, cwd, command
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try discriminator("type", in: decoder, for: "Effect") {
        case "refresh": self = .refresh
        case "replace": self = .replace(try container.decode(ViewDocument.self, forKey: .document))
        case "push": self = .push(try container.decode(ViewDocument.self, forKey: .document))
        case "pop": self = .pop
        case "toast": self = .toast(text: try container.decode(String.self, forKey: .text))
        case "notify":
            self = .notify(
                title: try container.decode(String.self, forKey: .title),
                body: try container.decodeIfPresent(String.self, forKey: .body))
        case "open_url": self = .openURL(try container.decode(String.self, forKey: .url))
        case "open_pane":
            self = .openPane(
                cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
                command: try Self.command(in: container),
                title: try container.decodeIfPresent(String.self, forKey: .title))
        case "open_session":
            self = .openSession(
                cwd: try container.decodeIfPresent(String.self, forKey: .cwd),
                command: try Self.command(in: container),
                title: try container.decodeIfPresent(String.self, forKey: .title))
        case let type: self = .unsupported(type: type)
        }
    }

    private static func command(in container: KeyedDecodingContainer<CodingKeys>) throws -> [String] {
        guard let command = try container.decodeIfPresent([String].self, forKey: .command), !command.isEmpty else {
            throw ExtensionProtocolError.payloadMismatch("Effect without a non-empty \"command\"")
        }
        return command
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .refresh:
            try container.encode("refresh", forKey: .type)
        case .replace(let document):
            try container.encode("replace", forKey: .type)
            try container.encode(document, forKey: .document)
        case .push(let document):
            try container.encode("push", forKey: .type)
            try container.encode(document, forKey: .document)
        case .pop:
            try container.encode("pop", forKey: .type)
        case .toast(let text):
            try container.encode("toast", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .notify(title, body):
            try container.encode("notify", forKey: .type)
            try container.encode(title, forKey: .title)
            try container.encodeIfPresent(body, forKey: .body)
        case .openURL(let url):
            try container.encode("open_url", forKey: .type)
            try container.encode(url, forKey: .url)
        case let .openPane(cwd, command, title):
            try container.encode("open_pane", forKey: .type)
            try container.encodeIfPresent(cwd, forKey: .cwd)
            try container.encode(command, forKey: .command)
            try container.encodeIfPresent(title, forKey: .title)
        case let .openSession(cwd, command, title):
            try container.encode("open_session", forKey: .type)
            try container.encodeIfPresent(cwd, forKey: .cwd)
            try container.encode(command, forKey: .command)
            try container.encodeIfPresent(title, forKey: .title)
        case .unsupported(let type):
            try container.encode(type, forKey: .type)
        }
    }
}

extension StatusSegment: Codable {
    private enum CodingKeys: String, CodingKey {
        case text, symbol, tint, help, action, url, popover, attention
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            text: try container.decode(String.self, forKey: .text),
            symbol: try container.decodeIfPresent(String.self, forKey: .symbol),
            tint: (try container.decodeIfPresent(String.self, forKey: .tint)).flatMap(Tint.init(rawValue:)) ?? .neutral,
            help: try container.decodeIfPresent(String.self, forKey: .help),
            action: try container.decodeIfPresent(ViewButton.self, forKey: .action),
            url: try container.decodeIfPresent(String.self, forKey: .url),
            popover: try container.decodeIfPresent(ViewDocument.self, forKey: .popover),
            attention: try container.decodeIfPresent(Bool.self, forKey: .attention) ?? false
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(symbol, forKey: .symbol)
        try container.encode(tint.rawValue, forKey: .tint)
        try container.encodeIfPresent(help, forKey: .help)
        try container.encodeIfPresent(action, forKey: .action)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(popover, forKey: .popover)
        try container.encode(attention, forKey: .attention)
    }
}

extension StatusSetParams: Codable {
    private enum CodingKeys: String, CodingKey {
        case placement, segments, text, symbol, popover
    }

    /// Accepts the original single-text shape (`text`, `symbol`, `popover`)
    /// as one neutral trailing segment.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let placement = (try container.decodeIfPresent(String.self, forKey: .placement)).flatMap(Placement.init(rawValue:)) ?? .trailing
        if let segments = try container.decodeIfPresent([StatusSegment].self, forKey: .segments) {
            self.init(placement: placement, segments: segments)
        } else {
            self.init(placement: placement, segments: [StatusSegment(
                text: try container.decode(String.self, forKey: .text),
                symbol: try container.decodeIfPresent(String.self, forKey: .symbol),
                popover: try container.decodeIfPresent(ViewDocument.self, forKey: .popover)
            )])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(placement.rawValue, forKey: .placement)
        try container.encode(segments, forKey: .segments)
    }
}

extension BadgeSetParams: Codable {
    private enum CodingKeys: String, CodingKey {
        case sessionKey, text, symbol, tint, popover
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            sessionKey: try container.decode(SessionKey.self, forKey: .sessionKey),
            text: try container.decode(String.self, forKey: .text),
            symbol: try container.decodeIfPresent(String.self, forKey: .symbol),
            tint: (try container.decodeIfPresent(String.self, forKey: .tint)).flatMap(StatusSegment.Tint.init(rawValue:)) ?? .neutral,
            popover: try container.decodeIfPresent(ViewDocument.self, forKey: .popover)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sessionKey, forKey: .sessionKey)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(symbol, forKey: .symbol)
        try container.encode(tint.rawValue, forKey: .tint)
        try container.encodeIfPresent(popover, forKey: .popover)
    }
}
