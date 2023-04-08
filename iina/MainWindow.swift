//
//  MainWindow.swift
//  iina
//
//  Created by Collider LI on 10/1/2018.
//  Copyright © 2018 lhc. All rights reserved.
//

import Cocoa

class MainWindow: NSWindow {
  var forceKeyAndMain = false

  override func keyDown(with event: NSEvent) {
    // Forward all key events which the window receives to controller. This fixes:
    // (a) ESC key not otherwise sent to window
    // (b) window was not getting a chance to respond before main menu
    if let controller = windowController as? MainWindowController {
      controller.keyDown(with: event)
    }
  }

  override var canBecomeKey: Bool {
    forceKeyAndMain ? true : super.canBecomeKey
  }
  
  override var canBecomeMain: Bool {
    forceKeyAndMain ? true : super.canBecomeMain
  }

  /// Hiding the Close (red stoplight) button causes `File` > `Close` to be disabled as an unwanted side effect.
  /// We must re-implement the window close functionality here.
  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(self.performClose(_:)) {
      return true
    } else {
      return super.validateUserInterfaceItem(item)
    }
  }

  /// See `validateUserInterfaceItem()`.
  override func performClose(_ sender: Any?) {
    self.close()
  }
}
