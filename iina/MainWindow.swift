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
   By default, `setFrame()` has its own implicit animation, and this can create an undesirable effect when combined with other animations. This function uses a `0` duration animation to effectively remove the implicit default animation.
   It will still animate if used inside an `NSAnimationContext` or `UIAnimation.Task` with non-zero duration.
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
    if menu?.performKeyEquivalent(with: event) == true {
      return
    }
    /// Forward all key events which the window receives to its controller.
    /// This allows `ESC` & `TAB` key bindings to work, instead of getting swallowed by
    /// MacOS keyboard focus navigation (which we don't use).
    if let controller = windowController as? MainWindowController {
      controller.keyDown(with: event)
    } else {
      super.keyDown(with: event)
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
