//
//  MainWindowGeometry.swift
//  iina
//
//  Created by Matt Svoboda on 7/11/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/**
 ┌─────────────────────────────────────────┐
 │`windowFrame`        ▲                   │
 │                     │`topBarHeight`     │
 │                     ▼                   │
 ├──────────────┬──────────┬───────────────┤
 │              │  Video   │               │
 │◄────────────►│   Frame  │◄─────────────►│
 │`leftBarWidth`│          │`rightBarWidth`│
 ├──────────────┴──────────┴───────────────┤
 │                 ▲                       │
 │                 │`bottomBarHeight`      │
 │                 ▼                       │
 └─────────────────────────────────────────┘
 */
struct MainWindowGeometry: Equatable {
  // MARK: - Stored properties

  let windowFrame: NSRect

  // Outside panels
  let topBarHeight: CGFloat
  let rightBarWidth: CGFloat
  let bottomBarHeight: CGFloat
  let leftBarWidth: CGFloat

  let videoAspectRatio: CGFloat

  // MARK: - Initializers

  init(windowFrame: NSRect, topBarHeight: CGFloat, rightBarWidth: CGFloat, bottomBarHeight: CGFloat, leftBarWidth: CGFloat, videoAspectRatio: CGFloat) {
    assert(topBarHeight >= 0, "Expected topBarHeight > 0, found \(topBarHeight)")
    assert(rightBarWidth >= 0, "Expected rightBarWidth > 0, found \(rightBarWidth)")
    assert(bottomBarHeight >= 0, "Expected bottomBarHeight > 0, found \(bottomBarHeight)")
    assert(leftBarWidth >= 0, "Expected leftBarWidth > 0, found \(leftBarWidth)")
    assert(rightBarWidth >= 0, "Expected rightBarWidth > 0, found \(rightBarWidth)")
    self.windowFrame = windowFrame
    self.topBarHeight = topBarHeight
    self.rightBarWidth = rightBarWidth
    self.bottomBarHeight = bottomBarHeight
    self.leftBarWidth = leftBarWidth
    self.videoAspectRatio = videoAspectRatio
  }

  init(windowFrame: CGRect, videoFrame: CGRect, videoAspectRatio: CGFloat) {
    assert(videoFrame.height <= windowFrame.height, "videoFrame.height (\(videoFrame.height)) cannot be larger than windowFrame.height (\(windowFrame.height))")
    assert(videoFrame.width <= windowFrame.width, "videoFrame.width (\(videoFrame.width)) cannot be larger than windowFrame.width (\(windowFrame.width))")

    let leftBarWidth = videoFrame.origin.x
    let bottomBarHeight = videoFrame.origin.y
    let rightBarWidth = windowFrame.width - videoFrame.width - leftBarWidth
    let topBarHeight = windowFrame.height - videoFrame.height - bottomBarHeight
    self.init(windowFrame: windowFrame,
              topBarHeight: topBarHeight, rightBarWidth: rightBarWidth,
              bottomBarHeight: bottomBarHeight, leftBarWidth: leftBarWidth,
              videoAspectRatio: videoAspectRatio)
  }

  // MARK: - Derived properties

  var videoSize: NSSize {
    return NSSize(width: windowFrame.width - rightBarWidth - leftBarWidth,
                  height: windowFrame.height - topBarHeight - bottomBarHeight)
  }

  var videoFrameInScreenCoords: NSRect {
    return NSRect(origin: CGPoint(x: windowFrame.origin.x + leftBarWidth, y: windowFrame.origin.y + bottomBarHeight), size: videoSize)
  }

  var outsideBarsTotalSize: NSSize {
    return NSSize(width: rightBarWidth + leftBarWidth, height: topBarHeight + bottomBarHeight)
  }

  func clone(windowFrame: NSRect? = nil,
             topBarHeight: CGFloat? = nil, rightBarWidth: CGFloat? = nil,
             bottomBarHeight: CGFloat? = nil, leftBarWidth: CGFloat? = nil,
             videoAspectRatio: CGFloat? = nil) -> MainWindowGeometry {

    return MainWindowGeometry(windowFrame: windowFrame ?? self.windowFrame,
                              topBarHeight: topBarHeight ?? self.topBarHeight,
                              rightBarWidth: rightBarWidth ?? self.rightBarWidth,
                              bottomBarHeight: bottomBarHeight ?? self.bottomBarHeight,
                              leftBarWidth: leftBarWidth ?? self.leftBarWidth,
                              videoAspectRatio: videoAspectRatio ?? self.videoAspectRatio)
  }

  private func computeMaxVideoSize(in containerSize: NSSize) -> NSSize {
    // Resize only the video. Panels outside the video do not change size.
    // To do this, subtract the "outside" panels from the container frame
    let outsideBarsSize = self.outsideBarsTotalSize
    return NSSize(width: containerSize.width - outsideBarsSize.width,
                  height: containerSize.height - outsideBarsSize.height)
  }

  func constrainWithin(_ containerFrame: NSRect) -> MainWindowGeometry {
    return scale(desiredVideoSize: self.videoSize, constrainedWithin: containerFrame)
  }

  func scale(desiredVideoSize: NSSize, constrainedWithin containerFrame: NSRect) -> MainWindowGeometry {
    Logger.log("Scaling MainWindowGeometry desiredVideoSize:\(desiredVideoSize)", level: .debug)
    var newVideoSize = desiredVideoSize

    /// Enforce `videoView.aspectRatio`: Recalculate height, trying to preserve width
    newVideoSize = NSSize(width: desiredVideoSize.width, height: desiredVideoSize.width / videoAspectRatio)
    Logger.log("Enforced aspectRatio, newVideoSize:\(newVideoSize)", level: .verbose)

    /// Clamp video between max and min video sizes, maintaining aspect ratio of `desiredVideoSize`.
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
    if newVideoSize.height < AppData.minVideoSize.height {
      newVideoSize = newVideoSize.satisfyMinSizeWithSameAspectRatio(AppData.minVideoSize)
    }
    if newVideoSize.width < AppData.minVideoSize.width {
      newVideoSize = newVideoSize.satisfyMinSizeWithSameAspectRatio(AppData.minVideoSize)
    }

    newVideoSize = NSSize(width: newVideoSize.width, height: newVideoSize.height)

    let outsideBarsSize = self.outsideBarsTotalSize
    let newWindowSize = NSSize(width: round(newVideoSize.width + outsideBarsSize.width),
                               height: round(newVideoSize.height + outsideBarsSize.height))

    // Round the results to prevent excessive window drift due to small imprecisions in calculation
    let deltaX = round((newVideoSize.width - videoSize.width) / 2)
    let deltaY = round((newVideoSize.height - videoSize.height) / 2)
    let newWindowOrigin = NSPoint(x: windowFrame.origin.x - deltaX,
                                  y: windowFrame.origin.y - deltaY)

    // Move window if needed to make sure the window is not offscreen
    let newWindowFrame = NSRect(origin: newWindowOrigin, size: newWindowSize).constrain(in: containerFrame)
    return self.clone(windowFrame: newWindowFrame)
  }

  func resizeOutsideBars(newTopHeight: CGFloat? = nil, newTrailingWidth: CGFloat? = nil, newBottomHeight: CGFloat? = nil, newLeadingWidth: CGFloat? = nil) -> MainWindowGeometry {

    var ΔW: CGFloat = 0
    var ΔH: CGFloat = 0
    var ΔX: CGFloat = 0
    var ΔY: CGFloat = 0
    if let newTopHeight = newTopHeight {
      let ΔTop = abs(newTopHeight) - self.topBarHeight
      ΔH += ΔTop
    }
    if let newTrailingWidth = newTrailingWidth {
      let ΔRight = abs(newTrailingWidth) - self.rightBarWidth
      ΔW += ΔRight
    }
    if let newBottomHeight = newBottomHeight {
      let ΔBottom = abs(newBottomHeight) - self.bottomBarHeight
      ΔH += ΔBottom
      ΔY -= ΔBottom
    }
    if let newLeadingWidth = newLeadingWidth {
      let ΔLeft = abs(newLeadingWidth) - self.leftBarWidth
      ΔW += ΔLeft
      ΔX -= ΔLeft
    }
    let newWindowFrame = CGRect(x: windowFrame.origin.x + ΔX,
                                y: windowFrame.origin.y + ΔY,
                                width: windowFrame.width + ΔW,
                                height: windowFrame.height + ΔH)
    return self.clone(windowFrame: newWindowFrame, topBarHeight: newTopHeight, rightBarWidth: newTrailingWidth,
                      bottomBarHeight: newBottomHeight, leftBarWidth: newLeadingWidth)
  }
}
