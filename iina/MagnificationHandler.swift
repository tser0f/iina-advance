//
//  MagnificationHandler.swift
//  iina
//
//  Created by Matt Svoboda on 8/31/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

class VideoMagnificationHandler: NSMagnificationGestureRecognizer {

  lazy var magnificationGestureRecognizer: NSMagnificationGestureRecognizer = {
    return NSMagnificationGestureRecognizer(target: self, action: #selector(PlayerWindowController.handleMagnifyGesture(recognizer:)))
  }()

  unowned var windowController: PlayerWindowController! = nil

  @objc func handleMagnifyGesture(recognizer: NSMagnificationGestureRecognizer) {
    let pinchAction: Preference.PinchAction = Preference.enum(for: .pinchAction)
    guard pinchAction != .none else { return }
    guard !windowController.isInInteractiveMode else { return }

    switch pinchAction {
    case .none:
      return
    case .fullscreen:
      // enter/exit fullscreen
      if recognizer.state == .began {
        let isEnlarge = recognizer.magnification > 0
        if isEnlarge != windowController.isFullScreen {
          recognizer.state = .recognized
          windowController.toggleWindowFullScreen()
        }
      }
    case .windowSize:
      if windowController.isFullScreen { return }

      var newWindowGeometry: PlayerWindowGeometry? = nil
      // adjust window size
      switch recognizer.state {
      case .began:
        scaleVideoFromPinchGesture(to: recognizer.magnification)
      case .changed:
        scaleVideoFromPinchGesture(to: recognizer.magnification)
      case .ended:
        newWindowGeometry = scaleVideoFromPinchGesture(to: recognizer.magnification)
      case .cancelled, .failed:
        newWindowGeometry = scaleVideoFromPinchGesture(to: 1.0)
        break
      default:
        return
      }

      if let newWindowGeometry = newWindowGeometry {
        if windowController.currentLayout.isMusicMode {
          windowController.log.verbose("Updating musicModeGeometry from magnification gesture state \(recognizer.state.rawValue)")
          windowController.musicModeGeometry = windowController.musicModeGeometry.clone(windowFrame: newWindowGeometry.windowFrame)
        } else {
          windowController.log.verbose("Updating windowedModeGeometry from magnification gesture state \(recognizer.state.rawValue)")
          windowController.windowedModeGeometry = newWindowGeometry
          windowController.updateWindowParametersForMPV()
        }
        windowController.player.saveState()
      }
    }
  }

  @discardableResult
  private func scaleVideoFromPinchGesture(to magnification: CGFloat) -> PlayerWindowGeometry? {
    // avoid zero and negative numbers because they will cause problems
    let scale = max(0.0001, magnification + 1.0)
    windowController.log.verbose("Scaling pinched video, target scale: \(scale)")

    let originalGeometry: PlayerWindowGeometry
    if windowController.currentLayout.isMusicMode {
      originalGeometry = windowController.musicModeGeometry.toPlayerWindowGeometry()
    } else {
      originalGeometry = windowController.windowedModeGeometry
    }

    // If in music mode but playlist is not visible, allow scaling up to screen size like regular windowed mode.
    // If playlist is visible, do not resize window beyond current window height
    if windowController.player.isInMiniPlayer && windowController.miniPlayer.isPlaylistVisible {
      _ = windowController.miniPlayer.view
      guard windowController.miniPlayer.isVideoVisible else {
        windowController.log.verbose("Window is in music mode but video is not visible; ignoring pinch gesture")
        return nil
      }
      let screenFrame = windowController.bestScreen.visibleFrame
      // Window height should not change. Only video size should be scaled
      let windowHeight = min(screenFrame.height, originalGeometry.windowFrame.height)  // should stay fixed

      // Constrain desired width within min and max allowed, then recalculate height from new value
      var newVideoWidth = originalGeometry.windowFrame.width * scale
      newVideoWidth = max(newVideoWidth, MiniPlayerController.minWindowWidth)
      newVideoWidth = min(newVideoWidth, MiniPlayerController.maxWindowWidth)
      newVideoWidth = min(newVideoWidth, screenFrame.width)

      windowController.log.verbose("Scaling video from pinch gesture in music mode, aspect: \(originalGeometry.videoAspectRatio). Trying width: \(newVideoWidth)")

      var newVideoHeight = newVideoWidth / originalGeometry.videoAspectRatio

      let minPlaylistHeight: CGFloat = windowController.miniPlayer.isPlaylistVisible ? MiniPlayerController.PlaylistMinHeight : 0
      let minBottomBarHeight: CGFloat = MiniPlayerController.controlViewHeight + minPlaylistHeight
      let maxVideoHeight = windowHeight - minBottomBarHeight
      if newVideoHeight > maxVideoHeight {
        newVideoHeight = maxVideoHeight
        newVideoWidth = newVideoHeight * originalGeometry.videoAspectRatio
      }

      let newWindowFrame = NSRect(origin: originalGeometry.windowFrame.origin, size: NSSize(width: newVideoWidth, height: windowHeight)).constrain(in: screenFrame)

      let newMusicModeGeometry = windowController.musicModeGeometry.clone(windowFrame: newWindowFrame)
      windowController.log.verbose("Scaling video from pinch gesture in music mode. Applying result bottomBarHeight: \(newMusicModeGeometry.bottomBarHeight), windowFrame: \(newWindowFrame)")

      CocoaAnimation.disableAnimation{
        /// Important: use `animate: false` so that window controller callbacks are not triggered
        windowController.applyMusicModeGeometry(newMusicModeGeometry, animate: false, updateCache: false)
      }
      // Kind of clunky to convert to PlayerWindowGeometry, just to fit the function signature, then convert it back. But...could be worse.
      return newMusicModeGeometry.toPlayerWindowGeometry()
    }
    // Not music mode, OR scaling music mode without playlist (only fixed-height controller)

    let origVideoContainerSize = originalGeometry.videoContainerSize
    let newVideoContainerSize = origVideoContainerSize.multiply(scale)

    let newGeoUnconstrained = originalGeometry.scaleVideoContainer(desiredSize: newVideoContainerSize)
    // User has actively resized the video. Assume this is the new intended resolution, even if it is outside the current screen size.
    // This is useful for various features such as resizing with "allowEmptySpaceAroundVideo", or toggling visibility of outside bars.
    windowController.player.info.setUserIntendedVideoContainerSize(from: newGeoUnconstrained)

    let newGeometry = newGeoUnconstrained.constrainWithin(windowController.bestScreen.visibleFrame)
    windowController.applyWindowGeometryLivePreview(newGeometry)
    return newGeometry
  }
}
