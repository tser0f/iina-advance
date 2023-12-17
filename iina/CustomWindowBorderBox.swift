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

  override var acceptsFirstResponder: Bool { false }

  // Need to send to either floating OSC or window, to patch holes when dragging OSC or resizing sidebar
  override func mouseDown(with event: NSEvent) {
    if let playerWindowController {
      if let controlBarFloating = playerWindowController.controlBarFloating, !controlBarFloating.isHidden,
          playerWindowController.isMouseEvent(event, inAnyOf: [controlBarFloating]) {
        controlBarFloating.mouseDown(with: event)
      } else {
        playerWindowController.mouseDown(with: event)
      }
    } else {
      super.mouseDown(with: event)
    }
  }

  override func mouseDragged(with event: NSEvent) {
    if let playerWindowController {
      if let controlBarFloating = playerWindowController.controlBarFloating, !controlBarFloating.isHidden,
         controlBarFloating.isDragging {
        controlBarFloating.mouseDragged(with: event)
      } else {
        playerWindowController.mouseDragged(with: event)
      }
    } else {
      super.mouseDragged(with: event)
    }
  }

  override func mouseUp(with event: NSEvent) {
    if let playerWindowController {
      if let controlBarFloating = playerWindowController.controlBarFloating, !controlBarFloating.isHidden,
         controlBarFloating.isDragging || playerWindowController.isMouseEvent(event, inAnyOf: [controlBarFloating]) {
        controlBarFloating.mouseUp(with: event)
      } else {
        playerWindowController.mouseUp(with: event)
      }
    } else {
      super.mouseUp(with: event)
    }
  }

  override func rightMouseDown(with event: NSEvent) {
    if let playerWindowController {
      if let controlBarFloating = playerWindowController.controlBarFloating, !controlBarFloating.isHidden,
          playerWindowController.isMouseEvent(event, inAnyOf: [controlBarFloating]) {
        controlBarFloating.rightMouseDown(with: event)
      } else {
        playerWindowController.rightMouseDown(with: event)
      }
    } else {
      super.rightMouseDown(with: event)
    }
  }

  override func rightMouseUp(with event: NSEvent) {
    if let playerWindowController {
      if let controlBarFloating = playerWindowController.controlBarFloating, !controlBarFloating.isHidden,
         playerWindowController.isMouseEvent(event, inAnyOf: [controlBarFloating]) {
        controlBarFloating.rightMouseUp(with: event)
      } else {
        playerWindowController.rightMouseUp(with: event)
      }
    } else {
      super.rightMouseUp(with: event)
    }
  }

  override func pressureChange(with event: NSEvent) {
    if let playerWindowController {
      if let controlBarFloating = playerWindowController.controlBarFloating, !controlBarFloating.isHidden,
         playerWindowController.isMouseEvent(event, inAnyOf: [controlBarFloating]) {
        controlBarFloating.pressureChange(with: event)
      } else {
        playerWindowController.pressureChange(with: event)
      }
    } else {
      super.pressureChange(with: event)
    }
  }

  override func otherMouseDown(with event: NSEvent) {
    if let playerWindowController {
      if let controlBarFloating = playerWindowController.controlBarFloating, !controlBarFloating.isHidden,
         playerWindowController.isMouseEvent(event, inAnyOf: [controlBarFloating]) {
        controlBarFloating.otherMouseDown(with: event)
      } else {
        playerWindowController.otherMouseDown(with: event)
      }
    } else {
      super.otherMouseDown(with: event)
    }
  }

  override func otherMouseUp(with event: NSEvent) {
    if let playerWindowController {
      if let controlBarFloating = playerWindowController.controlBarFloating, !controlBarFloating.isHidden,
         playerWindowController.isMouseEvent(event, inAnyOf: [controlBarFloating]) {
        controlBarFloating.otherMouseUp(with: event)
      } else {
        playerWindowController.otherMouseUp(with: event)
      }
    } else {
      super.otherMouseUp(with: event)
    }
  }
}
