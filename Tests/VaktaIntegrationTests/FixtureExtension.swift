//
//  FixtureExtension.swift
//  VaktaIntegrationTests
//
//  A real Extension process for shell tests: a small Python script speaking
//  the line protocol. `FIXTURE_MODE` (environment) picks its behaviour:
//  normal, `mismatch` (wrong API version), `hang` (never answers
//  initialize), `crash-once` (exits on its first contexts/changed, then
//  behaves). It always exits when a context names the session "crash", and
//  logs every contexts/changed as `contexts:<session names>`. Rendered lists
//  carry `render <n> for <focused session>` so tests can see re-renders; the
//  view "broken" answers with an error.

import Foundation

enum FixtureExtension {
    static let script = #"""
        #!/usr/bin/env python3
        import json, os, sys

        mode = os.environ.get("FIXTURE_MODE", "normal")
        root = os.environ.get("VAKTA_EXTENSION_ROOT", ".")
        with open(os.path.join(root, "env-check.json"), "w") as check:
            json.dump({k: os.environ.get(k) for k in ["FIXTURE_SECRET", "OTHER", "PATH"]}, check)
        sys.stderr.write("fixture started pid=%d\n" % os.getpid())
        sys.stderr.flush()

        def send(obj):
            sys.stdout.write(json.dumps(obj) + "\n")
            sys.stdout.flush()

        def log(message):
            send({"jsonrpc": "2.0", "method": "log", "params": {"level": "info", "message": message}})

        documents = {}
        renders = 0
        focused = "none"

        for line in sys.stdin:
            message = json.loads(line)
            method = message.get("method")
            ident = message.get("id")
            params = message.get("params") or {}
            if method == "initialize":
                if mode == "hang":
                    continue
                version = 2 if mode == "mismatch" else 1
                send({"jsonrpc": "2.0", "id": ident, "result": {"apiVersion": version, "name": "Fixture"}})
            elif method == "contexts/changed":
                names = [c["sessionKey"]["sessionName"] for c in params.get("contexts", [])]
                focused = next((c["sessionKey"]["sessionName"] for c in params.get("contexts", []) if c.get("focused")), "none")
                log("contexts:" + ",".join(names))
                flag = os.path.join(root, ".crashed-once")
                if mode == "crash-once" and not os.path.exists(flag):
                    open(flag, "w").close()
                    sys.exit(4)
                if "crash" in names:
                    sys.exit(5)
            elif method == "view/render":
                view = params.get("view")
                renders += 1
                if view == "broken":
                    send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32000, "message": "fixture can't render"}})
                    continue
                send({"jsonrpc": "2.0", "id": ident, "result": documents.get(view, {
                    "kind": "list", "sections": [{"title": "Fixture", "items": [
                        {"id": "one", "title": "First item", "subtitle": "render %d for %s" % (renders, focused),
                         "detail": {"kind": "detail", "title": "One detail"},
                         "buttons": [{"title": "Refresh", "callback": "refresh"}]}]}]})})
            elif method == "callback":
                name = params.get("callback")
                if name == "refresh":
                    send({"jsonrpc": "2.0", "id": ident, "result": {"effects": [{"type": "refresh"}]}})
                elif name == "fail":
                    send({"jsonrpc": "2.0", "id": ident, "error": {"code": -32000, "message": "fixture failure"}})
                elif name == "echo":
                    send({"jsonrpc": "2.0", "id": ident, "result": {"effects": [
                        {"type": "toast", "text": json.dumps({"payload": params.get("payload"), "form": params.get("form")}, sort_keys=True)}]}})
                elif name == "hang":
                    pass
                elif name == "form":
                    send({"jsonrpc": "2.0", "id": ident, "result": {"effects": [{"type": "push", "document": {
                        "kind": "form", "title": "Close one",
                        "fields": [{"id": "message", "label": "Message", "kind": "multiline", "required": True},
                                   {"id": "notify", "label": "Notify", "kind": "toggle", "isOn": True}],
                        "submit": {"title": "Close", "callback": "echo", "payload": {"id": "one"}, "style": "primary"}}}]}})
                elif name == "navigate":
                    send({"jsonrpc": "2.0", "id": ident, "result": {"effects": [
                        {"type": "push", "document": {"kind": "detail", "title": "Pushed"}}]}})
                elif name == "back":
                    send({"jsonrpc": "2.0", "id": ident, "result": {"effects": [{"type": "pop"}, {"type": "toast", "text": "popped"}]}})
                elif name == "open":
                    send({"jsonrpc": "2.0", "id": ident, "result": {"effects": [
                        {"type": "open_url", "url": "https://example.com/issue"}, {"type": "notify", "title": "Opened", "body": "issue"}]}})
                elif name == "pane":
                    send({"jsonrpc": "2.0", "id": ident, "result": {"effects": [
                        {"type": "open_pane", "cwd": "/tmp", "command": ["echo", "hi; rm -rf /"], "title": "fixture"}]}})
                elif name == "slow":
                    import time
                    time.sleep(0.3)
                    send({"jsonrpc": "2.0", "id": ident, "result": {"effects": [{"type": "refresh"}, {"type": "toast", "text": "slow done"}]}})
                else:
                    send({"jsonrpc": "2.0", "id": ident, "result": {"effects": []}})
            elif method == "fixture/push":
                send({"jsonrpc": "2.0", "method": params["method"], "params": params.get("params")})
            elif method == "shutdown":
                send({"jsonrpc": "2.0", "id": ident, "result": None})
                sys.exit(0)
        """#

    /// Writes the fixture Extension (manifest + script) into `directory`.
    @discardableResult
    static func make(in directory: URL, id: String = "fixture", environment: [String] = []) throws -> ExtensionFixturePaths {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scriptURL = directory.appendingPathComponent("run.py")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        let environmentJSON = "[" + environment.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let manifest = """
            {"id": "\(id)", "name": "Fixture", "command": ["./run.py"], "environment": \(environmentJSON),
             "panelViews": [{"id": "items", "title": "Items", "symbol": "list.bullet"}]}
            """
        try manifest.write(to: directory.appendingPathComponent("vakta-extension.json"), atomically: true, encoding: .utf8)
        return ExtensionFixturePaths(directory: directory, script: scriptURL)
    }
}

struct ExtensionFixturePaths {
    let directory: URL
    let script: URL
}
