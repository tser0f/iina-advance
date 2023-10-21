//
//  InteractiveModeGeometry.swift
//  iina
//
//  Created by Matt Svoboda on 10/18/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

struct BoxQuad {
  let top: CGFloat
  let trailing: CGFloat
  let bottom: CGFloat
  let leading: CGFloat

  var totalWidth: CGFloat {
    return leading + trailing
  }

  var totalHeight: CGFloat {
    return top + bottom
  }
}

/**
 `InteractiveModeGeometry`
 Useful for representing a player window which is in interactive mode.
 Unlike `MusicModeGeometry`, instances of this class can be converted both to and from an instance of `PlayerWindowGeometry`.
 */
struct InteractiveModeGeometry: Equatable {
  static let interactiveModeBottomBarHeight: CGFloat = 68
  static let outsideTopBarHeight = PlayerWindowController.standardTitleBarHeight

  // Window's top bezel must be at least as large as the title bar so that dragging the top of crop doesn't drag the window too
  static let videobox = BoxQuad(top: PlayerWindowController.standardTitleBarHeight, trailing: 24,
                                bottom: PlayerWindowController.standardTitleBarHeight, leading: 24)

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

  var outsideTopBarHeight: CGFloat {
    return InteractiveModeGeometry.outsideTopBarHeight
  }

  var outsideBottomBarHeight: CGFloat {
    return InteractiveModeGeometry.interactiveModeBottomBarHeight
  }

  var videoSize: NSSize {
    let videobox = InteractiveModeGeometry.videobox
    return NSSize(width: windowFrame.width - videobox.totalWidth,
                  height: windowFrame.height - videobox.totalHeight - outsideBottomBarHeight - outsideTopBarHeight)
  }

  /// Converts to equivalent `PlayerWindowGeometry`.
  func toPlayerWindowGeometry() -> PlayerWindowGeometry {
    assert(fitOption != .legacyFullScreen && fitOption != .nativeFullScreen, "toPlayerWindowGeometry(): do not use for full screen!")
    return PlayerWindowGeometry(windowFrame: windowFrame,
                                screenID: screenID,
                                fitOption: fitOption,
                                topMarginHeight: 0,
                                outsideTopBarHeight: outsideTopBarHeight,
                                outsideTrailingBarWidth: 0,
                                outsideBottomBarHeight: outsideBottomBarHeight,
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
    // Close sidebars. Top and bottom bars are resized for interactive mode controls
    var newGeo = windowedModeGeometry.withResizedOutsideBars(newOutsideTopBarHeight: InteractiveModeGeometry.outsideTopBarHeight,
                                                             newOutsideTrailingBarWidth: 0,
                                                             newOutsideBottomBarHeight: InteractiveModeGeometry.interactiveModeBottomBarHeight,
                                                             newOutsideLeadingBarWidth: 0)

    let videobox = InteractiveModeGeometry.videobox
    // Desired viewport is current one but shrunk with fixed margin around video
    let maxViewportSize = NSSize(width: newGeo.viewportSize.width - videobox.totalWidth,
                                 height: newGeo.viewportSize.height - videobox.totalHeight)
    let newVideoSize = PlayerWindowGeometry.computeVideoSize(withAspectRatio: windowedModeGeometry.videoAspectRatio, toFillIn: maxViewportSize)
    let desiredViewportSize = NSSize(width: newVideoSize.width + videobox.totalWidth,
                                     height: newVideoSize.height + videobox.totalHeight)
    // This will constrain in screen
    newGeo = newGeo.scaleViewport(to: desiredViewportSize).clone(insideTopBarHeight: 0, insideTrailingBarWidth: 0,
                                                                 insideBottomBarHeight: 0, insideLeadingBarWidth: 0,
                                                                 videoSize: newVideoSize)

    return InteractiveModeGeometry.from(newGeo)
  }

}
