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
struct InteractiveModeGeometry {
  // Need enough space to display all the buttons at the bottom:
  static let minWindowWidth: CGFloat = 450
  static let outsideBottomBarHeight: CGFloat = 68
  // Show title bar only in windowed mode
  static let outsideTopBarHeight = PlayerWindowController.standardTitleBarHeight

  // Window's top bezel must be at least as large as the title bar so that dragging the top of crop doesn't drag the window too
  static let videobox = BoxQuad(top: PlayerWindowController.standardTitleBarHeight, trailing: 24,
                                bottom: PlayerWindowController.standardTitleBarHeight, leading: 24)

  // Transition windowed mode geometry to Interactive Mode geometry. Note that this is not a direct conversion; it will modify the view sizes
  static func enterInteractiveMode(from windowedModeGeometry: PlayerWindowGeometry) -> PlayerWindowGeometry {
    assert(windowedModeGeometry.fitOption != .legacyFullScreen && windowedModeGeometry.fitOption != .nativeFullScreen)
    // Close sidebars. Top and bottom bars are resized for interactive mode controls
    let newGeo = windowedModeGeometry.withResizedOutsideBars(newOutsideTopBarHeight: InteractiveModeGeometry.outsideTopBarHeight,
                                                             newOutsideTrailingBarWidth: 0,
                                                             newOutsideBottomBarHeight: InteractiveModeGeometry.outsideBottomBarHeight,
                                                             newOutsideLeadingBarWidth: 0)

    let viewportMargins = InteractiveModeGeometry.videobox
    // Desired viewport is current one but shrunk with fixed margin around video
    var newVideoSize = PlayerWindowGeometry.computeVideoSize(withAspectRatio: windowedModeGeometry.videoAspectRatio, toFillIn: windowedModeGeometry.viewportSize, excludingMargins: viewportMargins)

    // Enforce min width for interactive mode window
    let minVideoWidth = InteractiveModeGeometry.minWindowWidth - viewportMargins.totalWidth
    if newVideoSize.width < minVideoWidth {
      newVideoSize = NSSize(width: minVideoWidth, height: round(minVideoWidth / windowedModeGeometry.videoAspectRatio))
    }

    let desiredViewportSize = NSSize(width: newVideoSize.width + viewportMargins.totalWidth,
                                     height: newVideoSize.height + viewportMargins.totalHeight)
    // This will constrain in screen
    return newGeo.clone(insideTopBarHeight: 0, insideTrailingBarWidth: 0,
                        insideBottomBarHeight: 0, insideLeadingBarWidth: 0,
                        viewportMargins: viewportMargins).scaleViewport(to: desiredViewportSize)
  }

}
