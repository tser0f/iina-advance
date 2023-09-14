//
//  MagnificationHandler.swift
//  iina
//
//  Created by Matt Svoboda on 8/31/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

class VideoMagnificationHandler: NSMagnificationGestureRecognizer {
  // Just init with dummy data for now so that this doesn't need to be optional
  private var windowGeometryAtMagnificationStart = MainWindowGeometry(windowFrame: NSRect(), videoContainerFrame: NSRect(),
                                                                      insideLeadingBarWidth: 0, insideTrailingBarWidth: 0,
                                                                      videoAspectRatio: 1.0)

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
        if isEnlarge != mainWindow.fsState.isFullscreen {
          recognizer.state = .recognized
          mainWindow.toggleWindowFullScreen()
        }
      }
    case .windowSize:
      if mainWindow.fsState.isFullscreen { return }

      // adjust window size
      switch recognizer.state {
      case .began:
        // FIXME: confirm reset on video size change due to track change
        windowGeometryAtMagnificationStart = mainWindow.getCurrentWindowGeometry()
        scaleVideoFromPinchGesture(to: recognizer.magnification)
      case .changed:
        scaleVideoFromPinchGesture(to: recognizer.magnification)
      case .ended:
        scaleVideoFromPinchGesture(to: recognizer.magnification)
        mainWindow.updateWindowParametersForMPV()
      case .cancelled, .failed:
        scaleVideoFromPinchGesture(to: 1.0)
        break
      default:
        return
      }
    }
  }

  private func scaleVideoFromPinchGesture(to magnification: CGFloat) {
    // avoid zero and negative numbers because they will cause problems
    let scale = max(0.0001, magnification + 1.0)
    mainWindow.log.verbose("Scaling pinched video, target scale: \(scale)")

    // If in music mode but playlist is not visible, allow scaling up to screen size like regular windowed mode.
    // If playlist is visible, do not resize window beyond current window height
    if mainWindow.player.isInMiniPlayer && mainWindow.miniPlayer.isPlaylistVisible {
      _ = mainWindow.miniPlayer.view
      guard mainWindow.miniPlayer.isVideoVisible else {
        mainWindow.log.verbose("Window is in music mode but video is not visible; ignoring pinch gesture")
        return
      }
      // Window height should not change. Only video size should be scaled
      let windowHeight = windowGeometryAtMagnificationStart.windowFrame.height  // should stay fixed
      // Constrain desired width within min and max allowed, then recalculate height from new value
      var newVideoWidth = min(
        // TODO: figure out how to remove need for 8px extra pixels on each side
        max(MiniPlayerWindowController.minWindowWidth + 16, windowGeometryAtMagnificationStart.videoSize.width * scale),
        MiniPlayerWindowController.maxWindowWidth)
      mainWindow.log.verbose("Scaling video from pinch gesture in music mode (aspect: \(windowGeometryAtMagnificationStart.videoAspectRatio)), trying width: \(newVideoWidth)")
      var newVideoHeight = newVideoWidth / windowGeometryAtMagnificationStart.videoAspectRatio

      let minPlaylistHeight: CGFloat = mainWindow.miniPlayer.isPlaylistVisible ? MiniPlayerWindowController.PlaylistMinHeight : 0
      let minBottomBarHeight: CGFloat = mainWindow.miniPlayer.backgroundView.frame.height + minPlaylistHeight
      let maxVideoHeight = windowHeight - minBottomBarHeight
      if newVideoWidth < MiniPlayerWindowController.minWindowWidth {
        newVideoWidth = MiniPlayerWindowController.minWindowWidth
        newVideoHeight = MiniPlayerWindowController.minWindowWidth / windowGeometryAtMagnificationStart.videoAspectRatio
      }
      if newVideoHeight > maxVideoHeight {
        newVideoHeight = maxVideoHeight
        newVideoWidth = maxVideoHeight * windowGeometryAtMagnificationStart.videoAspectRatio
      }

      let newWindowFrame = NSRect(origin: windowGeometryAtMagnificationStart.windowFrame.origin, size: NSSize(width: newVideoWidth, height: windowHeight)).constrain(in: mainWindow.bestScreen.visibleFrame)

      // Need to find video height to update the height of sections below it. Can easily calculate from the final window width
      var newBottomBarHeight = newWindowFrame.height - newVideoHeight
      newBottomBarHeight = newWindowFrame.height - newVideoHeight
      mainWindow.log.verbose("Scaling video from pinch gesture in music mode, got final videoSize: \(newVideoWidth) x \(newVideoHeight), bottomBarHeight: \(newBottomBarHeight), windowFrame: \(newWindowFrame)")

      CocoaAnimation.disableAnimation{
        mainWindow.miniPlayer.updateVideoHeightConstraint(height: newVideoHeight, animate: true)
        mainWindow.updateBottomBarHeight(to: newBottomBarHeight, bottomBarPlacement: .outsideVideo)
        (mainWindow.window as! MainWindow).setFrameImmediately(newWindowFrame, animate: false)
        // TODO: save geometry
        mainWindow.player.saveState()
      }
      return
    }
    // Not music mode:

    let origVideoContainerSize = windowGeometryAtMagnificationStart.videoContainerSize
    let newVideoContainerSize = origVideoContainerSize.multiply(scale)


    let newGeoUnconstrained = windowGeometryAtMagnificationStart.scale(desiredVideoContainerSize: newVideoContainerSize)
    // User has actively resized the video. Assume this is the new preferred resolution
    mainWindow.player.info.setUserPreferredVideoContainerSize(newGeoUnconstrained.videoContainerSize)

    let newGeometry = newGeoUnconstrained.constrainWithin(mainWindow.bestScreen.visibleFrame)
    mainWindow.setCurrentWindowGeometry(to: newGeometry, enqueueAnimation: false, animate: false)
  }
}
