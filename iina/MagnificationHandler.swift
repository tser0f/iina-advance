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

      var finalGeometry: PWindowGeometry? = nil
      // adjust window size
      switch recognizer.state {
      case .began:
        windowController.isMagnifying = true
        scaleVideoFromPinchGesture(to: recognizer.magnification)
      case .changed:
        scaleVideoFromPinchGesture(to: recognizer.magnification)
      case .ended:
        finalGeometry = scaleVideoFromPinchGesture(to: recognizer.magnification)
        windowController.isMagnifying = false
      case .cancelled, .failed:
        finalGeometry = scaleVideoFromPinchGesture(to: 1.0)
        windowController.isMagnifying = false
      default:
        return
      }

      if let finalGeometry {
        if windowController.currentLayout.isMusicMode {
          windowController.log.verbose("Updating musicModeGeometry from magnification gesture state \(recognizer.state.rawValue)")
          let musicModeGeometry = windowController.musicModeGeometry.clone(windowFrame: finalGeometry.windowFrame)
          windowController.applyMusicModeGeometry(musicModeGeometry, setFrame: false, updateCache: true)
        } else {
          windowController.log.verbose("Updating windowedModeGeometry from magnification gesture state \(recognizer.state.rawValue)")
          windowController.windowedModeGeometry = finalGeometry
          windowController.player.updateMPVWindowScale(using: finalGeometry)
          windowController.player.saveState()
        }
      }
    }
  }

  @discardableResult
  private func scaleVideoFromPinchGesture(to magnification: CGFloat) -> PWindowGeometry? {
    // avoid zero and negative numbers because they will cause problems
    let scale = max(0.0001, magnification + 1.0)
    windowController.log.verbose("Scaling pinched video, target scale: \(scale)")
    let currentLayout = windowController.currentLayout

    // If in music mode but playlist is not visible, allow scaling up to screen size like regular windowed mode.
    // If playlist is visible, do not resize window beyond current window height
    if currentLayout.isMusicMode {
      windowController.miniPlayer.loadIfNeeded()

      let originalGeometry = windowController.musicModeGeometry.toPWindowGeometry()

      if windowController.miniPlayer.isPlaylistVisible {
        guard windowController.miniPlayer.isVideoVisible else {
          windowController.log.verbose("Window is in music mode but video is not visible; ignoring pinch gesture")
          return nil
        }
        let newVideoSize = windowController.musicModeGeometry.videoSize!.multiplyThenRound(scale)
        var newMusicModeGeometry = windowController.musicModeGeometry.scaleVideo(to: newVideoSize)!
        windowController.log.verbose("Scaling video from pinch gesture in music mode. Applying result bottomBarHeight: \(newMusicModeGeometry.bottomBarHeight), windowFrame: \(newMusicModeGeometry.windowFrame)")

        IINAAnimation.disableAnimation{
          /// Important: use `animate: false` so that window controller callbacks are not triggered
          newMusicModeGeometry = windowController.applyMusicModeGeometry(newMusicModeGeometry, animate: false, updateCache: false)
        }
        // Kind of clunky to convert to PWindowGeometry, just to fit the function signature, then convert it back. But...could be worse.
        return newMusicModeGeometry.toPWindowGeometry()
      } else {
        // Scaling music mode without playlist (only fixed-height controller)
        let newViewportSize = originalGeometry.viewportSize.multiplyThenRound(scale)

        // TODO: modify this to keep either leading or trailing edge fixed (as above)
        let newGeometry = originalGeometry.scaleViewport(to: newViewportSize, fitOption: .keepInVisibleScreen, mode: .musicMode)
        windowController.applyWindowGeometryForSpecialResize(newGeometry)
        return newGeometry
      }
    }
    // Else: not music mode

    let originalGeometry = windowController.windowedModeGeometry!

    let newViewportSize = originalGeometry.viewportSize.multiplyThenRound(scale)

    let intendedGeo = originalGeometry.scaleViewport(to: newViewportSize, fitOption: .noConstraints, mode: currentLayout.mode)
    // User has actively resized the video. Assume this is the new intended resolution, even if it is outside the current screen size.
    // This is useful for various features such as resizing without "lockViewportToVideoSize", or toggling visibility of outside bars.
    windowController.player.info.intendedViewportSize = intendedGeo.viewportSize

    let newGeometry = intendedGeo.refit(.keepInVisibleScreen)
    windowController.applyWindowGeometryForSpecialResize(newGeometry)
    return newGeometry
  }
}
