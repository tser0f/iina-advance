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
  private var useZeroDurationForNextResize = false

  /**
   By default, `setFrame()` is not immediate, and this can create an undesirable delay when combined with other animations.
   This function uses a `0` duration animation.
   */
  func setFrameImmediately(_ newFrame: NSRect) {
    useZeroDurationForNextResize = true
    setFrame(newFrame, display: true, animate: true)
  }

  override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
    if useZeroDurationForNextResize {
      useZeroDurationForNextResize = false
      return 0
    }
    return super.animationResizeTime(newFrame)
  }

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

  /// Setting `alphaValue=0` for Close & Miniaturize (red & green traffic lights) buttons causes `File` > `Close`
  /// and `Window` > `Minimize` to be disabled as an unwanted side effect. This can cause key bindings to fail
  /// during animations or if we're not careful to set `alphaValue=1` for hidden items. Permanently enabling them
  /// here guarantees consistent behavior.
  override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(self.performClose(_:)) {
      return true
    } else if item.action == #selector(self.performMiniaturize(_:)) {
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
