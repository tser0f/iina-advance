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

  override func mouseDown(with event: NSEvent) {
    if let playerWindowController {
      if let controlBarFloating = playerWindowController.controlBarFloating, !controlBarFloating.isHidden,
          playerWindowController.isMouseEvent(event, inAnyOf: [controlBarFloating]) {
        controlBarFloating.mouseDown(with: event)
      }
      playerWindowController.mouseDown(with: event)
    }
    super.mouseDown(with: event)
  }

  override func mouseDragged(with event: NSEvent) {
    if let playerWindowController {
      if let controlBarFloating = playerWindowController.controlBarFloating, !controlBarFloating.isHidden,
         controlBarFloating.isDragging {
        controlBarFloating.mouseDragged(with: event)
      }
      playerWindowController.mouseDragged(with: event)
    }
    super.mouseDragged(with: event)
  }

  override func mouseUp(with event: NSEvent) {
    if let playerWindowController {
      if let controlBarFloating = playerWindowController.controlBarFloating, !controlBarFloating.isHidden,
         controlBarFloating.isDragging || playerWindowController.isMouseEvent(event, inAnyOf: [controlBarFloating]) {
        controlBarFloating.mouseUp(with: event)
      }
      playerWindowController.mouseUp(with: event)
    }
    super.mouseUp(with: event)
  }

  override func rightMouseDown(with event: NSEvent) {
    if let playerWindowController {
      if let controlBarFloating = playerWindowController.controlBarFloating, !controlBarFloating.isHidden,
          playerWindowController.isMouseEvent(event, inAnyOf: [controlBarFloating]) {
        controlBarFloating.rightMouseDown(with: event)
      }
      playerWindowController.rightMouseDown(with: event)
    }
    super.rightMouseDown(with: event)
  }

}
