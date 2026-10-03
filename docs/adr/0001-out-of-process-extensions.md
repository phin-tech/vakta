# Extensions are out-of-process programs drawn natively

Vakta Extensions (first user: Kata) are separate executables in any language. Each runs as one long-lived child process speaking newline-delimited JSON-RPC 2.0 over stdio. They describe UI as View Documents that Vakta draws with SwiftUI, and they act only by returning Effects that Vakta carries out. We chose this over in-process bundles (ABI, signing, crashes take down the app), WKWebView panels (not native, JS bridge and focus problems inside a terminal app), and an embedded JS runtime (too large). The cost is a fixed UI vocabulary that grows only when a real Extension needs more, plus a process supervisor to maintain.

## Consequences

- A View Document never names a program to run. Buttons send Callbacks, and the only executables that run are the manifest's, under Trust.
- The JSON on the wire is the contract. The shared `VaktaExtensionKit` Swift types are a convenience, checked against golden JSON fixtures so that non-Swift Extensions stay compatible.
- Vakta stores no Extension data. Extensions key their own state by Session Key.
