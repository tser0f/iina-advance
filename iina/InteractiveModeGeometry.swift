//
//  InteractiveModeGeometry.swift
//  iina
//
//  Created by Matt Svoboda on 10/18/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/**
 `InteractiveModeGeometry`
 Useful for representing a player window which is in interactive mode.
 Unlike `MusicModeGeometry`, instances of this class can be converted both to and from an instance of `PlayerWindowGeometry`.
 */
struct InteractiveModeGeometry: Equatable {
  static let interactiveModeBottomBarHeight: CGFloat = 68
  // Window's top bezel must be at least as large as the title bar so that dragging the top of crop doesn't drag the window too
  static let paddingBottom: CGFloat = PlayerWindowController.standardTitleBarHeight
  static let paddingTop: CGFloat = paddingBottom
  static let paddingLeading: CGFloat = 24
  static let paddingTrailing: CGFloat = paddingLeading

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
    return NSSize(width: windowFrame.width - InteractiveModeGeometry.paddingLeading - InteractiveModeGeometry.paddingTrailing,
                  height: windowFrame.height - InteractiveModeGeometry.paddingTop - InteractiveModeGeometry.paddingBottom - InteractiveModeGeometry.interactiveModeBottomBarHeight)
  }

  /// Converts to equivalent `PlayerWindowGeometry`.
  func toPlayerWindowGeometry() -> PlayerWindowGeometry {
    return PlayerWindowGeometry(windowFrame: windowFrame,
                                screenID: screenID,
                                fitOption: fitOption,
                                topMarginHeight: 0,
                                outsideTopBarHeight: 0,
                                outsideTrailingBarWidth: 0,
                                outsideBottomBarHeight: InteractiveModeGeometry.interactiveModeBottomBarHeight,
                                outsideLeadingBarWidth: 0,
                                insideTopBarHeight: 0,
                                insideTrailingBarWidth: 0,
                                insideBottomBarHeight: 0,
                                insideLeadingBarWidth: 0,
                                videoAspectRatio: videoAspectRatio,
                                videoSize: videoSize)
  }

  /// Converts from equivalent `PlayerWindowGeometry`.
  /// Do not use this to "enter" interactive mode. For that, see `InteractiveModeGeometry.enterInteractiveMode()`.
  static func from(_ pwGeo: PlayerWindowGeometry) -> InteractiveModeGeometry {
    return InteractiveModeGeometry(windowFrame: pwGeo.windowFrame, screenID: pwGeo.screenID,
                                   fitOption: pwGeo.fitOption, videoAspectRatio: pwGeo.videoAspectRatio)
  }

  // Transition windowed mode geometry to Interactive Mode geometry. Note that this is not the same
  static func enterInteractiveMode(from windowedModeGeometry: PlayerWindowGeometry) -> InteractiveModeGeometry {
    assert(windowedModeGeometry.fitOption != .legacyFullScreen && windowedModeGeometry.fitOption != .nativeFullScreen)
    // Close all outside bars except bottom
    var newGeo = windowedModeGeometry.withResizedOutsideBars(newOutsideTopBarHeight: 0,
                                                             newOutsideTrailingBarWidth: 0,
                                                             newOutsideBottomBarHeight: InteractiveModeGeometry.interactiveModeBottomBarHeight,
                                                             newOutsideLeadingBarWidth: 0)

    // Desired viewport is current one but shrunk with fixed margin around video
    let maxViewportSize = NSSize(width: newGeo.viewportSize.width - paddingLeading - paddingTrailing,
                                 height: newGeo.viewportSize.height - paddingBottom - paddingTop)
    let newVideoSize = PlayerWindowGeometry.computeVideoSize(withAspectRatio: windowedModeGeometry.videoAspectRatio, toFillIn: maxViewportSize)
    let desiredViewportSize = NSSize(width: newVideoSize.width + paddingLeading + paddingTrailing,
                                     height: newVideoSize.height + paddingBottom + paddingTop)
    // This will constrain in screen
    newGeo = newGeo.scaleViewport(to: desiredViewportSize).clone(insideTopBarHeight: 0, insideTrailingBarWidth: 0,
                                                                 insideBottomBarHeight: 0, insideLeadingBarWidth: 0,
                                                                 videoSize: newVideoSize)

    return InteractiveModeGeometry.from(newGeo)
  }

}
