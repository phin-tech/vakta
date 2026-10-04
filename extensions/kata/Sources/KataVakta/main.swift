//
//  main.swift
//  kata-vakta
//
//  Entry point: `kata-vakta serve` speaks the Vakta Extension protocol on
//  stdio (through VaktaExtensionServer). See docs/extensions-plan.md in the
//  Vakta repository.

import Foundation
import VaktaExtensionServer

guard CommandLine.arguments.dropFirst().first == "serve" else {
    FileHandle.standardError.write(Data("usage: kata-vakta serve\n".utf8))
    exit(64)
}

let server = ExtensionServer(name: "Kata")
let kata = KataServer(server: server)
server.run()
