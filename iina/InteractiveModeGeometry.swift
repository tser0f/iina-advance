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
  // Need enough space to display all the buttons at the bottom:
  static let minWindowWidth: CGFloat = 450
  static let outsideBottomBarHeight: CGFloat = 68
  // Show title bar only in windowed mode
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

  // In windowed mode, the top bar is used to hold the title bar.
  // In full screen, it is 0.
  var outsideTopBarHeight: CGFloat {
    switch fitOption {
    case .noConstraints, .keepInVisibleScreen, .centerInVisibleScreen:
      return InteractiveModeGeometry.outsideTopBarHeight
    case .legacyFullScreen, .nativeFullScreen:
      return 0
    }
  }

  /// Returns `0` unless in legacy full screen mode in a screen with camera housing
  var topMarginHeight: CGFloat {
    switch fitOption {
    case .noConstraints, .keepInVisibleScreen, .centerInVisibleScreen, .nativeFullScreen:
      return 0
    case .legacyFullScreen:
      let screen = NSScreen.getScreenOrDefault(screenID: screenID)
      return screen.cameraHousingHeight ?? 0
    }
  }

  var outsideBottomBarHeight: CGFloat {
    return InteractiveModeGeometry.outsideBottomBarHeight
  }

  var videoSize: NSSize {
    let videobox = InteractiveModeGeometry.videobox
    let maxVideoSize =  NSSize(width: windowFrame.width - videobox.totalWidth,
                               height: windowFrame.height - videobox.totalHeight - outsideBottomBarHeight - outsideTopBarHeight - topMarginHeight)
    switch fitOption {
    case .noConstraints, .keepInVisibleScreen, .centerInVisibleScreen:
      return maxVideoSize
    case .legacyFullScreen, .nativeFullScreen:
      return PlayerWindowGeometry.computeVideoSize(withAspectRatio: videoAspectRatio, toFillIn: maxVideoSize)
    }
  }

  /// Converts to equivalent `PlayerWindowGeometry`.
  func toPlayerWindowGeometry() -> PlayerWindowGeometry {
    return PlayerWindowGeometry(windowFrame: windowFrame,
                                screenID: screenID,
                                fitOption: fitOption,
                                topMarginHeight: topMarginHeight,
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

  // Transition windowed mode geometry to Interactive Mode geometry. Note that this is not a direct conversion; it will modify the view sizes
  static func enterInteractiveMode(from windowedModeGeometry: PlayerWindowGeometry) -> InteractiveModeGeometry {
    assert(windowedModeGeometry.fitOption != .legacyFullScreen && windowedModeGeometry.fitOption != .nativeFullScreen)
    // Close sidebars. Top and bottom bars are resized for interactive mode controls
    var newGeo = windowedModeGeometry.withResizedOutsideBars(newOutsideTopBarHeight: InteractiveModeGeometry.outsideTopBarHeight,
                                                             newOutsideTrailingBarWidth: 0,
                                                             newOutsideBottomBarHeight: InteractiveModeGeometry.outsideBottomBarHeight,
                                                             newOutsideLeadingBarWidth: 0)

    let videobox = InteractiveModeGeometry.videobox
    // Desired viewport is current one but shrunk with fixed margin around video
    let maxViewportSize = NSSize(width: newGeo.viewportSize.width - videobox.totalWidth,
                                 height: newGeo.viewportSize.height - videobox.totalHeight)
    var newVideoSize = PlayerWindowGeometry.computeVideoSize(withAspectRatio: windowedModeGeometry.videoAspectRatio, toFillIn: maxViewportSize)

    // Enforce min width
    let minVideoWidth = InteractiveModeGeometry.minWindowWidth - videobox.totalWidth
    if newVideoSize.width < minVideoWidth {
      newVideoSize = NSSize(width: minVideoWidth, height: minVideoWidth / windowedModeGeometry.videoAspectRatio)
    }

    let desiredViewportSize = NSSize(width: newVideoSize.width + videobox.totalWidth,
                                     height: newVideoSize.height + videobox.totalHeight)
    // This will constrain in screen
    newGeo = newGeo.scaleViewport(to: desiredViewportSize).clone(insideTopBarHeight: 0, insideTrailingBarWidth: 0,
                                                                 insideBottomBarHeight: 0, insideLeadingBarWidth: 0,
                                                                 videoSize: newVideoSize)

    return InteractiveModeGeometry.from(newGeo)
  }

  /// Here, `videoSizeUnscaled` and `cropbox` must be the same scale, which may be different than `self.videoSize`.
  /// The cropbox is the section of the video rect which remains after the crop. Its origin is the lower left of the video.
  func cropVideo(from videoSizeUnscaled: NSSize, to cropbox: NSRect) -> InteractiveModeGeometry {
    // First scale the cropbox to the current window scale
    let scaleRatio = self.videoSize.width / videoSizeUnscaled.width
    let cropboxScaled = NSRect(x: cropbox.origin.x * scaleRatio,
                               y: cropbox.origin.y * scaleRatio,
                               width: cropbox.width * scaleRatio,
                               height: cropbox.height * scaleRatio)

    let videoSize = videoSize
    if cropboxScaled.origin.x > videoSize.width || cropboxScaled.origin.y > videoSize.height {
      Logger.log("Cannot crop video: the cropbox completely outside the video! CropboxScaled: \(cropboxScaled), videoSize: \(videoSize)", level: .error)
      return self
    }
    Logger.log("Cropping InteractiveModeGeometry from cropbox: \(cropbox), scaled: \(scaleRatio)x -> \(cropboxScaled)")

    let widthRemoved = videoSize.width - cropboxScaled.width
    let heightRemoved = videoSize.height - cropboxScaled.height
    let newWindowFrame = NSRect(x: windowFrame.origin.x + cropboxScaled.origin.x,
                                y: windowFrame.origin.y + cropboxScaled.origin.y,
                                width: windowFrame.width - widthRemoved,
                                height: windowFrame.height - heightRemoved)

    let newVideoAspectRatio = cropbox.size.aspect
    Logger.log("Cropped InteractiveModeGeometry to new windowFrame: \(newWindowFrame), videoAspectRatio: \(newVideoAspectRatio), screenID: \(screenID), fitOption: \(fitOption)")
    return InteractiveModeGeometry(windowFrame: newWindowFrame, screenID: screenID, fitOption: fitOption, videoAspectRatio: newVideoAspectRatio)
  }
}
