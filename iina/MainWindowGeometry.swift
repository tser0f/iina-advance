//
//  MainWindowGeometry.swift
//  iina
//
//  Created by Matt Svoboda on 7/11/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/**
 ┌───────────────────────────────────────────┐
 │ `windowFrame`      ▲                      │
 │                    │`topPanelHeight`      │
 │                    ▼                      │
 │                ┌───────┐                  │
 │◄──────────────►│ Video │◄────────────────►│
 │`leftPanelWidth`│ Frame │`rightPanelWidth `│
 │                └───────┘                  │
 │                  ▲                        │
 │                  │ `bottomPanelHeight`    │
 │                  ▼                        │
 └───────────────────────────────────────────┘
 */
struct MainWindowGeometry: Equatable {
  // MARK: - Stored properties

  let windowFrame: NSRect

  // Outside panels
  let topPanelHeight: CGFloat
  let rightPanelWidth: CGFloat
  let bottomPanelHeight: CGFloat
  let leftPanelWidth: CGFloat

  // MARK: - Initializers

  init(windowFrame: NSRect, topPanelHeight: CGFloat, rightPanelWidth: CGFloat, bottomPanelHeight: CGFloat, leftPanelWidth: CGFloat) {
    assert(topPanelHeight >= 0, "Expected topPanelHeight > 0, found \(topPanelHeight)")
    assert(rightPanelWidth >= 0, "Expected rightPanelWidth > 0, found \(rightPanelWidth)")
    assert(bottomPanelHeight >= 0, "Expected bottomPanelHeight > 0, found \(bottomPanelHeight)")
    assert(leftPanelWidth >= 0, "Expected leftPanelWidth > 0, found \(leftPanelWidth)")
    assert(rightPanelWidth >= 0, "Expected rightPanelWidth > 0, found \(rightPanelWidth)")
    self.windowFrame = windowFrame
    self.topPanelHeight = topPanelHeight
    self.rightPanelWidth = rightPanelWidth
    self.bottomPanelHeight = bottomPanelHeight
    self.leftPanelWidth = leftPanelWidth
  }

  init(windowFrame: CGRect, videoFrame: CGRect) {
    assert(videoFrame.height <= windowFrame.height, "videoFrame.height (\(videoFrame.height)) cannot be larger than windowFrame.height (\(windowFrame.height))")
    assert(videoFrame.width <= windowFrame.width, "videoFrame.width (\(videoFrame.width)) cannot be larger than windowFrame.width (\(windowFrame.width))")

    let leftPanelWidth = videoFrame.origin.x
    let bottomPanelHeight = videoFrame.origin.y
    let rightPanelWidth = windowFrame.width - videoFrame.width - leftPanelWidth
    let topPanelHeight = windowFrame.height - videoFrame.height - bottomPanelHeight
    self.init(windowFrame: windowFrame,
              topPanelHeight: topPanelHeight, rightPanelWidth: rightPanelWidth,
              bottomPanelHeight: bottomPanelHeight, leftPanelWidth: leftPanelWidth)
  }

  // MARK: - Derived properties

  var videoSize: NSSize {
    return NSSize(width: windowFrame.width - rightPanelWidth - leftPanelWidth,
                  height: windowFrame.height - topPanelHeight - bottomPanelHeight)
  }

  var videoFrameInScreenCoords: NSRect {
    return NSRect(origin: CGPoint(x: windowFrame.origin.x + leftPanelWidth, y: windowFrame.origin.y + bottomPanelHeight), size: videoSize)
  }

  var outsidePanelsTotalSize: NSSize {
    return NSSize(width: rightPanelWidth + leftPanelWidth, height: topPanelHeight + bottomPanelHeight)
  }

  var minVideoSize: NSSize {
    return PlayerCore.minVideoSize
  }

  func clone(windowFrame: NSRect? = nil,
             topPanelHeight: CGFloat? = nil, rightPanelWidth: CGFloat? = nil,
             bottomPanelHeight: CGFloat? = nil, leftPanelWidth: CGFloat? = nil) -> MainWindowGeometry {

    return MainWindowGeometry(windowFrame: windowFrame ?? self.windowFrame,
                           topPanelHeight: topPanelHeight ?? self.topPanelHeight,
                           rightPanelWidth: rightPanelWidth ?? self.rightPanelWidth,
                           bottomPanelHeight: bottomPanelHeight ?? self.bottomPanelHeight,
                           leftPanelWidth: leftPanelWidth ?? self.leftPanelWidth)
  }

  private func computeMaxVideoSize(in containerSize: NSSize) -> NSSize {
    // Resize only the video. Panels outside the video do not change size.
    // To do this, subtract the "outside" panels from the container frame
    let outsidePanelsSize = self.outsidePanelsTotalSize
    return NSSize(width: containerSize.width - outsidePanelsSize.width,
                  height: containerSize.height - outsidePanelsSize.height)
  }

  func constrainWithin(_ containerFrame: NSRect) -> MainWindowGeometry {
    return scale(desiredVideoSize: self.videoSize, constrainedWithin: containerFrame)
  }

  func scale(desiredVideoSize: NSSize, constrainedWithin containerFrame: NSRect) -> MainWindowGeometry {
    var newVideoSize = desiredVideoSize

    /// Clamp video between max and min video sizes, maintaining its aspect ratio.
    /// (`desiredVideoSize` is assumed to be correct aspect ratio of the video.)

    // Max
    let maxVideoSize = computeMaxVideoSize(in: containerFrame.size)
    if newVideoSize.height > maxVideoSize.height {
      newVideoSize = newVideoSize.satisfyMaxSizeWithSameAspectRatio(maxVideoSize)
    }
    if newVideoSize.width > maxVideoSize.width {
      newVideoSize = newVideoSize.satisfyMaxSizeWithSameAspectRatio(maxVideoSize)
    }

    // Min
    if newVideoSize.height < minVideoSize.height {
      newVideoSize = newVideoSize.satisfyMinSizeWithSameAspectRatio(minVideoSize)
    }
    if newVideoSize.width < minVideoSize.width {
      newVideoSize = newVideoSize.satisfyMinSizeWithSameAspectRatio(minVideoSize)
    }

    newVideoSize = NSSize(width: newVideoSize.width, height: newVideoSize.height)

    let outsidePanelsSize = self.outsidePanelsTotalSize
    let newWindowSize = NSSize(width: round(newVideoSize.width + outsidePanelsSize.width),
                               height: round(newVideoSize.height + outsidePanelsSize.height))

    // Round the results to prevent excessive window drift due to small imprecisions in calculation
    let deltaX = round((newVideoSize.width - videoSize.width) / 2)
    let deltaY = round((newVideoSize.height - videoSize.height) / 2)
    let newWindowOrigin = NSPoint(x: windowFrame.origin.x - deltaX,
                                  y: windowFrame.origin.y - deltaY)

    // Move window if needed to make sure the window is not offscreen
    let newWindowFrame = NSRect(origin: newWindowOrigin, size: newWindowSize).constrain(in: containerFrame)
    return self.clone(windowFrame: newWindowFrame)
  }

  func resizeOutsidePanels(newTopHeight: CGFloat? = nil, newTrailingWidth: CGFloat? = nil, newBottomHeight: CGFloat? = nil, newLeadingWidth: CGFloat? = nil) -> MainWindowGeometry {

    var ΔW: CGFloat = 0
    var ΔH: CGFloat = 0
    var ΔX: CGFloat = 0
    var ΔY: CGFloat = 0
    if let newTopHeight = newTopHeight {
      let ΔTop = abs(newTopHeight) - self.topPanelHeight
      ΔH += ΔTop
    }
    if let newTrailingWidth = newTrailingWidth {
      let ΔRight = abs(newTrailingWidth) - self.rightPanelWidth
      ΔW += ΔRight
    }
    if let newBottomHeight = newBottomHeight {
      let ΔBottom = abs(newBottomHeight) - self.bottomPanelHeight
      ΔH += ΔBottom
      ΔY -= ΔBottom
    }
    if let newLeadingWidth = newLeadingWidth {
      let ΔLeft = abs(newLeadingWidth) - self.leftPanelWidth
      ΔW += ΔLeft
      ΔX -= ΔLeft
    }
    let newWindowFrame = CGRect(x: windowFrame.origin.x + ΔX,
                                y: windowFrame.origin.y + ΔY,
                                width: windowFrame.width + ΔW,
                                height: windowFrame.height + ΔH)
    return MainWindowGeometry(windowFrame: newWindowFrame,
                              topPanelHeight: newTopHeight ?? self.topPanelHeight,
                              rightPanelWidth: newTrailingWidth ?? self.rightPanelWidth,
                              bottomPanelHeight: newBottomHeight ?? self.bottomPanelHeight,
                              leftPanelWidth: newLeadingWidth ?? self.leftPanelWidth)
  }
}
