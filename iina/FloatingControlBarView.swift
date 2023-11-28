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

  @IBOutlet weak var xConstraint: NSLayoutConstraint!  // this is CENTER of OSC
  @IBOutlet weak var yConstraint: NSLayoutConstraint!

  var mousePosRelatedToView: CGPoint?

  var isDragging: Bool = false

  private var isAlignFeedbackSent = false

  override func awakeFromNib() {
    self.roundCorners(withRadius: 6)
    self.translatesAutoresizingMaskIntoConstraints = false
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
      let xPosWhenCenter = (viewportFrame.width - frame.width) / 2
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
    // bound to viewport frame
    let xMax = viewportFrame.width - frame.width - 10
    let yMax = viewportFrame.height - frame.height - 25
    newOrigin = newOrigin.constrained(to: NSRect(x: 10, y: 0, width: xMax, height: yMax))
    // apply position
    xConstraint.constant = newOrigin.x + frame.width / 2
    yConstraint.constant = newOrigin.y
  }

  override func mouseUp(with event: NSEvent) {
    isDragging = false
    guard let viewportFrame = (window?.windowController as? PlayerWindowController)?.viewportView.frame else { return }
    // save final position
    // FIXME: change this to work for multiple windows
    let xRatio = (xConstraint.constant - frame.width / 2) / viewportFrame.width
    let yRatio = yConstraint.constant / viewportFrame.height
    Preference.set(xRatio, for: .controlBarPositionHorizontal)
    Preference.set(yRatio, for: .controlBarPositionVertical)
  }

}
