//
//  PaneFocus.swift
//  Vakta
//
//  Backend-neutral pane focus shell. tmux needs an explicit window switch
//  before selecting a pane; Herdr exposes exact pane focus through its socket
//  API rather than its directional CLI command.

import Foundation
import Network

/// Builds the newline-delimited JSON request used by Herdr's socket API.
enum HerdrPaneFocusRequest {
    static func line(requestID: String, paneID: String) -> String {
        let request: [String: Any] = [
            "id": requestID,
            "method": "pane.focus",
            "params": ["pane_id": paneID],
        ]
        let data = (try? JSONSerialization.data(withJSONObject: request)) ?? Data("{}".utf8)
        return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
    }
}

/// Performs the observable focus operation for a selected pane.
enum PaneFocus {
    static func focus(
        sessionName: String,
        target: MultiplexerTarget,
        workspaceID: String,
        paneID: String,
        path: String,
        configDirectory: URL = HerdrSocketPath.defaultConfigDirectory(),
        isCancelled: @escaping () -> Bool = { false }
    ) -> Bool {
        guard !isCancelled() else { return false }

        switch target.backend {
        case .tmux:
            guard WorkspaceFocus.focus(
                sessionName: sessionName,
                target: target,
                workspaceID: workspaceID,
                path: path,
                isCancelled: isCancelled
            ) else { return false }
            guard let argv = target.paneFocusArgv(
                sessionName: sessionName,
                workspaceID: workspaceID,
                paneID: paneID
            ) else { return false }
            return ProcessRunner.run(
                argv,
                path: path,
                environment: target.environment,
                isCancelled: isCancelled
            ) != nil

        case .herdr:
            let socketPath = HerdrSocketPath.resolve(
                sessionName: sessionName,
                configDirectory: configDirectory
            )
            return HerdrPaneFocus.focus(
                socketPath: socketPath,
                paneID: paneID,
                isCancelled: isCancelled
            )
        }
    }
}

private enum HerdrPaneFocus {
    static func focus(
        socketPath: URL,
        paneID: String,
        timeout: TimeInterval = 3,
        isCancelled: @escaping () -> Bool = { false }
    ) -> Bool {
        let requestID = "vakta_focus_\(UUID().uuidString)"
        let request = HerdrPaneFocusRequest.line(requestID: requestID, paneID: paneID)
        let endpoint = NWEndpoint.unix(path: socketPath.path)
        let connection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "Vakta.HerdrPaneFocus")
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var completed = false
        var succeeded = false

        func complete(_ result: Bool) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            succeeded = result
            lock.unlock()
            semaphore.signal()
        }

        var buffer = Data()
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    buffer.append(data)
                    let (lines, remainder) = HerdrSocketDecoder.extractLines(from: buffer)
                    buffer = remainder
                    for line in lines {
                        guard let responseData = line.data(using: .utf8),
                              let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                              response["id"] as? String == requestID
                        else { continue }
                        complete(response["error"] == nil)
                        return
                    }
                }

                if isComplete || error != nil {
                    complete(false)
                } else {
                    receive()
                }
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard let data = request.data(using: .utf8) else {
                    complete(false)
                    return
                }
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        _ = error
                        complete(false)
                    } else {
                        receive()
                    }
                })
            case .failed, .cancelled:
                complete(false)
            default:
                break
            }
        }
        connection.start(queue: queue)

        let deadline = DispatchTime.now() + timeout
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            if isCancelled() || DispatchTime.now() >= deadline {
                complete(false)
                break
            }
        }
        connection.cancel()

        lock.lock()
        let result = succeeded
        lock.unlock()
        return result
    }
}
