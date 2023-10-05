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
  let playlistHeight: CGFloat  /// indicates playlist height whether or not `isPlaylistVisible`
  let isVideoVisible: Bool
  let isPlaylistVisible: Bool
  let videoAspectRatio: CGFloat

  init(windowFrame: NSRect, playlistHeight: CGFloat, isVideoVisible: Bool, isPlaylistVisible: Bool, videoAspectRatio: CGFloat) {
    self.windowFrame = windowFrame
    if isPlaylistVisible {
      /// Ignore given `playlistHeight` and calculate it from the other params
      let videoHeight = isVideoVisible ? windowFrame.width / videoAspectRatio : 0
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

  func clone(windowFrame: NSRect? = nil, playlistHeight: CGFloat? = nil, isVideoVisible: Bool? = nil, isPlaylistVisible: Bool? = nil,
             videoAspectRatio: CGFloat? = nil) -> MusicModeGeometry {
    return MusicModeGeometry(windowFrame: windowFrame ?? self.windowFrame,
                             // if playlist is visible, this will be ignored and recalculated in the constructor
                             playlistHeight: playlistHeight ?? self.playlistHeight,
                             isVideoVisible: isVideoVisible ?? self.isVideoVisible,
                             isPlaylistVisible: isPlaylistVisible ?? self.isPlaylistVisible,
                             videoAspectRatio: videoAspectRatio ?? self.videoAspectRatio)
  }

  func toPlayerWindowGeometry() -> PlayerWindowGeometry {
    let outsideBottomBarHeight = MiniPlayerController.controlViewHeight + (isPlaylistVisible ? playlistHeight : 0)
    return PlayerWindowGeometry(windowFrame: windowFrame,
                                topMarginHeight: 0,
                                outsideTopBarHeight: 0,
                                outsideTrailingBarWidth: 0,
                                outsideBottomBarHeight: outsideBottomBarHeight,
                                outsideLeadingBarWidth: 0,
                                insideTopBarHeight: 0,
                                insideTrailingBarWidth: 0,
                                insideBottomBarHeight: 0,
                                insideLeadingBarWidth: 0,
                                videoAspectRatio: videoAspectRatio)
  }

  var videoHeightIfVisible: CGFloat {
    return windowFrame.width / videoAspectRatio
  }

  var videoSize: NSSize? {
    guard isVideoVisible else { return nil }
    return NSSize(width: windowFrame.width, height: videoHeightIfVisible)
  }

  var videoHeight: CGFloat {
    return isVideoVisible ? videoHeightIfVisible : 0
  }

  var bottomBarHeight: CGFloat {
    return windowFrame.height - videoHeight
  }

  /// The MiniPlayerWindow's width must be between `MiniPlayerMinWidth` and `Preference.musicModeMaxWidth`.
  /// It is composed of up to 3 vertical sections:
  /// 1. `videoWrapperView`: Visible if `isVideoVisible` is true). Scales with the aspect ratio of its video
  /// 2. `backgroundView`: Visible always. Fixed height
  /// 3. `playlistWrapperView`: Visible if `isPlaylistVisible` is true. Height is user resizable, and must be >= `PlaylistMinHeight`
  /// Must also ensure that window stays within the bounds of the screen it is in. Almost all of the time the window  will be
  /// height-bounded instead of width-bounded.
  func constrainWithin(_ containerFrame: NSRect) -> MusicModeGeometry {
    /// When the window's width changes, the video scales to match while keeping its aspect ratio,
    /// and the control bar (`backgroundView`) and playlist are pushed down.
    /// Calculate the maximum width/height the art can grow to so that `backgroundView` is not pushed off the screen.
    let minPlaylistHeight = isPlaylistVisible ? MiniPlayerController.PlaylistMinHeight : 0

    let maxWindowWidth: CGFloat
    if isVideoVisible {
      var maxVideoHeight = containerFrame.height - MiniPlayerController.controlViewHeight - minPlaylistHeight
      /// `maxVideoHeight` can be negative if very short screen! Fall back to height based on `MiniPlayerMinWidth` if needed
      maxVideoHeight = max(maxVideoHeight, MiniPlayerController.minWindowWidth / videoAspectRatio)
      maxWindowWidth = maxVideoHeight * videoAspectRatio
    } else {
      maxWindowWidth = MiniPlayerController.maxWindowWidth
    }

    let newWidth: CGFloat
    let requestedSize = windowFrame.size
    if requestedSize.width < MiniPlayerController.minWindowWidth {
      // Clamp to min width
      newWidth = MiniPlayerController.minWindowWidth
    } else if requestedSize.width > maxWindowWidth {
      // Clamp to max width
      newWidth = maxWindowWidth
    } else {
      // Requested size is valid
      newWidth = requestedSize.width
    }
    let videoHeight = isVideoVisible ? newWidth / videoAspectRatio : 0
    let minWindowHeight = videoHeight + MiniPlayerController.controlViewHeight + minPlaylistHeight
    // Make sure height is within acceptable values
    var newHeight = max(requestedSize.height, minWindowHeight)
    let maxHeight = isPlaylistVisible ? containerFrame.height : minWindowHeight
    newHeight = min(newHeight, maxHeight)
    let newWindowSize = NSSize(width: newWidth, height: newHeight)
    Logger.log("Constraining miniPlayer. Video=\(isVideoVisible.yn) Playlist=\(isPlaylistVisible.yn) VideoAspect=\(videoAspectRatio.string2f), ReqSize=\(requestedSize), NewSize=\(newWindowSize)", level: .verbose)

    let newWindowFrame = NSRect(origin: windowFrame.origin, size: newWindowSize).constrain(in: containerFrame)
    return self.clone(windowFrame: newWindowFrame)
  }

  var description: String {
    return "MusicModeGeometry winFrame=\(windowFrame) Video={show=\(isVideoVisible.yn) aspect=\(videoAspectRatio)} Plist={\(isPlaylistVisible.yn) H=\(playlistHeight)}"
  }
}
