//
//  InteractiveModeGeometry.swift
//  iina
//
//  Created by Matt Svoboda on 10/18/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

fileprivate let interactiveModeBottomBarHeight: CGFloat = 60
// VideoView's top bezel must be at least as large as the title bar so that dragging the top of crop doesn't drag the window too
// the max region that the video view can occupy
fileprivate let pad = PlayerWindowController.standardTitleBarHeight
fileprivate let paddingBottom: CGFloat = interactiveModeBottomBarHeight + pad
fileprivate let paddingTop: CGFloat = pad
fileprivate let paddingSide: CGFloat = pad

/**
 `InteractiveModeGeometry`
 Useful for representing a player window which is in interactive mode.
 Unlike `MusicModeGeometry`, instances of this class can be converted both to and from an instance of `PlayerWindowGeometry`.
 */
struct InteractiveModeGeometry: Equatable {
  let windowFrame: NSRect
  let screenID: String
  let fitOption: ScreenFitOption
  let videoAspectRatio: CGFloat

  init(windowFrame: NSRect, screenID: String, fitOption: ScreenFitOption, videoAspectRatio: CGFloat) {
    self.windowFrame = windowFrame
    self.screenID = screenID
    self.fitOption = fitOption
    self.videoAspectRatio = videoAspectRatio
  }

  var videoSize: NSSize {
    return NSSize(width: windowFrame.width - paddingSide - paddingSide,
                  height: windowFrame.height - paddingBottom - paddingTop)
  }

  var viewportSize: NSSize {
    return PlayerWindowGeometry.computeViewportSize(from: windowFrame, topMarginHeight: 0, 
                                                    outsideTopBarHeight: 0, outsideTrailingBarWidth: 0,
                                                    outsideBottomBarHeight: interactiveModeBottomBarHeight, outsideLeadingBarWidth: 0)
  }

  func toPlayerWindowGeometry() -> PlayerWindowGeometry {
    return PlayerWindowGeometry(windowFrame: windowFrame,
                                screenID: screenID,
                                fitOption: .insideVisibleFrame,
                                topMarginHeight: 0,
                                outsideTopBarHeight: 0,
                                outsideTrailingBarWidth: 0,
                                outsideBottomBarHeight: interactiveModeBottomBarHeight,
                                outsideLeadingBarWidth: 0,
                                insideTopBarHeight: 0,
                                insideTrailingBarWidth: 0,
                                insideBottomBarHeight: 0,
                                insideLeadingBarWidth: 0,
                                videoAspectRatio: videoAspectRatio,
                                videoSize: videoSize)
  }

  static func from(_ pwGeo: PlayerWindowGeometry) -> InteractiveModeGeometry {
    let videoFrame = pwGeo.videoFrameInScreenCoords
    let windowOrigin = CGPoint(x: videoFrame.origin.x + paddingSide, y: videoFrame.origin.y + paddingBottom)
    let windowSize = CGSize(width: videoFrame.width + paddingSide + paddingSide, height: videoFrame.height + paddingBottom + paddingTop)
    let windowFrame = NSRect(origin: windowOrigin,
                             size: windowSize)
    return InteractiveModeGeometry(windowFrame: windowFrame, screenID: pwGeo.screenID, fitOption: pwGeo.fitOption, videoAspectRatio: pwGeo.videoAspectRatio)
  }
}
