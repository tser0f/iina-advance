//
//  MusicModeGeometry.swift
//  iina
//
//  Created by Matt Svoboda on 9/18/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/**
 `MusicModeGeometry`
 */
struct MusicModeGeometry: Equatable, CustomStringConvertible {
  let windowFrame: NSRect
  let screenID: String
  let playlistHeight: CGFloat  /// indicates playlist height whether or not `isPlaylistVisible`
  let isVideoVisible: Bool
  let isPlaylistVisible: Bool
  let videoAspectRatio: CGFloat

  init(windowFrame: NSRect, screenID: String, playlistHeight: CGFloat, 
       isVideoVisible: Bool, isPlaylistVisible: Bool, videoAspectRatio: CGFloat) {
    self.windowFrame = windowFrame
    self.screenID = screenID
    if isPlaylistVisible {
      /// Ignore given `playlistHeight` and calculate it from the other params
      let videoHeight = isVideoVisible ? round(windowFrame.width / videoAspectRatio) : 0
      let controlViewHeight = MiniPlayerController.controlViewHeight
      self.playlistHeight = windowFrame.height - controlViewHeight - videoHeight
    } else {
      /// Sometimes `playlistHeight` can fall slightly below due to rounding errors. Just correct it:
      self.playlistHeight = max(playlistHeight, MiniPlayerController.PlaylistMinHeight)
    }
    self.isVideoVisible = isVideoVisible
    self.isPlaylistVisible = isPlaylistVisible
    self.videoAspectRatio = videoAspectRatio
  }

  func clone(windowFrame: NSRect? = nil, screenID: String? = nil, playlistHeight: CGFloat? = nil,
             isVideoVisible: Bool? = nil, isPlaylistVisible: Bool? = nil,
             videoAspectRatio: CGFloat? = nil) -> MusicModeGeometry {
    return MusicModeGeometry(windowFrame: windowFrame ?? self.windowFrame,
                             screenID: screenID ?? self.screenID,
                             // if playlist is visible, this will be ignored and recalculated in the constructor
                             playlistHeight: playlistHeight ?? self.playlistHeight,
                             isVideoVisible: isVideoVisible ?? self.isVideoVisible,
                             isPlaylistVisible: isPlaylistVisible ?? self.isPlaylistVisible,
                             videoAspectRatio: videoAspectRatio ?? self.videoAspectRatio)
  }

  func toPlayerWindowGeometry() -> PlayerWindowGeometry {
    let outsideBottomBarHeight = MiniPlayerController.controlViewHeight + (isPlaylistVisible ? playlistHeight : 0)
    return PlayerWindowGeometry(windowFrame: windowFrame,
                                screenID: screenID,
                                fitOption: .keepInVisibleScreen,
                                topMarginHeight: 0,
                                outsideTopBarHeight: 0,
                                outsideTrailingBarWidth: 0,
                                outsideBottomBarHeight: outsideBottomBarHeight,
                                outsideLeadingBarWidth: 0,
                                insideTopBarHeight: 0,
                                insideTrailingBarWidth: 0,
                                insideBottomBarHeight: 0,
                                insideLeadingBarWidth: 0,
                                videoAspectRatio: videoAspectRatio,
                                videoSize: videoSize ?? NSSize(width: windowFrame.width, height: 0))
  }

  var videoHeightIfVisible: CGFloat {
    let videoHeightByDivision = round(windowFrame.width / videoAspectRatio)
    let otherControlsHeight = MiniPlayerController.controlViewHeight + playlistHeight
    let videoHeightBySubtraction = windowFrame.height - otherControlsHeight
    // Align to other controls if within 1 px to smooth out division imprecision
    if abs(videoHeightByDivision - videoHeightBySubtraction) < 1 {
      return videoHeightBySubtraction
    }
    return videoHeightByDivision
  }

  var videoSize: NSSize? {
    guard isVideoVisible else { return nil }
    return NSSize(width: windowFrame.width, height: videoHeightIfVisible)
  }

  var viewportSize: NSSize? {
    return videoSize
  }

  var videoHeight: CGFloat {
    return isVideoVisible ? videoHeightIfVisible : 0
  }

  var bottomBarHeight: CGFloat {
    return windowFrame.height - videoHeight
  }

  func hasEqual(windowFrame windowFrame2: NSRect? = nil, videoSize videoSize2: NSSize? = nil) -> Bool {
    return PlayerWindowGeometry.areEqual(windowFrame1: windowFrame, windowFrame2: windowFrame2, videoSize1: videoSize, videoSize2: videoSize2)
  }

  /// The MiniPlayerWindow's width must be between `MiniPlayerMinWidth` and `Preference.musicModeMaxWidth`.
  /// It is composed of up to 3 vertical sections:
  /// 1. `videoWrapperView`: Visible if `isVideoVisible` is true). Scales with the aspect ratio of its video
  /// 2. `backgroundView`: Visible always. Fixed height
  /// 3. `playlistWrapperView`: Visible if `isPlaylistVisible` is true. Height is user resizable, and must be >= `PlaylistMinHeight`
  /// Must also ensure that window stays within the bounds of the screen it is in. Almost all of the time the window  will be
  /// height-bounded instead of width-bounded.
  func refit() -> MusicModeGeometry {
    let containerFrame = PlayerWindowGeometry.getContainerFrame(forScreenID: screenID, fitOption: .keepInVisibleScreen)!

    /// When the window's width changes, the video scales to match while keeping its aspect ratio,
    /// and the control bar (`backgroundView`) and playlist are pushed down.
    /// Calculate the maximum width/height the art can grow to so that `backgroundView` is not pushed off the screen.
    let minPlaylistHeight = isPlaylistVisible ? MiniPlayerController.PlaylistMinHeight : 0

    var maxWidth: CGFloat
    if isVideoVisible {
      var maxVideoHeight = containerFrame.height - MiniPlayerController.controlViewHeight - minPlaylistHeight
      /// `maxVideoHeight` can be negative if very short screen! Fall back to height based on `MiniPlayerMinWidth` if needed
      maxVideoHeight = max(maxVideoHeight, round(MiniPlayerController.minWindowWidth / videoAspectRatio))
      maxWidth = round(maxVideoHeight * videoAspectRatio)
    } else {
      maxWidth = MiniPlayerController.maxWindowWidth
    }
    maxWidth = min(maxWidth, containerFrame.width)

    // Determine width first
    let newWidth: CGFloat
    let requestedSize = windowFrame.size
    if requestedSize.width < MiniPlayerController.minWindowWidth {
      // Clamp to min width
      newWidth = MiniPlayerController.minWindowWidth
    } else if requestedSize.width > maxWidth {
      // Clamp to max width
      newWidth = maxWidth
    } else {
      // Requested size is valid
      newWidth = requestedSize.width
    }

    // Now determine height
    let videoHeight = isVideoVisible ? round(newWidth / videoAspectRatio) : 0
    let minWindowHeight = videoHeight + MiniPlayerController.controlViewHeight + minPlaylistHeight
    // Make sure height is within acceptable values
    var newHeight = max(requestedSize.height, minWindowHeight)
    let maxHeight = isPlaylistVisible ? containerFrame.height : minWindowHeight
    newHeight = min(newHeight, maxHeight)
    let newWindowSize = NSSize(width: newWidth, height: newHeight)
    Logger.log("Constraining miniPlayer. Video=\(isVideoVisible.yn) Playlist=\(isPlaylistVisible.yn) VideoAspect=\(videoAspectRatio.stringTrunc2f), ReqSize=\(requestedSize), NewSize=\(newWindowSize)", level: .verbose)

    let newWindowFrame = NSRect(origin: windowFrame.origin, size: newWindowSize).constrain(in: containerFrame)
    return self.clone(windowFrame: newWindowFrame)
  }

  func scaleVideo(to desiredSize: NSSize? = nil,
                     screenID: String? = nil) -> MusicModeGeometry? {

    guard isVideoVisible else {
      Logger.log("Cannot scale video of MiniPlayer: isVideoVisible=\(isVideoVisible.yesno)", level: .error)
      return nil
    }

    let newVideoSize = desiredSize ?? videoSize!
    Logger.log("Scaling MiniPlayer, newVideoSize: \(newVideoSize)", level: .verbose)

    let newScreenID = screenID ?? self.screenID
    let screenFrame: NSRect = PlayerWindowGeometry.getContainerFrame(forScreenID: newScreenID, fitOption: .keepInVisibleScreen)!

    // Window height should not change. Only video size should be scaled
    let windowHeight = min(screenFrame.height, windowFrame.height)

    // Constrain desired width within min and max allowed, then recalculate height from new value
    var newVideoWidth = newVideoSize.width
    newVideoWidth = max(newVideoWidth, MiniPlayerController.minWindowWidth)
    newVideoWidth = min(newVideoWidth, MiniPlayerController.maxWindowWidth)
    newVideoWidth = min(newVideoWidth, screenFrame.width)

    var newVideoHeight = newVideoWidth / videoAspectRatio

    let minPlaylistHeight: CGFloat = isPlaylistVisible ? MiniPlayerController.PlaylistMinHeight : 0
    let minBottomBarHeight: CGFloat = MiniPlayerController.controlViewHeight + minPlaylistHeight
    let maxVideoHeight = windowHeight - minBottomBarHeight
    if newVideoHeight > maxVideoHeight {
      newVideoHeight = maxVideoHeight
      newVideoWidth = newVideoHeight * videoAspectRatio
    }

    var newOriginX = windowFrame.origin.x

    // Determine which X direction to scale towards by checking which side of the screen it's closest to
    let distanceToLeadingSideOfScreen = abs(abs(windowFrame.minX) - abs(screenFrame.minX))
    let distanceToTrailingSideOfScreen = abs(abs(windowFrame.maxX) - abs(screenFrame.maxX))
    if distanceToTrailingSideOfScreen < distanceToLeadingSideOfScreen {
      // Closer to trailing side. Keep trailing side fixed by adjusting the window origin by the width changed
      let widthChange = windowFrame.width - newVideoWidth
      newOriginX += widthChange
    }
    // else (closer to leading side): keep leading side fixed

    let newWindowOrigin = NSPoint(x: newOriginX, y: windowFrame.origin.y)
    let newWindowSize = NSSize(width: newVideoWidth, height: windowHeight)
    let newWindowFrame = NSRect(origin: newWindowOrigin, size: newWindowSize).constrain(in: screenFrame)

    return clone(windowFrame: newWindowFrame)
  }

  var description: String {
    return "MusicModeGeometry winFrame=\(windowFrame) BtmBarH=\(bottomBarHeight) Video={show=\(isVideoVisible.yn) aspect=\(videoAspectRatio) H=\(videoHeight)} Plist={show=\(isPlaylistVisible.yn) H=\(playlistHeight)}"
  }
}
