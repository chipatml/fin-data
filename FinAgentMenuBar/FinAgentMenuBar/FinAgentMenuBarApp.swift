//
//  FinAgentMenuBarApp.swift
//  FinAgentMenuBar
//
//  Created by Chirag Patel on 7/16/26.
//

import SwiftUI

@main
struct FinAgentMenuBarApp: App {
    var body: some Scene {
        MenuBarExtra("FinAgent", systemImage: "dollarsign.circle") {
            ContentView()
        }
        .menuBarExtraStyle(.window)
    }
}
