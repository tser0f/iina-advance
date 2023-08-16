//
//  MiniPlayerWindow.swift
//  iina
//
//  Created by Matt Svoboda on 2023-06-15.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

class MiniPlayerWindow: NSWindow {

  override func keyDown(with event: NSEvent) {
    if menu?.performKeyEquivalent(with: event) == true {
      return
    }
    /// Forward all key events which the window receives to its controller.
    /// This allows `ESC` & `TAB` key bindings to work, instead of getting swallowed by
    /// MacOS keyboard focus navigation (which we don't use).
    if let controller = windowController as? MiniPlayerWindowController {
      controller.keyDown(with: event)
    } else {
      super.keyDown(with: event)
    }
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    /// AppKit by default will prioritize menu item key equivalents over arrow key navigation
    /// (although for some reason it is the opposite for `ESC`, `TAB`, `ENTER` or `RETURN`).
    /// Need to add an explicit check here for arrow keys to ensure that they always work when desired.
    if let responder = firstResponder, shouldFavorArrowKeyNavigation(for: responder) {

      let keyCode = KeyCodeHelper.mpvKeyCode(from: event)
      let normalizedKeyCode = KeyCodeHelper.normalizeMpv(keyCode)

      switch normalizedKeyCode {
      case "UP", "DOWN", "LEFT", "RIGHT":
        // Send arrow keys to view to enable key navigation
        responder.keyDown(with: event)
        return true
      default:
        break
      }
    }
    return super.performKeyEquivalent(with: event)
  }

  private func shouldFavorArrowKeyNavigation(for responder: NSResponder) -> Bool {
    /// There is some ambiguity about when a table is in focus, so only favor arrow keys when there's
    /// already a selection:
    if let tableView = responder as? NSTableView, !tableView.selectedRowIndexes.isEmpty {
      return true
    }
    return false
  }

}
