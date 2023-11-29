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
  private static let barHeight: CGFloat = 67
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

  // MARK: - Positioning

  func moveTo(centerRatioH cH: CGFloat, originRatioV oV: CGFloat, layout: PlayerWindowController.LayoutState, viewportSize: CGSize) {
    assert(cH >= 0 && cH <= 1, "centerRatioH is invalid: \(cH)")
    assert(oV >= 0 && oV <= 1, "originRatioV is invalid: \(oV)")

    let geometry = FloatingControllerGeometry(windowLayout: layout, viewportSize: viewportSize)
    let availableWidth = geometry.availableWidth
    let minXCenter = geometry.minXCenter
    let centerX = geometry.availableWidthMinX + (availableWidth * cH)
    let originY = geometry.minOriginY + (oV * (geometry.maxOriginY - geometry.minOriginY))
    let (xConst, yConst) = geometry.calculateConstraintConstants(centerX: centerX, originY: originY)
    Logger.log("Setting xConstraint to: \(xConst)")
    xConstraint.constant = xConst
    yConstraint.constant = yConst
  }

  // MARK: - Mouse Events

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return Preference.bool(for: .videoViewAcceptsFirstMouse)
  }

  override func mouseDown(with event: NSEvent) {
    guard let viewportView = playerWindowController?.viewportView else { return }

    mousePosRelatedToView = self.convert(event.locationInWindow, from: nil)
    let originInViewport = viewportView.convert(frame.origin, from: nil)
    isAlignFeedbackSent = abs(originInViewport.x - (viewportView.frame.width - frame.width) / 2) <= Constants.Distance.floatingControllerSnapToCenterThreshold
    isDragging = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard let mouseLocInView = mousePosRelatedToView,
          let playerWindowController,
          let viewportView = playerWindowController.viewportView else {
      return
    }

    let currentLocInViewport = viewportView.convert(event.locationInWindow, from: nil)
    let geometry = FloatingControllerGeometry(windowLayout: playerWindowController.currentLayout, viewportSize: viewportView.frame.size)

    var newCenterX = currentLocInViewport.x - mouseLocInView.x + geometry.halfBarWidth
    let newOriginY = currentLocInViewport.y - mouseLocInView.y
    // stick to center
    if Preference.bool(for: .controlBarStickToCenter) {
      let xPosWhenCenter = geometry.centerX
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

    let availableWidth = geometry.availableWidth
    Logger.log("Drag: Setting xConstraint to: \(newCenterX)")
    let (xConst, yConst) = geometry.calculateConstraintConstants(centerX: newCenterX, originY: newOriginY)
    xConstraint.constant = xConst
    yConstraint.constant = yConst
  }

  override func mouseUp(with event: NSEvent) {
    guard let playerWindowController, let viewportView = playerWindowController.viewportView else { return }

    isDragging = false
    let geometry = FloatingControllerGeometry(windowLayout: playerWindowController.currentLayout, viewportSize: viewportView.frame.size)

    if event.clickCount == 2 {
      let (xConst, yConst) = geometry.calculateConstraintConstants(centerX: geometry.centerX, originY: frame.origin.y)

      // apply position
      xConstraint.constant = xConst
      yConstraint.constant = yConst
      updateRatios(xConst: xConst, yConst: yConst, geometry)
      return
    }

    updateRatios(xConst: xConstraint.constant, yConst: yConstraint.constant, geometry)
  }

  private func updateRatios(xConst: CGFloat, yConst: CGFloat, _ geometry: FloatingControllerGeometry) {
    guard let playerWindowController else { return }
    let minXCenter = geometry.minXCenter

    // save final position
    let xRatio = (xConstraint.constant - minXCenter) / (geometry.maxXCenter - minXCenter)
    let minOriginY = geometry.minOriginY
    let yRatio = (yConstraint.constant - minOriginY) / (geometry.maxOriginY - minOriginY)

    Logger.log("Drag: Setting x ratio to: \(xRatio)")
    // Save in window for use when resizing, etc.
    playerWindowController.floatingOscCenterRatioH = xRatio
    playerWindowController.floatingOSCOriginRatioV = yRatio
    // Save to prefs as future default
    Preference.set(xRatio, for: .controlBarPositionHorizontal)
    Preference.set(yRatio, for: .controlBarPositionVertical)
  }

  // MARK: - Coordinates in Viewport

  struct FloatingControllerGeometry {
    let windowLayout: PlayerWindowController.LayoutState
    let viewportSize: CGSize

    // "available" == space to move OSC within
    var availableWidthMinX: CGFloat {
      return windowLayout.insideLeadingBarWidth + FloatingControlBarView.margin
    }

    var availableWidthMaxX: CGFloat {
      let viewportMaxX = viewportSize.width
      let trailingUsedSpace = windowLayout.insideTrailingBarWidth + FloatingControlBarView.margin
      return max(viewportMaxX - trailingUsedSpace, FloatingControlBarView.margin + FloatingControlBarView.minBarWidth)
    }

    var availableWidth: CGFloat {
      return availableWidthMaxX - availableWidthMinX
    }

    var halfBarWidth: CGFloat {
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
      let maxYWithoutTopBar = viewportSize.height - FloatingControlBarView.barHeight - FloatingControlBarView.margin
      let topBarHeight = windowLayout.insideTopBarHeight
      let value = maxYWithoutTopBar - topBarHeight
      // ensure sanity
      return max(value, FloatingControlBarView.barHeight + FloatingControlBarView.margin)
    }

    var centerX: CGFloat {
      let minX = minXCenter
      let maxX = maxXCenter
      let availableWidth = maxX - minX
      return minX + (availableWidth * 0.5)
    }

    func calculateConstraintConstants(centerX: CGFloat, originY: CGFloat) -> (CGFloat, CGFloat) {
      let minOriginY = minOriginY
      let minXCenter = minXCenter
      let maxXCenter = maxXCenter
      let maxOriginY = maxOriginY
      // bound to viewport frame
      let constraintRect = NSRect(x: minXCenter, y: minOriginY, width: maxXCenter - minXCenter, height: maxOriginY - minOriginY)
      let newOrigin = CGPoint(x: centerX, y: originY).constrained(to: constraintRect)
      return (newOrigin.x, newOrigin.y)
    }

  }

}
