//
//  FloatingControlBarView.swift
//  iina
//
//  Created by lhc on 16/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

// The control bar when position=="floating"
class FloatingControlBarView: NSVisualEffectView {
  private static let minBarWidth: CGFloat = 200
  private static let preferredBarWidth: CGFloat = 440
  private static let minOffsetFromSides: CGFloat = 10

  @IBOutlet weak var xConstraint: NSLayoutConstraint!  // this is X CENTER of OSC
  @IBOutlet weak var yConstraint: NSLayoutConstraint!  // Bottom of OSC

  var mousePosRelatedToView: CGPoint?

  var isDragging: Bool = false

  private var isAlignFeedbackSent = false

  private var playerWindowController: PlayerWindowController? {
    return window?.windowController as? PlayerWindowController
  }

  private var viewportView: NSView? {
    return playerWindowController?.viewportView
  }

  // - MARK: Coordinates in Viewport

  var minX: CGFloat {
    return FloatingControlBarView.minOffsetFromSides + (playerWindowController?.currentLayout.insideLeadingBarWidth ?? 0)
  }

  var minY: CGFloat {
    if Preference.enum(for: .oscPosition) == Preference.OSCPosition.bottom, 
        Preference.enum(for: .bottomBarPlacement) == Preference.PanelPlacement.insideViewport,
        let bottomBarHeight = playerWindowController?.bottomBarView.frame.height {
      return FloatingControlBarView.minOffsetFromSides + bottomBarHeight
    }
    return FloatingControlBarView.minOffsetFromSides
  }

  var maxX: CGFloat {
    guard let viewportView else {
      return FloatingControlBarView.minBarWidth
    }
    let availableSpace = viewportView.frame.width - FloatingControlBarView.minOffsetFromSides
    if availableSpace < FloatingControlBarView.preferredBarWidth {
      return availableSpace - (FloatingControlBarView.minBarWidth / 2)
    } else {
      return availableSpace - (FloatingControlBarView.preferredBarWidth / 2)
    }
  }

  var maxY: CGFloat {
    let maxYWithoutTopBar = (viewportView?.frame.height ?? 0) - frame.height - FloatingControlBarView.minOffsetFromSides
    let value: CGFloat
    if Preference.enum(for: .topBarPlacement) == Preference.PanelPlacement.insideViewport,
       let topBarHeight = playerWindowController?.topBarView.frame.height {
      value = maxYWithoutTopBar - topBarHeight
    } else {
      value = maxYWithoutTopBar
    }
    // ensure sanity
    return max(value, frame.height + FloatingControlBarView.minOffsetFromSides)
  }

  var centerX: CGFloat {
    let minX = minX
    let maxX = maxX
    let availableWidth = maxX - minX
    return (availableWidth * 0.5) + minX
  }

  override func awakeFromNib() {
    self.roundCorners(withRadius: 6)
    self.translatesAutoresizingMaskIntoConstraints = false
  }

  func updateConstraints(newOriginInViewport newOrigin: NSPoint) {
    // bound to viewport frame
    let newOrigin = newOrigin.constrained(to: NSRect(x: minX, y: minY, width: maxX - FloatingControlBarView.minOffsetFromSides, height: maxY - FloatingControlBarView.minOffsetFromSides))
    // apply position
    xConstraint.constant = newOrigin.x + frame.width / 2
    yConstraint.constant = newOrigin.y
  }

  // - MARK: Mouse Events

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return Preference.bool(for: .videoViewAcceptsFirstMouse)
  }

  override func mouseDown(with event: NSEvent) {
    guard let viewportView = (window?.windowController as? PlayerWindowController)?.viewportView else {
      return
    }

    mousePosRelatedToView = viewportView.convert(NSEvent.mouseLocation, from: superview)
    let originInViewport = viewportView.convert(frame.origin, from: superview)
    mousePosRelatedToView!.x -= originInViewport.x
    mousePosRelatedToView!.y -= originInViewport.y
    isAlignFeedbackSent = abs(originInViewport.x - (viewportView.frame.width - frame.width) / 2) <= 5
    isDragging = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard let mousePos = mousePosRelatedToView,
          let viewportView = (window?.windowController as? PlayerWindowController)?.viewportView else {
      return
    }
    let viewportFrame = viewportView.frame

    let currentLocInViewport = viewportView.convert(NSEvent.mouseLocation, from: superview)
    var newOrigin = CGPoint(
      x: currentLocInViewport.x - mousePos.x,
      y: currentLocInViewport.y - mousePos.y
    )
    // stick to center
    if Preference.bool(for: .controlBarStickToCenter) {
      let xPosWhenCenter = centerX - (frame.width / 2)
      if abs(newOrigin.x - xPosWhenCenter) <= Constants.Distance.floatingControllerSnapToCenterThreshold {
        newOrigin.x = xPosWhenCenter
        if !isAlignFeedbackSent {
          NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
          isAlignFeedbackSent = true
        }
      } else {
        isAlignFeedbackSent = false
      }
    }

    updateConstraints(newOriginInViewport: newOrigin)
  }

  override func mouseUp(with event: NSEvent) {
    isDragging = false

    if event.clickCount == 2 {
      let newOrigin = NSPoint(x: centerX - (frame.width / 2), y: frame.origin.y)
      updateConstraints(newOriginInViewport: newOrigin)
      return
    }

    guard let viewportFrame = (window?.windowController as? PlayerWindowController)?.viewportView.frame else { return }
    // save final position
    // FIXME: change this to work for multiple windows
    let xRatio = (xConstraint.constant - (frame.width / 2)) / viewportFrame.width
    let yRatio = yConstraint.constant / maxY
    Preference.set(xRatio, for: .controlBarPositionHorizontal)
    Preference.set(yRatio, for: .controlBarPositionVertical)
  }

}
