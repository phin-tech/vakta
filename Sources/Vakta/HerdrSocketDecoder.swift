//
//  HerdrSocketDecoder.swift
//  Vakta
//
//  Decodes one newline-delimited JSON line from herdr's socket API into the
//  minimal signal `HerdrEventStreamClient` needs: did the subscription
//  start, did something pane-relevant happen (so the caller should trigger
//  an early poll), or neither. Deliberately does not fully decode every
//  response/event shape -- see docs/herdr-events-plan.md's design pivot:
//  this client never carries status data itself.

import Foundation

enum HerdrSocketDecoder {
    enum Frame: Equatable {
        case subscriptionAck
        /// One of the trigger-worthy pane events fired. `paneID` is `nil`
        /// for the session-wide event types (`pane.created`/`pane.closed`/
        /// `pane.agent_detected`, which herdr's schema requires no `pane_id`
        /// filter for) when the payload happens not to include one.
        case paneEvent(paneID: String?)
        /// A response/event this client doesn't act on (ping/pong, an
        /// unrelated event type, an error response).
        case other
        /// Invalid JSON, or valid JSON that matches none of the known frame
        /// shapes -- a signal to log and reconnect.
        case malformed
    }

    /// The pane events `HerdrEventStreamClient` subscribes to -- session-wide
    /// lifecycle events plus per-pane status changes (see the plan doc).
    private static let triggerEventTypes: Set<String> = [
        "pane.created", "pane.closed", "pane.agent_detected", "pane.agent_status_changed",
    ]

    static func decode(line: String) -> Frame {
        guard !line.isEmpty, let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .malformed }

        if let event = object["event"] as? String {
            guard triggerEventTypes.contains(event) else { return .other }
            let paneID = (object["data"] as? [String: Any])?["pane_id"] as? String
            return .paneEvent(paneID: paneID)
        }

        if let result = object["result"] as? [String: Any] {
            return (result["type"] as? String) == "subscription_started" ? .subscriptionAck : .other
        }

        if object["error"] != nil {
            return .other
        }

        return .malformed
    }

    /// Splits accumulated socket bytes into complete newline-terminated
    /// lines plus whatever incomplete tail remains to keep buffering -- a
    /// `recv` can split one frame across two reads, or deliver several in
    /// one. Empty lines (a lone `\n`) are dropped rather than passed to
    /// `decode`, matching every real frame observed being non-empty.
    static func extractLines(from buffer: Data) -> (lines: [String], remainder: Data) {
        let newline = UInt8(ascii: "\n")
        var lines: [String] = []
        var searchStart = buffer.startIndex
        while let newlineIndex = buffer[searchStart...].firstIndex(of: newline) {
            let lineData = buffer[searchStart..<newlineIndex]
            if !lineData.isEmpty, let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
            searchStart = buffer.index(after: newlineIndex)
        }
        return (lines, buffer[searchStart...])
    }
}
