//
//  CustomWindowBorderBox.swift
//  iina
//
//  Created by Matt Svoboda on 11/30/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/// `CustomWindowBorderBox` is used when drawing a "legacy" player window to provide a 0.5px border to
/// trailing, bottom, and leading sides, and a 1px gradient effect on the top side.
/// Because this element is higher in the Z ordering than the floating OSC and/or `VideoView`,
/// we need to add code to forward its `NSResponder` events appropriately
class CustomWindowBorderBox: NSBox {

  private var playerWindowController: PlayerWindowController? {
    return window?.windowController as? PlayerWindowController
  }

  // Need to send to either floating OSC or window, to patch holes when dragging OSC or resizing sidebar
  override func mouseDown(with event: NSEvent) {
    super.mouseDown(with: event)
    playerWindowController?.mouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    super.mouseDragged(with: event)
    playerWindowController?.mouseDragged(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    super.mouseUp(with: event)
    playerWindowController?.mouseUp(with: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    super.rightMouseDown(with: event)
    playerWindowController?.rightMouseDown(with: event)
  }

  override func rightMouseUp(with event: NSEvent) {
    playerWindowController?.rightMouseUp(with: event)
    super.rightMouseUp(with: event)
  }

  override func pressureChange(with event: NSEvent) {
    playerWindowController?.pressureChange(with: event)
    super.pressureChange(with: event)
  }

  override func otherMouseDown(with event: NSEvent) {
    playerWindowController?.otherMouseDown(with: event)
    super.otherMouseDown(with: event)
  }

  override func otherMouseUp(with event: NSEvent) {
    playerWindowController?.otherMouseUp(with: event)
    super.otherMouseUp(with: event)
  }
}
