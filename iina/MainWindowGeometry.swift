//
//  MainWindowGeometry.swift
//  iina
//
//  Created by Matt Svoboda on 7/11/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/**
 ┌─────────────────────────────────────────┐
 │`windowFrame`        ▲                   │
 │                     │`topBarHeight`     │
 │                     ▼                   │
 ├──────────────┬──────────┬───────────────┤
 │              │  Video   │               │
 │◄────────────►│   Frame  │◄─────────────►│
 │`leftBarWidth`│          │`rightBarWidth`│
 ├──────────────┴──────────┴───────────────┤
 │                 ▲                       │
 │                 │`bottomBarHeight`      │
 │                 ▼                       │
 └─────────────────────────────────────────┘
 */
struct MainWindowGeometry: Equatable {
  // MARK: - Stored properties

  let windowFrame: NSRect

  // Outside panels
  let topBarHeight: CGFloat
  let rightBarWidth: CGFloat
  let bottomBarHeight: CGFloat
  let leftBarWidth: CGFloat

  let videoAspectRatio: CGFloat

  // MARK: - Initializers

  init(windowFrame: NSRect, topBarHeight: CGFloat, rightBarWidth: CGFloat, bottomBarHeight: CGFloat, leftBarWidth: CGFloat, videoAspectRatio: CGFloat) {
    assert(topBarHeight >= 0, "Expected topBarHeight > 0, found \(topBarHeight)")
    assert(rightBarWidth >= 0, "Expected rightBarWidth > 0, found \(rightBarWidth)")
    assert(bottomBarHeight >= 0, "Expected bottomBarHeight > 0, found \(bottomBarHeight)")
    assert(leftBarWidth >= 0, "Expected leftBarWidth > 0, found \(leftBarWidth)")
    assert(rightBarWidth >= 0, "Expected rightBarWidth > 0, found \(rightBarWidth)")
    self.windowFrame = windowFrame
    self.topBarHeight = topBarHeight
    self.rightBarWidth = rightBarWidth
    self.bottomBarHeight = bottomBarHeight
    self.leftBarWidth = leftBarWidth
    self.videoAspectRatio = videoAspectRatio
  }

  init(windowFrame: CGRect, videoFrame: CGRect, videoAspectRatio: CGFloat) {
    assert(videoFrame.height <= windowFrame.height, "videoFrame.height (\(videoFrame.height)) cannot be larger than windowFrame.height (\(windowFrame.height))")
    assert(videoFrame.width <= windowFrame.width, "videoFrame.width (\(videoFrame.width)) cannot be larger than windowFrame.width (\(windowFrame.width))")

    let leftBarWidth = videoFrame.origin.x
    let bottomBarHeight = videoFrame.origin.y
    let rightBarWidth = windowFrame.width - videoFrame.width - leftBarWidth
    let topBarHeight = windowFrame.height - videoFrame.height - bottomBarHeight
    self.init(windowFrame: windowFrame,
              topBarHeight: topBarHeight, rightBarWidth: rightBarWidth,
              bottomBarHeight: bottomBarHeight, leftBarWidth: leftBarWidth,
              videoAspectRatio: videoAspectRatio)
  }

  // MARK: - Derived properties

  var videoSize: NSSize {
    return NSSize(width: windowFrame.width - rightBarWidth - leftBarWidth,
                  height: windowFrame.height - topBarHeight - bottomBarHeight)
  }

  var videoFrameInScreenCoords: NSRect {
    return NSRect(origin: CGPoint(x: windowFrame.origin.x + leftBarWidth, y: windowFrame.origin.y + bottomBarHeight), size: videoSize)
  }

  var outsideBarsTotalSize: NSSize {
    return NSSize(width: rightBarWidth + leftBarWidth, height: topBarHeight + bottomBarHeight)
  }

  func clone(windowFrame: NSRect? = nil,
             topBarHeight: CGFloat? = nil, rightBarWidth: CGFloat? = nil,
             bottomBarHeight: CGFloat? = nil, leftBarWidth: CGFloat? = nil,
             videoAspectRatio: CGFloat? = nil) -> MainWindowGeometry {

    return MainWindowGeometry(windowFrame: windowFrame ?? self.windowFrame,
                              topBarHeight: topBarHeight ?? self.topBarHeight,
                              rightBarWidth: rightBarWidth ?? self.rightBarWidth,
                              bottomBarHeight: bottomBarHeight ?? self.bottomBarHeight,
                              leftBarWidth: leftBarWidth ?? self.leftBarWidth,
                              videoAspectRatio: videoAspectRatio ?? self.videoAspectRatio)
  }

  private func computeMaxVideoSize(in containerSize: NSSize) -> NSSize {
    // Resize only the video. Panels outside the video do not change size.
    // To do this, subtract the "outside" panels from the container frame
    let outsideBarsSize = self.outsideBarsTotalSize
    return NSSize(width: containerSize.width - outsideBarsSize.width,
                  height: containerSize.height - outsideBarsSize.height)
  }

  func constrainWithin(_ containerFrame: NSRect) -> MainWindowGeometry {
    return scale(desiredVideoSize: self.videoSize, constrainedWithin: containerFrame)
  }

  func scale(desiredVideoSize: NSSize, constrainedWithin containerFrame: NSRect) -> MainWindowGeometry {
    Logger.log("Scaling MainWindowGeometry desiredVideoSize:\(desiredVideoSize)", level: .debug)
    var newVideoSize = desiredVideoSize

    /// Enforce `videoView.aspectRatio`: Recalculate height, trying to preserve width
    newVideoSize = NSSize(width: desiredVideoSize.width, height: desiredVideoSize.width / videoAspectRatio)
    Logger.log("Enforced aspectRatio, newVideoSize:\(newVideoSize)", level: .verbose)

    /// Clamp video between max and min video sizes, maintaining aspect ratio of `desiredVideoSize`.
    /// (`desiredVideoSize` is assumed to be correct aspect ratio of the video.)

    // Max
    let maxVideoSize = computeMaxVideoSize(in: containerFrame.size)
    if newVideoSize.height > maxVideoSize.height {
      newVideoSize = newVideoSize.satisfyMaxSizeWithSameAspectRatio(maxVideoSize)
    }
    if newVideoSize.width > maxVideoSize.width {
      newVideoSize = newVideoSize.satisfyMaxSizeWithSameAspectRatio(maxVideoSize)
    }

    // Min
    if newVideoSize.height < AppData.minVideoSize.height {
      newVideoSize = newVideoSize.satisfyMinSizeWithSameAspectRatio(AppData.minVideoSize)
    }
    if newVideoSize.width < AppData.minVideoSize.width {
      newVideoSize = newVideoSize.satisfyMinSizeWithSameAspectRatio(AppData.minVideoSize)
    }

    newVideoSize = NSSize(width: newVideoSize.width, height: newVideoSize.height)

    let outsideBarsSize = self.outsideBarsTotalSize
    let newWindowSize = NSSize(width: round(newVideoSize.width + outsideBarsSize.width),
                               height: round(newVideoSize.height + outsideBarsSize.height))

    // Round the results to prevent excessive window drift due to small imprecisions in calculation
    let deltaX = round((newVideoSize.width - videoSize.width) / 2)
    let deltaY = round((newVideoSize.height - videoSize.height) / 2)
    let newWindowOrigin = NSPoint(x: windowFrame.origin.x - deltaX,
                                  y: windowFrame.origin.y - deltaY)

    // Move window if needed to make sure the window is not offscreen
    let newWindowFrame = NSRect(origin: newWindowOrigin, size: newWindowSize).constrain(in: containerFrame)
    return self.clone(windowFrame: newWindowFrame)
  }

  func resizeOutsideBars(newTopHeight: CGFloat? = nil, newTrailingWidth: CGFloat? = nil, newBottomHeight: CGFloat? = nil, newLeadingWidth: CGFloat? = nil) -> MainWindowGeometry {

    var ΔW: CGFloat = 0
    var ΔH: CGFloat = 0
    var ΔX: CGFloat = 0
    var ΔY: CGFloat = 0
    if let newTopHeight = newTopHeight {
      let ΔTop = abs(newTopHeight) - self.topBarHeight
      ΔH += ΔTop
    }
    if let newTrailingWidth = newTrailingWidth {
      let ΔRight = abs(newTrailingWidth) - self.rightBarWidth
      ΔW += ΔRight
    }
    if let newBottomHeight = newBottomHeight {
      let ΔBottom = abs(newBottomHeight) - self.bottomBarHeight
      ΔH += ΔBottom
      ΔY -= ΔBottom
    }
    if let newLeadingWidth = newLeadingWidth {
      let ΔLeft = abs(newLeadingWidth) - self.leftBarWidth
      ΔW += ΔLeft
      ΔX -= ΔLeft
    }
    let newWindowFrame = CGRect(x: windowFrame.origin.x + ΔX,
                                y: windowFrame.origin.y + ΔY,
                                width: windowFrame.width + ΔW,
                                height: windowFrame.height + ΔH)
    return self.clone(windowFrame: newWindowFrame, topBarHeight: newTopHeight, rightBarWidth: newTrailingWidth,
                      bottomBarHeight: newBottomHeight, leftBarWidth: newLeadingWidth)
  }
}

extension MainWindowController {

  // MARK: - UI: Window size / aspect

  /** Calculate the window frame from a parsed struct of mpv's `geometry` option. */
  func windowFrameFromGeometry(newSize: NSSize? = nil, screen: NSScreen? = nil) -> NSRect? {
    guard let geometry = cachedGeometry ?? player.getGeometry(), let screenFrame = (screen ?? window?.screen)?.visibleFrame else {
      log.verbose("WindowFrameFromGeometry: returning nil")
      return nil
    }
    log.verbose("WindowFrameFromGeometry: using \(geometry), screenFrame: \(screenFrame)")

    cachedGeometry = geometry
    // FIXME: should not use this
    var winFrame = window!.frame
    if let ns = newSize {
      winFrame.size.width = ns.width
      winFrame.size.height = ns.height
    }
    let winAspect = winFrame.size.aspect
    var widthOrHeightIsSet = false
    // w and h can't take effect at same time
    if let strw = geometry.w, strw != "0" {
      var w: CGFloat
      if strw.hasSuffix("%") {
        w = CGFloat(Double(String(strw.dropLast()))! * 0.01 * Double(screenFrame.width))
      } else {
        w = CGFloat(Int(strw)!)
      }
      w = max(AppData.minVideoSize.width, w)
      winFrame.size.width = w
      winFrame.size.height = w / winAspect
      widthOrHeightIsSet = true
    } else if let strh = geometry.h, strh != "0" {
      var h: CGFloat
      if strh.hasSuffix("%") {
        h = CGFloat(Double(String(strh.dropLast()))! * 0.01 * Double(screenFrame.height))
      } else {
        h = CGFloat(Int(strh)!)
      }
      h = max(AppData.minVideoSize.height, h)
      winFrame.size.height = h
      winFrame.size.width = h * winAspect
      widthOrHeightIsSet = true
    }
    // x, origin is window center
    if let strx = geometry.x, let xSign = geometry.xSign {
      let x: CGFloat
      if strx.hasSuffix("%") {
        x = CGFloat(Double(String(strx.dropLast()))! * 0.01 * Double(screenFrame.width)) - winFrame.width / 2
      } else {
        x = CGFloat(Int(strx)!)
      }
      winFrame.origin.x = xSign == "+" ? x : screenFrame.width - x
      // if xSign equals "-", need set right border as origin
      if (xSign == "-") {
        winFrame.origin.x -= winFrame.width
      }
    }
    // y
    if let stry = geometry.y, let ySign = geometry.ySign {
      let y: CGFloat
      if stry.hasSuffix("%") {
        y = CGFloat(Double(String(stry.dropLast()))! * 0.01 * Double(screenFrame.height)) - winFrame.height / 2
      } else {
        y = CGFloat(Int(stry)!)
      }
      winFrame.origin.y = ySign == "+" ? y : screenFrame.height - y
      if (ySign == "-") {
        winFrame.origin.y -= winFrame.height
      }
    }
    // if x and y are not specified
    if geometry.x == nil && geometry.y == nil && widthOrHeightIsSet {
      winFrame.origin.x = (screenFrame.width - winFrame.width) / 2
      winFrame.origin.y = (screenFrame.height - winFrame.height) / 2
    }
    // if the screen has offset
    winFrame.origin.x += screenFrame.origin.x
    winFrame.origin.y += screenFrame.origin.y

    log.verbose("WindowFrameFromGeometry: resulting windowFrame: \(winFrame)")
    return winFrame
  }

  /** Set window size when info available, or video size changed. Called in response to receiving 'video-reconfig' msg  */
  func adjustFrameAfterVideoReconfig() {
    guard let window = window else { return }

    let videoBaseDisplaySize = player.videoBaseDisplaySize

    // set aspect ratio
    videoView.updateAspectRatio(w: videoBaseDisplaySize.width, h: videoBaseDisplaySize.height)
    if #available(macOS 10.12, *) {
      pip.aspectRatio = videoBaseDisplaySize
    }


    // Scale only the video. Panels outside the video do not change size
    let oldVideoSize = videoView.frame.size
    // TODO: figure out why these each == -2, and whether that is OK
    let outsidePanelsWidth = window.frame.width - oldVideoSize.width
    let outsidePanelsHeight = window.frame.height - oldVideoSize.height

    var newVideoSize: NSSize
    var newWindowFrame: NSRect
    var scaleDownFactor: CGFloat? = nil

    if player.info.isRestoring {
      if oldVideoSize.aspect == videoView.aspectRatio {
        log.debug("AdjustFrameAfterVideoReconfig: skipping resize because isRestoring is set")
      } else {
        log.debug("AdjustFrameAfterVideoReconfig: bad aspect! Expected \(videoView.aspectRatio), found \(oldVideoSize.aspect)")
        // FIXME: fix it!
      }
    } else {
      if shouldResizeWindowAfterVideoReconfig() {
        // get videoSize on screen
        newVideoSize = videoBaseDisplaySize
        log.verbose("Starting resizeWindow calculations; set newVideoSize = videoBaseDisplaySize -> \(videoBaseDisplaySize)")

        // TODO
        if false && Preference.bool(for: .usePhysicalResolution) {
          let invertedScaleFactor = 1.0 / window.backingScaleFactor
          scaleDownFactor = invertedScaleFactor
          newVideoSize = videoBaseDisplaySize.multiplyThenRound(invertedScaleFactor)
          log.verbose("Converted newVideoSize to physical resolution -> \(newVideoSize)")
        }

        let resizeWindowStrategy: Preference.ResizeWindowOption? = player.info.justStartedFile ? Preference.enum(for: .resizeWindowOption) : nil
        if let strategy = resizeWindowStrategy, strategy != .fitScreen {
          let resizeRatio = strategy.ratio
          newVideoSize = newVideoSize.multiply(CGFloat(resizeRatio))
          log.verbose("Applied resizeRatio (\(resizeRatio)) to newVideoSize -> \(newVideoSize)")
        }

        let screenRect = bestScreen.visibleFrame
        let maxVideoSize = NSSize(width: screenRect.width - outsidePanelsWidth,
                                  height: screenRect.height - outsidePanelsHeight)

        // check screen size
        newVideoSize = newVideoSize.satisfyMaxSizeWithSameAspectRatio(maxVideoSize)
        log.verbose("Constrained newVideoSize to maxVideoSize \(maxVideoSize) -> \(newVideoSize)")
        // guard min size
        // must be slightly larger than the min size, or it will crash when the min size is auto saved as window frame size.
        // FIXME: cannot use same aspect ratio as AppData.minVideoSize!
        newVideoSize = newVideoSize.satisfyMinSizeWithSameAspectRatio(AppData.minVideoSize)
        log.verbose("Constrained videoSize to min size: \(AppData.minVideoSize) -> \(newVideoSize)")
        // check if have geometry set (initial window position/size)
        if shouldApplyInitialWindowSize, let wfg = windowFrameFromGeometry(newSize: newVideoSize) {
          log.verbose("Applied initial window geometry; resulting windowFrame: \(wfg)")
          newWindowFrame = wfg
        } else {
          let newWindowSize = NSSize(width: newVideoSize.width + outsidePanelsWidth,
                                     height: newVideoSize.height + outsidePanelsHeight)
          if let strategy = resizeWindowStrategy, strategy == .fitScreen {
            newWindowFrame = screenRect.centeredResize(to: newWindowSize)
            log.verbose("Did a centered resize using screen rect \(screenRect); resulting windowFrame: \(newWindowFrame)")
          } else {
            let priorWindowFrame = fsState.priorWindowedFrame?.windowFrame ?? window.frame  // FIXME: need to save more information
            newWindowFrame = priorWindowFrame.centeredResize(to: newWindowSize)
            log.verbose("Did a centered resize to \(newWindowSize) using prior frame \(priorWindowFrame); resulting windowFrame: \(newWindowFrame)")
          }
        }

      } else {
        // FIXME: this gets messed up by vertical videos. Investigate organizing per aspect ratio
        // user is navigating in playlist. retain same window width.
        let newVideoWidth = oldVideoSize.width
        let newVideoHeight = newVideoWidth / videoBaseDisplaySize.aspect
        newVideoSize = NSSize(width: newVideoWidth, height: newVideoHeight)
        log.verbose("Using oldVideoSize width for newVideoSize, with new height (\(newVideoHeight)) -> \(newVideoSize)")
        newWindowFrame = computeResizedWindowFrame(withDesiredVideoSize: newVideoSize)
      }

      /// Finally call `setFrame()`
      if fsState.isFullscreen {
        // FIXME: get this back
        //      Logger.log("AdjustFrameAfterVideoReconfig: Window is in fullscreen; setting priorWindowedFrame to: \(newWindowFrame)", level: .verbose)
        //      fsState.priorWindowedFrame = newWindowFrame
      } else {
        log.verbose("AdjustFrameAfterVideoReconfig DONE: NewVideoSize: \(newVideoSize) [OldVideoSize: \(oldVideoSize) NewWindowFrame: \(newWindowFrame)]")
        window.setFrame(newWindowFrame, display: true, animate: true)

        // If adjusted by backingScaleFactor, need to reverse the adjustment when reporting to mpv
        let mpvVideoSize: CGSize
        if let scaleDownFactor = scaleDownFactor {
          mpvVideoSize = newVideoSize.multiplyThenRound(scaleDownFactor)
        } else {
          mpvVideoSize = newVideoSize
        }
        updateWindowParametersForMPV(withSize: mpvVideoSize)
      }

      // UI and slider
      updatePlayTime(withDuration: true)
      player.events.emit(.windowSizeAdjusted, data: newWindowFrame)
    }

    // maybe not a good position, consider putting these at playback-restart
    player.info.justOpenedFile = false
    player.info.justStartedFile = false
    shouldApplyInitialWindowSize = false
    player.info.priorUIState = nil
  }

  func shouldResizeWindowAfterVideoReconfig() -> Bool {
    if player.info.justStartedFile {
      // resize option applies
      let resizeTiming = Preference.enum(for: .resizeWindowTiming) as Preference.ResizeWindowTiming
      switch resizeTiming {
      case .always:
        return true
      case .onlyWhenOpen:
        return player.info.justOpenedFile
      case .never:
        return false
      }
    }
    // video size changed during playback
    return true
  }

  func setWindowScale(_ scale: CGFloat) {
    guard fsState == .windowed else { return }
    guard let window = window else { return }

    let videoBaseDisplaySize = player.videoBaseDisplaySize
    var videoDesiredSize = CGSize(width: videoBaseDisplaySize.width * scale, height: videoBaseDisplaySize.height * scale)

    log.verbose("SetWindowScale: requested scale=\(scale)x, videoBaseDisplaySize=\(videoBaseDisplaySize) -> videoDesiredSize=\(videoDesiredSize)")

    // TODO
    if false && Preference.bool(for: .usePhysicalResolution) {
      videoDesiredSize = window.convertFromBacking(NSRect(origin: window.frame.origin, size: videoDesiredSize)).size
      log.verbose("SetWindowScale: converted videoDesiredSize to physical resolution: \(videoDesiredSize)")
    }

    resizeVideo(desiredVideoSize: videoDesiredSize)
  }

  /**
   Resizes and repositions the window, attempting to match `desiredVideoSize`, but the actual resulting
   video size will be scaled if needed so it is`>= AppData.minVideoSize` and `<= bestScreen.visibleFrame`.
   The window's position will also be updated to maintain its current center if possible, but also to
   ensure it is placed entirely inside `bestScreen.visibleFrame`. The aspect ratio of `desiredVideoSize`
   does not need to match the aspect ratio of `fromVideoSize`.
   • If `fromVideoSize` is not provided, it will default to `videoView.frame.size`.
   • If `fromWindowFrame` is not provided, it will default to `window.frame`
   */
  func resizeVideo(desiredVideoSize: CGSize, fromGeometry: MainWindowGeometry? = nil,
                   centerOnScreen: Bool = false, animate: Bool = true) {
    guard !isInInteractiveMode, let window = window else { return }

    let newWindowFrame = computeResizedWindowFrame(withDesiredVideoSize: desiredVideoSize, fromGeometry: fromGeometry, centerOnScreen: centerOnScreen)
    log.verbose("Calling setFrame() from resizeVideo, to: \(newWindowFrame)")

    if animate {
      // This seems to provide a better animation and plays better with other animations
      animationQueue.run(UIAnimation.Task(duration: UIAnimation.DefaultDuration, timing: .easeInEaseOut, {
        (window as! MainWindow).setFrameImmediately(newWindowFrame)
      }))
    } else {
      window.setFrame(newWindowFrame, display: true, animate: false)
    }
  }

  /// Same as `resizeVideo()`, but does not call `window.setFrame()`.
  /// If `fromGeometry` is `nil`, uses existing window geometry.
  func computeResizedWindowFrame(withDesiredVideoSize desiredVideoSize: CGSize, fromGeometry: MainWindowGeometry? = nil,
                                 centerOnScreen: Bool = false) -> NSRect {

    let oldScaleGeo = fromGeometry ?? buildGeometryFromCurrentLayout()
    let newScaleGeo = oldScaleGeo.scale(desiredVideoSize: desiredVideoSize, constrainedWithin: bestScreen.visibleFrame)
    if centerOnScreen {
      return newScaleGeo.windowFrame.size.centeredRect(in: bestScreen.visibleFrame)
    }
    return newScaleGeo.windowFrame
  }

  func buildGeometryFromCurrentLayout() -> MainWindowGeometry {
    let windowFrame = window!.frame
    let videoFrame = videoContainerView.frame
    let videoAspectRatio = videoView.aspectRatio

    guard videoFrame.width <= windowFrame.width && videoFrame.height <= windowFrame.height else {
      log.error("VideoContainerFrame is invalid: height or width cannot exceed those of windowFrame! Will try to fix it. (Video: \(videoFrame); Window: \(windowFrame))")
      return MainWindowGeometry(windowFrame: windowFrame,
                                topBarHeight: currentLayout.topBarHeight,
                                rightBarWidth: trailingSidebar.currentOutsideWidth,
                                bottomBarHeight: currentLayout.bottomBarOutsideHeight,
                                leftBarWidth: leadingSidebar.currentOutsideWidth,
                                videoAspectRatio: videoAspectRatio)
    }
    return MainWindowGeometry(windowFrame: windowFrame, videoFrame: videoFrame,
                              videoAspectRatio: videoAspectRatio)
  }

  func windowWillStartLiveResize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    log.verbose("LiveResize started (\(window.inLiveResize)) for window: \(window.frame)")
    isLiveResizingWidth = false
  }

  // MARK: - Window delegate: Resize

  func windowWillResize(_ window: NSWindow, to requestedSize: NSSize) -> NSSize {
    // This method can be called as a side effect of the animation. If so, ignore.
    guard fsState == .windowed else { return requestedSize }

    defer {
      updateSpacingForTitleBarAccessories()
    }

    if denyNextWindowResize {
      let currentSize = window.frame.size
      log.verbose("WindowWillResize: denying this resize; will stay at \(currentSize)")
      denyNextWindowResize = false
      return currentSize
    }

    if player.info.isRestoring {
      guard let savedState = player.info.priorUIState else { return window.frame.size }

      if let csv = savedState.string(for: .windowFrame) {
        let dims: [Double] = csv.components(separatedBy: ",").compactMap{Double($0)}
        if dims.count == 4 {
          // FIXME: constrain within screen (add to MainWindowGeometry)
          let savedSize = NSSize(width: dims[2], height: dims[3])
          log.verbose("WindowWillResize: denying request due to restore; returning \(savedSize)")
          return savedSize
        }
      }
      log.verbose("WindowWillResize: failed to restore window frame; returning existing: \(window.frame.size)")
      return window.frame.size
    }

    if !window.inLiveResize && (requestedSize.height <= AppData.minVideoSize.height || requestedSize.width <= AppData.minVideoSize.width) {
      // Sending the current size seems to work much better with accessibilty requests
      // than trying to change to the min size
      log.verbose("WindowWillResize: requested smaller than min \(AppData.minVideoSize); returning existing \(window.frame.size)")
      return window.frame.size
    }

    let requestedVideoSize = NSSize(width: requestedSize.width - (trailingSidebar.currentOutsideWidth + leadingSidebar.currentOutsideWidth),
                                    height: requestedSize.height - (currentLayout.topBarOutsideHeight + currentLayout.bottomBarOutsideHeight))

    // resize height based on requested width
    let resizeFromWidthRequestedVideoSize = NSSize(width: requestedVideoSize.width, height: requestedVideoSize.width / videoView.aspectRatio)
    let resizeFromWidth = computeResizedWindowFrame(withDesiredVideoSize: resizeFromWidthRequestedVideoSize).size

    // resize width based on requested height
    let resizeFromHeightRequestedVideoSize = NSSize(width: requestedVideoSize.height * videoView.aspectRatio, height: requestedVideoSize.height)
    let resizeFromHeight = computeResizedWindowFrame(withDesiredVideoSize: resizeFromHeightRequestedVideoSize).size

    let newSize: NSSize
    if window.inLiveResize {
      /// Notes on the trickiness of live window resize:
      /// 1. We need to decide whether to (A) keep the width fixed, and resize the height, or (B) keep the height fixed, and resize the width.
      /// "A" works well when the user grabs the top or bottom sides of the window, but will not allow resizing if the user grabs the left
      /// or right sides. Similarly, "B" works with left or right sides, but will not work with top or bottom.
      /// 2. We can make all 4 sides allow resizing by first checking if the user is requesting a different height: if yes, use "B";
      /// and if no, use "A".
      /// 3. Unfortunately (2) causes resize from the corners to jump all over the place, because in that case either height or width will change
      /// in small increments (depending on how fast the user moves the cursor) but this will result in a different choice between "A" or "B" schemes
      /// each time, with very different answers, which causes the jumpiness. In this case either scheme will work fine, just as long as we stick
      /// to the same scheme for the whole resize. So to fix this, we add `isLiveResizingWidth`, and once set, stick to scheme "B".
      if window.frame.height != requestedSize.height {
        isLiveResizingWidth = true
      }
      if isLiveResizingWidth {
        newSize = resizeFromHeight
      } else {
        newSize = resizeFromWidth
      }
    } else {
      // Resize request is not coming from the user. Could be BetterTouchTool, Retangle, or some window manager, or the OS.
      // These tools seem to expect that both dimensions of the returned size are less than the requested dimensions, so check for this.

      if resizeFromWidth.width <= requestedSize.width && resizeFromWidth.height <= requestedSize.height {
        newSize = resizeFromWidth
      } else {
        newSize = resizeFromHeight
      }
    }
    log.verbose("WindowWillResize returning: \(newSize) from:\(requestedSize)")
    return newSize
  }

  func windowDidResize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    // Remember, this method can be called as a side effect of an animation
    log.verbose("WindowDidResize live=\(window.inLiveResize.yn), frame=\(window.frame)")
    defer {
      updateSpacingForTitleBarAccessories()
    }

    UIAnimation.disableAnimation {
      if isInInteractiveMode {
        // interactive mode
        cropSettingsView?.cropBoxView.resized(with: videoView.frame)
      } else if currentLayout.oscPosition == .floating {
        // Update floating control bar position
        updateFloatingOSCAfterWindowDidResize()
      }
    }

    player.events.emit(.windowResized, data: window.frame)
  }

  // resize framebuffer in videoView after resizing.
  func windowDidEndLiveResize(_ notification: Notification) {
    // Must not access mpv while it is asynchronously processing stop and quit commands.
    // See comments in windowWillExitFullScreen for details.
    guard !isClosing else { return }

    // This method can be called as a side effect of the animation. If so, ignore.
    guard fsState == .windowed else { return }

    updateWindowParametersForMPV()
  }

  private func updateFloatingOSCAfterWindowDidResize() {
    guard let window = window, currentLayout.oscPosition == .floating else { return }
    let cph = Preference.float(for: .controlBarPositionHorizontal)
    let cpv = Preference.float(for: .controlBarPositionVertical)

    let windowWidth = window.frame.width
    let margin: CGFloat = 10
    let minWindowWidth: CGFloat = 480 // 460 + 20 margin
    var xPos: CGFloat

    if windowWidth < minWindowWidth {
      // osc is compressed
      xPos = windowWidth / 2
    } else {
      // osc has full width
      let oscHalfWidth: CGFloat = 230
      xPos = windowWidth * CGFloat(cph)
      if xPos - oscHalfWidth < margin {
        xPos = oscHalfWidth + margin
      } else if xPos + oscHalfWidth + margin > windowWidth {
        xPos = windowWidth - oscHalfWidth - margin
      }
    }

    let windowHeight = window.frame.height
    var yPos = windowHeight * CGFloat(cpv)
    let oscHeight: CGFloat = 67
    let yMargin: CGFloat = 25

    if yPos < 0 {
      yPos = 0
    } else if yPos + oscHeight + yMargin > windowHeight {
      yPos = windowHeight - oscHeight - yMargin
    }

    controlBarFloating.xConstraint.constant = xPos
    controlBarFloating.yConstraint.constant = yPos

    // Detach the views in oscFloatingUpperView manually on macOS 11 only; as it will cause freeze
    if #available(macOS 11.0, *) {
      if #unavailable(macOS 12.0) {
        guard let maxWidth = [fragVolumeView, fragToolbarView].compactMap({ $0?.frame.width }).max() else {
          return
        }

        // window - 10 - controlBarFloating
        // controlBarFloating - 12 - oscFloatingUpperView
        let margin: CGFloat = (10 + 12) * 2
        let hide = (window.frame.width
                    - oscFloatingPlayButtonsContainerView.frame.width
                    - maxWidth*2
                    - margin) < 0

        let views = oscFloatingUpperView.views
        if hide {
          if views.contains(fragVolumeView) {
            oscFloatingUpperView.removeView(fragVolumeView)
          }
          if let fragToolbarView = fragToolbarView, views.contains(fragToolbarView) {
            oscFloatingUpperView.removeView(fragToolbarView)
          }
        } else {
          if !views.contains(fragVolumeView) {
            oscFloatingUpperView.addView(fragVolumeView, in: .leading)
          }
          if let fragToolbarView = fragToolbarView, !views.contains(fragToolbarView) {
            oscFloatingUpperView.addView(fragToolbarView, in: .trailing)
          }
        }
      }
    }
  }

}
