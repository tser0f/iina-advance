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
    return NSMagnificationGestureRecognizer(target: self, action: #selector(MainWindowController.handleMagnifyGesture(recognizer:)))
  }()

  unowned var mainWindow: MainWindowController! = nil

  @objc func handleMagnifyGesture(recognizer: NSMagnificationGestureRecognizer) {
    let pinchAction: Preference.PinchAction = Preference.enum(for: .pinchAction)
    guard pinchAction != .none else { return }
    guard !mainWindow.isInInteractiveMode else { return }

    switch pinchAction {
    case .none:
      return
    case .fullscreen:
      // enter/exit fullscreen
      if recognizer.state == .began {
        let isEnlarge = recognizer.magnification > 0
        if isEnlarge != mainWindow.isFullScreen {
          recognizer.state = .recognized
          mainWindow.toggleWindowFullScreen()
        }
      }
    case .windowSize:
      if mainWindow.isFullScreen { return }

      var newWindowGeometry: MainWindowGeometry? = nil
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
        if mainWindow.currentLayout.isMusicMode {
          mainWindow.musicModeGeometry = mainWindow.musicModeGeometry.clone(windowFrame: newWindowGeometry.windowFrame)
          mainWindow.player.saveState()
        } else {
          mainWindow.windowGeometry = newWindowGeometry
          mainWindow.updateWindowParametersForMPV()  // also saves state
        }
      }
    }
  }

  @discardableResult
  private func scaleVideoFromPinchGesture(to magnification: CGFloat) -> MainWindowGeometry? {
    // avoid zero and negative numbers because they will cause problems
    let scale = max(0.0001, magnification + 1.0)
    mainWindow.log.verbose("Scaling pinched video, target scale: \(scale)")

    let originalGeometry: MainWindowGeometry
    if mainWindow.currentLayout.isMusicMode {
      originalGeometry = mainWindow.musicModeGeometry.toMainWindowGeometry()
    } else {
      originalGeometry = mainWindow.getCurrentWindowGeometry()
    }

    // If in music mode but playlist is not visible, allow scaling up to screen size like regular windowed mode.
    // If playlist is visible, do not resize window beyond current window height
    if mainWindow.player.isInMiniPlayer && mainWindow.miniPlayer.isPlaylistVisible {
      _ = mainWindow.miniPlayer.view
      guard mainWindow.miniPlayer.isVideoVisible else {
        mainWindow.log.verbose("Window is in music mode but video is not visible; ignoring pinch gesture")
        return nil
      }
      let screenFrame = mainWindow.bestScreen.visibleFrame
      // TODO: figure out why extra 8px on each side is needed for min width
      let minWindowWidth = MiniPlayerWindowController.minWindowWidth + 16
      // Window height should not change. Only video size should be scaled
      let windowHeight = min(screenFrame.height, originalGeometry.windowFrame.height)  // should stay fixed

      // Constrain desired width within min and max allowed, then recalculate height from new value
      var newVideoWidth = originalGeometry.windowFrame.width * scale
      newVideoWidth = max(newVideoWidth, minWindowWidth)
      newVideoWidth = min(newVideoWidth, MiniPlayerWindowController.maxWindowWidth)
      mainWindow.log.verbose("Scaling video from pinch gesture in music mode. Aspect: \(originalGeometry.videoAspectRatio), trying width: \(newVideoWidth)")

      var newVideoHeight = newVideoWidth / originalGeometry.videoAspectRatio

      let minPlaylistHeight: CGFloat = mainWindow.miniPlayer.isPlaylistVisible ? MiniPlayerWindowController.PlaylistMinHeight : 0
      let minBottomBarHeight: CGFloat = MiniPlayerWindowController.controlViewHeight + minPlaylistHeight
      let maxVideoHeight = windowHeight - minBottomBarHeight
      if newVideoWidth < minWindowWidth {
        newVideoWidth = minWindowWidth
        newVideoHeight = minWindowWidth / originalGeometry.videoAspectRatio
      }
      if newVideoHeight > maxVideoHeight {
        newVideoHeight = maxVideoHeight
        newVideoWidth = maxVideoHeight * originalGeometry.videoAspectRatio
      }

      let newWindowFrame = NSRect(origin: originalGeometry.windowFrame.origin, size: NSSize(width: newVideoWidth, height: windowHeight)).constrain(in: screenFrame)

      let newMusicModeGeometry = mainWindow.musicModeGeometry.clone(windowFrame: newWindowFrame)
      mainWindow.log.verbose("Scaling video from pinch gesture in music mode. Final width: \(originalGeometry.windowFrame.width) → \(newVideoWidth), bottomBarHeight: \(newMusicModeGeometry.bottomBarHeight), windowFrame: \(newWindowFrame)")

      CocoaAnimation.disableAnimation{
        mainWindow.miniPlayer.apply(newMusicModeGeometry, updateCache: false)
      }
      // Kind of clunky to convert to MainWindowGeometry, just to fit the function signature, then convert it back. But...could be worse.
      return newMusicModeGeometry.toMainWindowGeometry()
    }
    // Not music mode, OR scaling music mode without playlist (only fixed-height controller)

    let origVideoContainerSize = originalGeometry.videoContainerSize
    let newVideoContainerSize = origVideoContainerSize.multiply(scale)


    let newGeoUnconstrained = originalGeometry.scale(desiredVideoContainerSize: newVideoContainerSize)
    // User has actively resized the video. Assume this is the new preferred resolution
    mainWindow.player.info.setUserPreferredVideoContainerSize(newGeoUnconstrained.videoContainerSize)

    let newGeometry = newGeoUnconstrained.constrainWithin(mainWindow.bestScreen.visibleFrame)
    mainWindow.applyWindowGeometry(newGeometry, updateCache: false, enqueueAnimation: false, animate: false)
    return newGeometry
  }
}
