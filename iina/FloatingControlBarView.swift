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
  private static let margin: CGFloat = 10

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

  override func awakeFromNib() {
    self.roundCorners(withRadius: 6)
    self.translatesAutoresizingMaskIntoConstraints = false
  }

  // MARK: - Coordinates in Viewport

  // "available" == space to move OSC within
  private var availableWidthMinX: CGFloat {
    return (playerWindowController?.currentLayout.insideLeadingBarWidth ?? 0) + FloatingControlBarView.margin
  }

  private var availableWidthMaxX: CGFloat {
    guard let viewportView else {
      return FloatingControlBarView.margin + FloatingControlBarView.minBarWidth
    }
    let viewportMaxX = viewportView.frame.size.width
    let trailingUsedSpace = (playerWindowController?.currentLayout.insideTrailingBarWidth ?? 0) + FloatingControlBarView.margin
    return viewportMaxX - trailingUsedSpace
  }

  private var availableWidth: CGFloat {
    return availableWidthMaxX - availableWidthMinX
  }

  private var halfBarWidth: CGFloat {
    if availableWidth < FloatingControlBarView.preferredBarWidth {
      return FloatingControlBarView.minBarWidth / 2
    }
    return FloatingControlBarView.preferredBarWidth / 2
  }

  var minXCenter: CGFloat {
    return availableWidthMinX + halfBarWidth
  }

  // Centered
  var maxXCenter: CGFloat {
    return availableWidthMaxX - halfBarWidth
  }

  var minOriginY: CGFloat {
    // There is no bottom bar is OSC is floating
    return FloatingControlBarView.margin
  }

  var maxOriginY: CGFloat {
    let maxYWithoutTopBar = (viewportView?.frame.height ?? 0) - frame.height - FloatingControlBarView.margin
    let value: CGFloat
    if let topBarHeight = playerWindowController?.currentLayout.insideTopBarHeight {
      value = maxYWithoutTopBar - topBarHeight
    } else {
      value = maxYWithoutTopBar
    }
    // ensure sanity
    return max(value, frame.height + FloatingControlBarView.margin)
  }

  var centerX: CGFloat {
    let minX = minXCenter
    let maxX = maxXCenter
    let availableWidth = maxX - minX
    return minX + (availableWidth * 0.5)
  }

  // MARK: - Positioning

  func moveTo(centerRatioH cH: CGFloat, originRatioV oV: CGFloat) {
    assert(cH >= 0 && cH <= 1, "centerRatioH is invalid: \(cH)")
    assert(oV >= 0 && oV <= 1, "originRatioV is invalid: \(oV)")

    let centerX = minXCenter + (availableWidth * cH)
    xConstraint.constant = centerX
    let originY = minOriginY + (oV * (maxOriginY - minOriginY))
    updatePositionConstraints(centerX: centerX, originY: originY)
  }

  private func updatePositionConstraints(centerX: CGFloat, originY: CGFloat) {
    let minOriginY = minOriginY
    let minXCenter = minXCenter
    let maxXCenter = maxXCenter
    let maxOriginY = maxOriginY
    // bound to viewport frame
    let constraintRect = NSRect(x: minXCenter, y: minOriginY, width: maxXCenter - minXCenter, height: maxOriginY - minOriginY)
    let newOrigin = CGPoint(x: centerX, y: originY).constrained(to: constraintRect)
    // apply position
    xConstraint.constant = newOrigin.x
    yConstraint.constant = newOrigin.y
  }

  // MARK: - Mouse Events

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return Preference.bool(for: .videoViewAcceptsFirstMouse)
  }

  override func mouseDown(with event: NSEvent) {
    guard let viewportView = (window?.windowController as? PlayerWindowController)?.viewportView else {
      return
    }

    mousePosRelatedToView = self.convert(event.locationInWindow, from: nil)
    let originInViewport = viewportView.convert(frame.origin, from: nil)
    isAlignFeedbackSent = abs(originInViewport.x - (viewportView.frame.width - frame.width) / 2) <= Constants.Distance.floatingControllerSnapToCenterThreshold
    isDragging = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard let mouseLocInView = mousePosRelatedToView,
          let viewportView = (window?.windowController as? PlayerWindowController)?.viewportView else {
      return
    }

    let currentLocInViewport = viewportView.convert(event.locationInWindow, from: nil)
    var newCenterX = currentLocInViewport.x - mouseLocInView.x + halfBarWidth
    let newOriginY = currentLocInViewport.y - mouseLocInView.y
    // stick to center
    if Preference.bool(for: .controlBarStickToCenter) {
      let xPosWhenCenter = centerX
      if abs(newCenterX - xPosWhenCenter) <= Constants.Distance.floatingControllerSnapToCenterThreshold {
        newCenterX = xPosWhenCenter
        if !isAlignFeedbackSent {
          NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
          isAlignFeedbackSent = true
        }
      } else {
        isAlignFeedbackSent = false
      }
    }

    updatePositionConstraints(centerX: newCenterX, originY: newOriginY)
  }

  override func mouseUp(with event: NSEvent) {
    isDragging = false

    let minXCenter = minXCenter
    if event.clickCount == 2 {
      updatePositionConstraints(centerX: centerX, originY: frame.origin.y)
      return
    }

    // save final position
    let xRatio = (xConstraint.constant - minXCenter) / (maxXCenter - minXCenter)
    let minOriginY = minOriginY
    let yRatio = (yConstraint.constant - minOriginY) / (maxOriginY - minOriginY)

    if let playerWindowController {
      // Save in window for use when resizing, etc.
      playerWindowController.floatingOscCenterRatioH = xRatio
      playerWindowController.floatingOSCOriginRatioV = yRatio
    }
    // Save to prefs as future default
    Preference.set(xRatio, for: .controlBarPositionHorizontal)
    Preference.set(yRatio, for: .controlBarPositionVertical)
  }

}
