//
//  MagnificationHandler.swift
//  iina
//
//  Created by Matt Svoboda on 8/31/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

class VideoMagnificationHandler: NSMagnificationGestureRecognizer {
  private var windowGeometryAtMagnificationStart = MainWindowGeometry(windowFrame: NSRect(), videoContainerFrame: NSRect(), videoAspectRatio: 1.0)

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
        windowGeometryAtMagnificationStart = mainWindow.buildGeometryFromCurrentLayout()
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

    let origVideoContainerSize = windowGeometryAtMagnificationStart.videoContainerSize
    let newVideoContainerSize = origVideoContainerSize.multiply(scale);

    mainWindow.resizeVideoContainer(desiredVideoContainerSize: newVideoContainerSize, fromGeometry: windowGeometryAtMagnificationStart, animate: false)
  }
}
