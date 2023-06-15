//
//  MiniPlayerWindow.swift
//  iina
//
//  Created by Matt Svoboda on 2023-06-14.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

class MiniPlayerWindow: NSWindow {
  override func keyDown(with event: NSEvent) {
    // Forward all key events which the window receives to controller. This ensures that
    // TAB & ESC key bindings will work, and that TAB/Shift+TAB will not change focus onto
    // window controls.
    if let controller = windowController as? MiniPlayerWindowController {
      controller.keyDown(with: event)
    }
  }
}
