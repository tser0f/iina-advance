//
//  MainWindowGeometry.swift
//  iina
//
//  Created by Matt Svoboda on 7/11/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/**
`MainWindowGeometry`
 Data structure which describes:
 1. The size & position (`windowFrame`) of an IINA player window which is in normal windowed mode
    (not fullscreen, music mode, etc.)
 2. The distance between each of the 4 `outsideVideo` panels and the video container. If a given outside panel is
    hidden or instead is shown as `insideVideo`, its value will be `0`.
 3. The size of the video container (`videoContainerView`), whose size is inferred by subtracting the bar sizes
    from `windowFrame`.
 4. The size of the video itself (`videoView`), which may or may not be equal to the size of `videoContainerView`,
    depending on whether empty space is allowed around the video.
 5. The video aspect ratio. This is stored here mainly to create a central reference for it, to avoid differing
    values which can arise if calculating it from disparate sources.

 Below is an example of a player window with letterboxed video, where `videoContainerView` is taller than `videoView`.
 The `windowFrame` is the outermost rectangle.
 •
 •              `videoContainerSize` (W)
 •              │◄───────────────►│
 ┌────────────────────────────────────────────────┐`windowFrame`
 │                     ▲                          │
 │                     │`topBarHeight`            │
 │                     ▼                          │
 ├──────────────┬─────────────────┬───────────────┤ ─
 │              │                 │               │ ▲
 │              │-----------------│               │ │
 │◄────────────►|   `videoSize`   |◄─────────────►│ │`videoContainerSize`
 │`leftBarWidth`|                 |`rightBarWidth`│ │ (H)
 │              │-----------------│               │ │
 │              │                 │               │ ▼
 ├──────────────┴─────────────────┴───────────────┤ ─
 │                 ▲                              │
 │                 │`bottomBarHeight`             │
 │                 ▼                              │
 └────────────────────────────────────────────────┘
 */
struct MainWindowGeometry: Equatable {
  // MARK: - Stored properties

  let windowFrame: NSRect

  // Outside panels
  let topBarHeight: CGFloat
  let trailingBarWidth: CGFloat
  let bottomBarHeight: CGFloat
  let leadingBarWidth: CGFloat

  let videoAspectRatio: CGFloat
  let videoSize: NSSize

  var allowEmptySpaceAroundVideo: Bool {
    return Preference.bool(for: .allowEmptySpaceAroundVideo)
  }

  // MARK: - Initializers

  init(windowFrame: NSRect,
       topBarHeight: CGFloat, trailingBarWidth: CGFloat, bottomBarHeight: CGFloat, leadingBarWidth: CGFloat,
       videoAspectRatio: CGFloat) {
    assert(topBarHeight >= 0, "Expected topBarHeight > 0, found \(topBarHeight)")
    assert(trailingBarWidth >= 0, "Expected trailingBarWidth > 0, found \(trailingBarWidth)")
    assert(bottomBarHeight >= 0, "Expected bottomBarHeight > 0, found \(bottomBarHeight)")
    assert(leadingBarWidth >= 0, "Expected leadingBarWidth > 0, found \(leadingBarWidth)")
    assert(trailingBarWidth >= 0, "Expected trailingBarWidth > 0, found \(trailingBarWidth)")
    self.windowFrame = windowFrame
    self.topBarHeight = topBarHeight
    self.trailingBarWidth = trailingBarWidth
    self.bottomBarHeight = bottomBarHeight
    self.leadingBarWidth = leadingBarWidth
    self.videoAspectRatio = videoAspectRatio
    let videoContainerSize = MainWindowGeometry.computeVideoContainerSize(from: windowFrame, topBarHeight: topBarHeight, trailingBarWidth: trailingBarWidth, bottomBarHeight: bottomBarHeight, leadingBarWidth: leadingBarWidth)
    self.videoSize = MainWindowGeometry.computeVideoSize(withAspectRatio: videoAspectRatio, toFillIn: videoContainerSize)
  }

  init(windowFrame: NSRect,
       videoContainerFrame: NSRect,
       videoAspectRatio: CGFloat) {
    assert(videoContainerFrame.height <= windowFrame.height, "videoContainerFrame.height (\(videoContainerFrame.height)) cannot be larger than windowFrame.height (\(windowFrame.height))")
    assert(videoContainerFrame.width <= windowFrame.width, "videoContainerFrame.width (\(videoContainerFrame.width)) cannot be larger than windowFrame.width (\(windowFrame.width))")

    let leadingBarWidth = videoContainerFrame.origin.x
    let bottomBarHeight = videoContainerFrame.origin.y
    self.init(windowFrame: windowFrame,
              topBarHeight: windowFrame.height - videoContainerFrame.height - bottomBarHeight,
              trailingBarWidth: windowFrame.width - videoContainerFrame.width - leadingBarWidth,
              bottomBarHeight: videoContainerFrame.origin.y,
              leadingBarWidth: videoContainerFrame.origin.x,
              videoAspectRatio: videoAspectRatio)
  }

  func clone(windowFrame: NSRect? = nil,
             topBarHeight: CGFloat? = nil, trailingBarWidth: CGFloat? = nil,
             bottomBarHeight: CGFloat? = nil, leadingBarWidth: CGFloat? = nil,
             videoAspectRatio: CGFloat? = nil) -> MainWindowGeometry {

    return MainWindowGeometry(windowFrame: windowFrame ?? self.windowFrame,
                              topBarHeight: topBarHeight ?? self.topBarHeight,
                              trailingBarWidth: trailingBarWidth ?? self.trailingBarWidth,
                              bottomBarHeight: bottomBarHeight ?? self.bottomBarHeight,
                              leadingBarWidth: leadingBarWidth ?? self.leadingBarWidth,
                              videoAspectRatio: videoAspectRatio ?? self.videoAspectRatio)
  }

  // MARK: - Computed properties

  /// This will be equal to `videoSize`, unless IINA is configured to allow the window to expand beyond
  /// the bounds of the video for a letterbox/pillarbox effect (separate from anything mpv includes)
  var videoContainerSize: NSSize {
    return NSSize(width: windowFrame.width - trailingBarWidth - leadingBarWidth,
                  height: windowFrame.height - topBarHeight - bottomBarHeight)
  }

  var videoFrameInScreenCoords: NSRect {
    return NSRect(origin: CGPoint(x: windowFrame.origin.x + leadingBarWidth, y: windowFrame.origin.y + bottomBarHeight), size: videoSize)
  }

  var outsideBarsTotalSize: NSSize {
    return NSSize(width: trailingBarWidth + leadingBarWidth, height: topBarHeight + bottomBarHeight)
  }

  // MARK: - Functions

  static private func computeVideoContainerSize(from windowFrame: NSRect,
                                                topBarHeight: CGFloat, trailingBarWidth: CGFloat,
                                                bottomBarHeight: CGFloat, leadingBarWidth: CGFloat) -> NSSize {
    return NSSize(width: windowFrame.width - trailingBarWidth - leadingBarWidth,
                  height: windowFrame.height - topBarHeight - bottomBarHeight)
  }

  static private func computeVideoSize(withAspectRatio videoAspectRatio: CGFloat, toFillIn videoContainerSize: NSSize) -> NSSize {
    /// Compute `videoSize` to fit within `videoContainerSize` while maintaining `videoAspectRatio`:
    if videoAspectRatio < videoContainerSize.aspect {  // video is taller, shrink to meet height
      return NSSize(width: videoContainerSize.height * videoAspectRatio, height: videoContainerSize.height)
    } else {  // video is wider, shrink to meet width
      return NSSize(width: videoContainerSize.width, height: videoContainerSize.width / videoAspectRatio)
    }
  }

  private func computeMaxVideoContainerSize(in containerSize: NSSize) -> NSSize {
    // Resize only the video. Panels outside the video do not change size.
    // To do this, subtract the "outside" panels from the container frame
    return NSSize(width: containerSize.width - outsideBarsTotalSize.width,
                  height: containerSize.height - outsideBarsTotalSize.height)
  }

  private func constrainAboveMin(desiredVideoContainerSize: NSSize) -> NSSize {
    return NSSize(width: max(AppData.minVideoSize.width, desiredVideoContainerSize.width),
                  height: max(AppData.minVideoSize.height, desiredVideoContainerSize.height))
  }

  private func constrainBelowMax(desiredVideoContainerSize: NSSize, maxSize: NSSize) -> NSSize {
    let outsideBarsTotalSize = self.outsideBarsTotalSize
    return NSSize(width: min(desiredVideoContainerSize.width, maxSize.width - outsideBarsTotalSize.width),
                  height: min(desiredVideoContainerSize.height, maxSize.height - outsideBarsTotalSize.height))
  }

  func constrainWithin(_ containerFrame: NSRect) -> MainWindowGeometry {
    return scale(desiredVideoContainerSize: nil, constrainedWithin: containerFrame)
  }

  func scale(desiredWindowSize: NSSize? = nil, constrainedWithin containerFrame: NSRect? = nil) -> MainWindowGeometry {
    if let desiredWindowSize = desiredWindowSize {
      let outsideBarsTotalSize = outsideBarsTotalSize
      let requestedVideoContainerSize = NSSize(width: desiredWindowSize.width - outsideBarsTotalSize.width,
                                               height: desiredWindowSize.height - outsideBarsTotalSize.height)
      return scale(desiredVideoContainerSize: requestedVideoContainerSize, constrainedWithin: containerFrame)
    }
    if let containerFrame = containerFrame {
      return constrainWithin(containerFrame)
    } else {
      Logger.log("Call made to MainWindowGeometry scale() but all args are nil! Doing nothing.", level: .warning)
      return self
    }
  }

  /// Computes a new `MainWindowGeometry` from this one.
  /// • If `desiredVideoContainerSize` is given, the `windowFrame` will be shrunk or grown as needed, as will the `videoSize` which will
  /// be resized to fit in the new `videoContainerSize` based on `videoAspectRatio`.
  /// • If `allowEmptySpaceAroundVideo` is enabled, `videoContainerSize` will be shrunk to the same size as `videoSize`, and
  /// `windowFrame` will be resized accordingly.
  /// • If `containerFrame` is given, resulting `windowFrame` (and its subviews) will be sized and repositioned as ncessary to fit within it.
  /// (The `containerFrame` will typically be `screen.visibleFrame`)
  /// • If `containerFrame` is `nil`, center point & size of resulting `windowFrame` will not be changed.
  func scale(desiredVideoContainerSize: NSSize? = nil, constrainedWithin containerFrame: NSRect? = nil) -> MainWindowGeometry {
    var newVidConSize = desiredVideoContainerSize ?? videoContainerSize
    Logger.log("Scaling MainWindowGeometry newVidConSize: \(newVidConSize)", level: .verbose)

    /// Make sure `videoContainerSize` is at least as large as `minVideoSize`:
    newVidConSize = constrainAboveMin(desiredVideoContainerSize: newVidConSize)

    /// If `containerFrame` is specified, constrain `videoContainerSize` within `containerFrame`:
    if let containerFrame = containerFrame {
      newVidConSize = constrainBelowMax(desiredVideoContainerSize: newVidConSize, maxSize: containerFrame.size)
    }

    /// Compute `videoSize` to fit within `videoContainerSize` while maintaining `videoAspectRatio`:
    let newVideoSize = MainWindowGeometry.computeVideoSize(withAspectRatio: videoAspectRatio, toFillIn: newVidConSize)

    if !allowEmptySpaceAroundVideo {
      newVidConSize = newVideoSize
    }

    let outsideBarsSize = self.outsideBarsTotalSize
    let newWindowSize = NSSize(width: round(newVidConSize.width + outsideBarsSize.width),
                           height: round(newVidConSize.height + outsideBarsSize.height))

    // Round the results to prevent excessive window drift due to small imprecisions in calculation
    let deltaX = round((newWindowSize.width - windowFrame.size.width) / 2)
    let deltaY = round((newWindowSize.height - windowFrame.size.height) / 2)
    let newWindowOrigin = NSPoint(x: windowFrame.origin.x - deltaX,
                                  y: windowFrame.origin.y - deltaY)

    // Move window if needed to make sure the window is not offscreen
    var newWindowFrame = NSRect(origin: newWindowOrigin, size: newWindowSize)
    if let containerFrame = containerFrame {
      newWindowFrame = newWindowFrame.constrain(in: containerFrame)
    }
    Logger.log("Scaled MainWindowGeometry result: \(newWindowFrame)", level: .verbose)
    return self.clone(windowFrame: newWindowFrame)
  }

  func scale(desiredVideoSize: NSSize, constrainedWithin containerFrame: NSRect? = nil) -> MainWindowGeometry {
    Logger.log("Scaling MainWindowGeometry desiredVideoSize: \(desiredVideoSize)", level: .debug)
    var newVideoSize = desiredVideoSize

    /// Enforce `videoView.aspectRatio`: Recalculate height, trying to preserve width
    newVideoSize = NSSize(width: desiredVideoSize.width, height: (desiredVideoSize.width / videoAspectRatio).rounded())
    if newVideoSize.height != desiredVideoSize.height {
      // We don't want to see too much of this ideally
      Logger.log("While scaling: applied aspectRatio (\(videoAspectRatio)): changed newVideoSize.height by \(newVideoSize.height - desiredVideoSize.height)", level: .debug)
    }

    /// Use `videoSize` for `desiredVideoContainerSize`:
    return scale(desiredVideoContainerSize: newVideoSize, constrainedWithin: containerFrame)
  }

  // Resizes the window appropriately
  func resizeOutsideBars(newTopHeight: CGFloat? = nil, newTrailingWidth: CGFloat? = nil,
                         newBottomHeight: CGFloat? = nil, newLeadingWidth: CGFloat? = nil) -> MainWindowGeometry {

    var ΔW: CGFloat = 0
    var ΔH: CGFloat = 0
    var ΔX: CGFloat = 0
    var ΔY: CGFloat = 0
    if let newTopHeight = newTopHeight {
      let ΔTop = abs(newTopHeight) - self.topBarHeight
      ΔH += ΔTop
    }
    if let newTrailingWidth = newTrailingWidth {
      let ΔRight = abs(newTrailingWidth) - self.trailingBarWidth
      ΔW += ΔRight
    }
    if let newBottomHeight = newBottomHeight {
      let ΔBottom = abs(newBottomHeight) - self.bottomBarHeight
      ΔH += ΔBottom
      ΔY -= ΔBottom
    }
    if let newLeadingWidth = newLeadingWidth {
      let ΔLeft = abs(newLeadingWidth) - self.leadingBarWidth
      ΔW += ΔLeft
      ΔX -= ΔLeft
    }

    let newWindowFrame = CGRect(x: windowFrame.origin.x + ΔX,
                                y: windowFrame.origin.y + ΔY,
                                width: windowFrame.width + ΔW,
                                height: windowFrame.height + ΔH)
    return self.clone(windowFrame: newWindowFrame,
                      topBarHeight: newTopHeight, trailingBarWidth: newTrailingWidth,
                      bottomBarHeight: newBottomHeight, leadingBarWidth: newLeadingWidth)
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

    log.verbose("[AdjustFrameAfterVideoReconfig] Start")

    let oldVideoAspectRatio = videoView.aspectRatio
    // Will only change the video size & video container size. Panels outside the video do not change size
    let oldVideoSize = videoView.frame.size
    // TODO: figure out why these each == -2, and whether that is OK
    let outsidePanelsWidth = window.frame.width - oldVideoSize.width
    let outsidePanelsHeight = window.frame.height - oldVideoSize.height

    // Get "correct" video size from mpv
    let videoBaseDisplaySize = player.videoBaseDisplaySize ?? AppData.sizeWhenNoVideo
    // Update aspect ratio & constraint
    videoView.updateAspectRatio(to: videoBaseDisplaySize.aspect)
    if #available(macOS 10.12, *) {
      pip.aspectRatio = videoBaseDisplaySize
    }

    var newVideoSize: NSSize
    var newWindowFrame: NSRect
    var scaleDownFactor: CGFloat? = nil

    if player.info.isRestoring {
      // To account for imprecision(s) due to floats coming from multiple sources,
      // just compare the first 6 digits after the decimal (strings make it easier)
      let oldAspect = oldVideoAspectRatio.string6f
      let newAspect = videoView.aspectRatio.string6f
      if oldAspect == newAspect {
        log.verbose("[AdjustFrameAfterVideoReconfig A] Restore is in progress; ignoring mpv video-reconfig")
      } else {
        log.error("[AdjustFrameAfterVideoReconfig B] Aspect ratio mismatch during restore! Expected \(newAspect), found \(oldAspect). Will attempt to correct by resizing window.")

      }
    } else {
      let currentWindowGeometry = buildGeometryFromCurrentLayout()
      let newGeo: MainWindowGeometry
      if shouldResizeWindowAfterVideoReconfig() {
        // get videoSize on screen
        newVideoSize = videoBaseDisplaySize
        log.verbose("[AdjustFrameAfterVideoReconfig C Resize01]  Starting calc: set newVideoSize := videoBaseDisplaySize → \(videoBaseDisplaySize)")

        // TODO
        if false && Preference.bool(for: .usePhysicalResolution) {
          let invertedScaleFactor = 1.0 / window.backingScaleFactor
          scaleDownFactor = invertedScaleFactor
          newVideoSize = videoBaseDisplaySize.multiplyThenRound(invertedScaleFactor)
          log.verbose("[AdjustFrameAfterVideoReconfig C Resize02] Converted newVideoSize to physical resolution → \(newVideoSize)")
        }

        let resizeWindowStrategy: Preference.ResizeWindowOption? = player.info.justStartedFile ? Preference.enum(for: .resizeWindowOption) : nil
        if let strategy = resizeWindowStrategy, strategy != .fitScreen {
          let resizeRatio = strategy.ratio
          newVideoSize = newVideoSize.multiply(CGFloat(resizeRatio))
          log.verbose("[AdjustFrameAfterVideoReconfig C Resize03] Applied resizeRatio (\(resizeRatio)) to newVideoSize → \(newVideoSize)")
        }

        let screenRect = bestScreen.visibleFrame
        let maxVideoSize = NSSize(width: screenRect.width - outsidePanelsWidth,
                                  height: screenRect.height - outsidePanelsHeight)

        // check screen size
        newVideoSize = newVideoSize.satisfyMaxSizeWithSameAspectRatio(maxVideoSize)
        log.verbose("[AdjustFrameAfterVideoReconfig C Resize04] Constrained newVideoSize to maxVideoSize \(maxVideoSize) → \(newVideoSize)")
        // guard min size
        // must be slightly larger than the min size, or it will crash when the min size is auto saved as window frame size.
        newVideoSize = newVideoSize.satisfyMinSizeWithSameAspectRatio(AppData.minVideoSize)
        log.verbose("[AdjustFrameAfterVideoReconfig C Resize05] Constrained videoSize to min size: \(AppData.minVideoSize) → \(newVideoSize)")
        // check if have geometry set (initial window position/size)
        if shouldApplyInitialWindowSize, let wfg = windowFrameFromGeometry(newSize: newVideoSize) {
          log.verbose("[AdjustFrameAfterVideoReconfig C ResultA] shouldApplyInitialWindowSize=Y. Got windowFrame from mpv geometry → \(wfg)")
          newWindowFrame = wfg
        } else {
          let newWindowSize = NSSize(width: newVideoSize.width + outsidePanelsWidth,
                                     height: newVideoSize.height + outsidePanelsHeight)
          if let strategy = resizeWindowStrategy, strategy == .fitScreen {
            newWindowFrame = screenRect.centeredResize(to: newWindowSize)
            log.verbose("[AdjustFrameAfterVideoReconfig C ResultB] FitToScreen strategy. Using screen rect \(screenRect) → windowFrame: \(newWindowFrame)")
          } else {
            let priorWindowFrame = currentWindowGeometry.windowFrame
            newWindowFrame = priorWindowFrame.centeredResize(to: newWindowSize)
            log.verbose("[AdjustFrameAfterVideoReconfig C ResultC] Resizing priorWindowFrame \(priorWindowFrame) to videoSize + outside panels = \(newWindowSize) → windowFrame: \(newWindowFrame)")
          }
        }
        newGeo = currentWindowGeometry.clone(windowFrame: newWindowFrame, videoAspectRatio: videoView.aspectRatio)

      } else {
        // user is navigating in playlist. retain same window width.
        // This often isn't possible for vertical videos, which will end up shrinking the width.
        // So try to remember the preferred width so it can be restored when possible
        var desiredVidConSize = currentWindowGeometry.videoContainerSize

        if !Preference.bool(for: .allowEmptySpaceAroundVideo) {
          if let prefVidConSize = player.info.getUserPreferredVideoContainerSize(forAspectRatio: videoBaseDisplaySize.aspect)  {
            // Just use existing size in this case:
            desiredVidConSize = prefVidConSize
          }

          let minNewVidConHeight = desiredVidConSize.width / videoBaseDisplaySize.aspect
          if desiredVidConSize.height < minNewVidConHeight {
            // Try to increase height if possible, though it may still be shrunk to fit screen
            desiredVidConSize = NSSize(width: desiredVidConSize.width, height: minNewVidConHeight)
          }
        }

        newGeo = currentWindowGeometry.scale(desiredVideoContainerSize: desiredVidConSize, constrainedWithin: bestScreen.visibleFrame)
        newWindowFrame = newGeo.windowFrame
        newVideoSize = newGeo.videoSize
        log.verbose("[AdjustFrameAfterVideoReconfig Assuming user is navigating in playlist. Applying desiredVidConSize \(desiredVidConSize)")
      }

      /// Finally call `setFrame()`
      if fsState.isFullscreen {
        Logger.log("AdjustFrameAfterVideoReconfig: Window is in fullscreen; setting priorWindowedGeometry to: \(newWindowFrame)", level: .verbose)
        fsState.priorWindowedGeometry = newGeo
      } else {
        log.verbose("[AdjustFrameAfterVideoReconfig] NewVideoSize: \(newVideoSize) [OldVideoSize: \(oldVideoSize) NewWindowFrame: \(newWindowFrame)]")
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
    if player.info.priorState != nil {
      player.info.priorState = nil
      log.debug("[AdjustFrameAfterVideoReconfig] Done with restore")
    } else {
      log.debug("[AdjustFrameAfterVideoReconfig] Done")
    }
  }

  func shouldResizeWindowAfterVideoReconfig() -> Bool {
    if player.info.justStartedFile {
      // resize option applies
      let resizeTiming = Preference.enum(for: .resizeWindowTiming) as Preference.ResizeWindowTiming
      switch resizeTiming {
      case .always:
        log.verbose("[AdjustFrameAfterVideoReconfig C] JustStartedFile & resizeTiming=Always → returning YES for shouldResize")
        return true
      case .onlyWhenOpen:
        log.verbose("[AdjustFrameAfterVideoReconfig C] JustStartedFile & resizeTiming=OnlyWhenOpen → returning justOpenedFile (\(player.info.justOpenedFile.yesno)) for shouldResize")
        return player.info.justOpenedFile
      case .never:
        log.verbose("[AdjustFrameAfterVideoReconfig C] JustStartedFile & resizeTiming=Never → returning NO for shouldResize")
        return false
      }
    }
    // video size changed during playback
    log.verbose("[AdjustFrameAfterVideoReconfig C] JustStartedFile=NO → returning YES for shouldResize")
    return true
  }

  func setWindowScale(_ scale: CGFloat) {
    guard fsState == .windowed else { return }
    guard let window = window else { return }

    guard let videoBaseDisplaySize = player.videoBaseDisplaySize else {
      log.error("SetWindowScale failed: could not get videoBaseDisplaySize")
      return
    }
    var videoDesiredSize = CGSize(width: videoBaseDisplaySize.width * scale, height: videoBaseDisplaySize.height * scale)

    log.verbose("SetWindowScale: requested scale=\(scale)x, videoBaseDisplaySize=\(videoBaseDisplaySize) → videoDesiredSize=\(videoDesiredSize)")

    // TODO
    if false && Preference.bool(for: .usePhysicalResolution) {
      videoDesiredSize = window.convertFromBacking(NSRect(origin: window.frame.origin, size: videoDesiredSize)).size
      log.verbose("SetWindowScale: converted videoDesiredSize to physical resolution: \(videoDesiredSize)")
    }

    /// This will fit the video container to the video size, even if `allowEmptySpaceAroundVideo` is enabled.
    /// May revisit this in the future...
    resizeVideoContainer(desiredVideoContainerSize: videoDesiredSize)
  }

  /**
   Resizes and repositions the window, attempting to match `desiredVideoContainerSize`, but the actual resulting
   video size will be scaled if needed so it is`>= AppData.minVideoSize` and `<= bestScreen.visibleFrame`.
   The window's position will also be updated to maintain its current center if possible, but also to
   ensure it is placed entirely inside `bestScreen.visibleFrame`.
   */
  func resizeVideoContainer(desiredVideoContainerSize: CGSize? = nil, fromGeometry: MainWindowGeometry? = nil,
                            centerOnScreen: Bool = false, animate: Bool = true) {
    guard !isInInteractiveMode, fsState == .windowed, let window = window else { return }

    let oldGeo = fromGeometry ?? buildGeometryFromCurrentLayout()
    let newGeoUnconstrained = oldGeo.scale(desiredVideoContainerSize: desiredVideoContainerSize)
    var newGeo = newGeoUnconstrained.constrainWithin(bestScreen.visibleFrame)
    if centerOnScreen {
      let newWindowFrame = newGeo.windowFrame.size.centeredRect(in: bestScreen.visibleFrame)
      newGeo = newGeo.clone(windowFrame: newWindowFrame)
    }

    let newWindowFrame = newGeo.windowFrame
    log.verbose("Calling setFrame() from resizeVideoContainer, to: \(newWindowFrame)")

    if animate {
      // This seems to provide a better animation and plays better with other animations
      animationQueue.run(CocoaAnimation.Task(duration: CocoaAnimation.DefaultDuration, timing: .easeInEaseOut, {
        (window as! MainWindow).setFrameImmediately(newWindowFrame)
      }))
    } else {
      window.setFrame(newWindowFrame, display: true, animate: false)
    }

    // User has actively resized the video. Assume this is the new preferred resolution
    player.info.setUserPreferredVideoContainerSize(newGeoUnconstrained.videoContainerSize)
  }

  // Must be called from the main thread
  func buildGeometryFromCurrentLayout() -> MainWindowGeometry {
    dispatchPrecondition(condition: .onQueue(DispatchQueue.main))

    if let priorGeo = fsState.priorWindowedGeometry {
      log.debug("buildGeometryFromCurrentLayout(): looks like we are in full screen. Returning priorWindowedGeometry")
      return priorGeo
    }

    let windowFrame = window!.frame
    let videoContainerFrame = videoContainerView.frame
    let videoAspectRatio = videoView.aspectRatio

    guard videoContainerFrame.width <= windowFrame.width && videoContainerFrame.height <= windowFrame.height else {
      log.error("VideoContainerFrame is invalid: height or width cannot exceed those of windowFrame! Will try to fix it. (VideoContainer: \(videoContainerFrame); Window: \(windowFrame))")
      return MainWindowGeometry(windowFrame: windowFrame,
                                topBarHeight: currentLayout.topBarHeight,
                                trailingBarWidth: currentLayout.trailingBarWidth,
                                bottomBarHeight: currentLayout.bottomBarOutsideHeight,
                                leadingBarWidth: currentLayout.leadingBarWidth,
                                videoAspectRatio: videoAspectRatio)
    }
    return MainWindowGeometry(windowFrame: windowFrame, videoContainerFrame: videoContainerFrame,
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
    log.verbose("WindowWillResize: requestedSize \(requestedSize)")

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
      guard let savedState = player.info.priorState else { return window.frame.size }

      if let savedGeo = savedState.windowGeometry {
        // If getting here, restore is in progress. Don't allow size changes, but don't worry
        // about whether the saved size is valid. It will be handled elsewhere.
        let priorSize = savedGeo.windowFrame.size
        log.verbose("WindowWillResize: denying request due to restore; returning \(priorSize)")
        return savedGeo.windowFrame.size
      }
      log.error("WindowWillResize: failed to restore window frame; returning existing: \(window.frame.size)")
      return window.frame.size
    }

    if !window.inLiveResize && (requestedSize.height <= AppData.minVideoSize.height || requestedSize.width <= AppData.minVideoSize.width) {
      // Sending the current size seems to work much better with accessibilty requests
      // than trying to change to the min size
      log.verbose("WindowWillResize: requested smaller than min \(AppData.minVideoSize); returning existing \(window.frame.size)")
      return window.frame.size
    }

    // Need to resize window to match video aspect ratio, while
    // taking into account any outside panels

    let currentGeo = buildGeometryFromCurrentLayout()
    let screenVisibleFrame = bestScreen.visibleFrame

    if Preference.bool(for: .allowEmptySpaceAroundVideo) {
      // No need to resize window to match video aspect ratio.

      let requestedGeo = currentGeo.scale(desiredWindowSize: requestedSize)

      if fsState == .windowed && window.inLiveResize {
        // User has resized the video. Assume this is the new preferred resolution until told otherwise. Do not constrain.
        player.info.setUserPreferredVideoContainerSize(requestedGeo.videoContainerSize)
      }
      let requestedGeoConstrained = requestedGeo.constrainWithin(screenVisibleFrame)
      return requestedGeoConstrained.windowFrame.size
    }

    let outsideBarsTotalSize = currentGeo.outsideBarsTotalSize

    // resize height based on requested width
    let requestedVideoWidth = requestedSize.width - outsideBarsTotalSize.width
    let resizeFromWidthRequestedVideoSize = NSSize(width: requestedVideoWidth, height: requestedVideoWidth / videoView.aspectRatio)
    let resizeFromWidthGeo = currentGeo.scale(desiredVideoSize: resizeFromWidthRequestedVideoSize, constrainedWithin: screenVisibleFrame)

    // resize width based on requested height
    let requestedVideoHeight = requestedSize.height - outsideBarsTotalSize.height
    let resizeFromHeightRequestedVideoSize = NSSize(width: requestedVideoHeight * videoView.aspectRatio, height: requestedVideoHeight)
    let resizeFromHeightGeo = currentGeo.scale(desiredVideoSize: resizeFromHeightRequestedVideoSize, constrainedWithin: screenVisibleFrame)

    let chosenGeometry: MainWindowGeometry
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
        chosenGeometry = resizeFromHeightGeo
      } else {
        chosenGeometry = resizeFromWidthGeo
      }
 
      if fsState == .windowed {
        // User has resized the video. Assume this is the new preferred resolution until told otherwise.
        player.info.setUserPreferredVideoContainerSize(chosenGeometry.videoContainerSize)
      }
    } else {
      // Resize request is not coming from the user. Could be BetterTouchTool, Retangle, or some window manager, or the OS.
      // These tools seem to expect that both dimensions of the returned size are less than the requested dimensions, so check for this.

      if resizeFromWidthGeo.windowFrame.width <= requestedSize.width && resizeFromWidthGeo.windowFrame.height <= requestedSize.height {
        chosenGeometry = resizeFromWidthGeo
      } else {
        chosenGeometry = resizeFromHeightGeo
      }
    }
    log.verbose("WindowWillResize isLive=\(window.inLiveResize.yn) req=\(requestedSize). Returning \(chosenGeometry.windowFrame.size)")
    return chosenGeometry.windowFrame.size
  }

  func windowDidResize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    // Remember, this method can be called as a side effect of an animation
    log.verbose("WindowDidResize live=\(window.inLiveResize.yn), frame=\(window.frame)")
    defer {
      updateSpacingForTitleBarAccessories()
    }

    CocoaAnimation.disableAnimation {
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

struct MiniWindowGeometry: Equatable {
  // MARK: - Stored properties

  let windowFrame: NSRect

  let videoSize: NSSize
  let videoAspectRatio: CGFloat

  let isPlaylistVisible: Bool
  let isVideoVisible: Bool
  let playlistHeight: CGFloat
}
