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
 •                        `videoContainerSize` (W)
 •                        │◄───────────────►│
 ┌─────────────────────────────────────────────────────────────────────┐`windowFrame`
 │                               ▲                                     │
 │                               │`outsideTopBarHeight`                │
 │                               ▼                                     │
 ├────────────────────────┬─────────────────┬──────────────────────────┤ ─
 │                        │                 │                          │ ▲
 │                        │-----------------│                          │ │
 │◄──────────────────────►|   `videoSize`   |◄────────────────────────►│ │`videoContainerSize`
 │`outsideLeadingBarWidth`|                 | `outsideTrailingBarWidth`│ │ (H)
 │                        │-----------------│                          │ │
 │                        │                 │                          │ ▼
 ├────────────────────────┴─────────────────┴──────────────────────────┤ ─
 │                            ▲                                        │
 │                            │`outsideBottomBarHeight`                │
 │                            ▼                                        │
 └─────────────────────────────────────────────────────────────────────┘
 */
struct MainWindowGeometry: Equatable {
  // MARK: - Stored properties

  let windowFrame: NSRect

  // Outside panels
  let outsideTopBarHeight: CGFloat
  let outsideTrailingBarWidth: CGFloat
  let outsideBottomBarHeight: CGFloat
  let outsideLeadingBarWidth: CGFloat

  // Inside panels
  let insideLeadingBarWidth: CGFloat
  let insideTrailingBarWidth: CGFloat

  let videoAspectRatio: CGFloat
  let videoSize: NSSize

  var allowEmptySpaceAroundVideo: Bool {
    return Preference.bool(for: .allowEmptySpaceAroundVideo)
  }

  // MARK: - Initializers

  init(windowFrame: NSRect,
       outsideTopBarHeight: CGFloat, outsideTrailingBarWidth: CGFloat, outsideBottomBarHeight: CGFloat, outsideLeadingBarWidth: CGFloat,
       insideLeadingBarWidth: CGFloat, insideTrailingBarWidth: CGFloat,
       videoAspectRatio: CGFloat) {
    assert(outsideTopBarHeight >= 0, "Expected outsideTopBarHeight >= 0, found \(outsideTopBarHeight)")
    assert(outsideTrailingBarWidth >= 0, "Expected outsideTrailingBarWidth >= 0, found \(outsideTrailingBarWidth)")
    assert(outsideBottomBarHeight >= 0, "Expected outsideBottomBarHeight >= 0, found \(outsideBottomBarHeight)")
    assert(outsideLeadingBarWidth >= 0, "Expected outsideLeadingBarWidth >= 0, found \(outsideLeadingBarWidth)")
    assert(insideLeadingBarWidth >= 0, "Expected insideLeadingBarWidth >= 0, found \(insideLeadingBarWidth)")
    assert(insideTrailingBarWidth >= 0, "Expected insideTrailingBarWidth >= 0, found \(insideTrailingBarWidth)")
    self.windowFrame = windowFrame
    self.outsideTopBarHeight = outsideTopBarHeight
    self.outsideTrailingBarWidth = outsideTrailingBarWidth
    self.outsideBottomBarHeight = outsideBottomBarHeight
    self.outsideLeadingBarWidth = outsideLeadingBarWidth
    self.insideLeadingBarWidth = insideLeadingBarWidth
    self.insideTrailingBarWidth = insideTrailingBarWidth
    self.videoAspectRatio = videoAspectRatio
    let videoContainerSize = MainWindowGeometry.computeVideoContainerSize(from: windowFrame, outsideTopBarHeight: outsideTopBarHeight, outsideTrailingBarWidth: outsideTrailingBarWidth, outsideBottomBarHeight: outsideBottomBarHeight, outsideLeadingBarWidth: outsideLeadingBarWidth)
    self.videoSize = MainWindowGeometry.computeVideoSize(withAspectRatio: videoAspectRatio, toFillIn: videoContainerSize)
  }

  init(windowFrame: NSRect,
       videoContainerFrame: NSRect,
       insideLeadingBarWidth: CGFloat, insideTrailingBarWidth: CGFloat,
       videoAspectRatio: CGFloat) {
    assert(videoContainerFrame.height <= windowFrame.height, "videoContainerFrame.height (\(videoContainerFrame.height)) cannot be larger than windowFrame.height (\(windowFrame.height))")
    assert(videoContainerFrame.width <= windowFrame.width, "videoContainerFrame.width (\(videoContainerFrame.width)) cannot be larger than windowFrame.width (\(windowFrame.width))")

    let outsideLeadingBarWidth = videoContainerFrame.origin.x
    let outsideBottomBarHeight = videoContainerFrame.origin.y
    self.init(windowFrame: windowFrame,
              outsideTopBarHeight: windowFrame.height - videoContainerFrame.height - outsideBottomBarHeight,
              outsideTrailingBarWidth: windowFrame.width - videoContainerFrame.width - outsideLeadingBarWidth,
              outsideBottomBarHeight: videoContainerFrame.origin.y,
              outsideLeadingBarWidth: videoContainerFrame.origin.x,
              insideLeadingBarWidth: insideLeadingBarWidth, insideTrailingBarWidth: insideTrailingBarWidth,
              videoAspectRatio: videoAspectRatio)
  }

  func clone(windowFrame: NSRect? = nil,
             outsideTopBarHeight: CGFloat? = nil, outsideTrailingBarWidth: CGFloat? = nil,
             outsideBottomBarHeight: CGFloat? = nil, outsideLeadingBarWidth: CGFloat? = nil,
             insideLeadingBarWidth: CGFloat? = nil, insideTrailingBarWidth: CGFloat? = nil,
             videoAspectRatio: CGFloat? = nil) -> MainWindowGeometry {

    return MainWindowGeometry(windowFrame: windowFrame ?? self.windowFrame,
                              outsideTopBarHeight: outsideTopBarHeight ?? self.outsideTopBarHeight,
                              outsideTrailingBarWidth: outsideTrailingBarWidth ?? self.outsideTrailingBarWidth,
                              outsideBottomBarHeight: outsideBottomBarHeight ?? self.outsideBottomBarHeight,
                              outsideLeadingBarWidth: outsideLeadingBarWidth ?? self.outsideLeadingBarWidth,
                              insideLeadingBarWidth: insideLeadingBarWidth ?? self.insideLeadingBarWidth,
                              insideTrailingBarWidth: insideTrailingBarWidth ?? self.insideTrailingBarWidth,
                              videoAspectRatio: videoAspectRatio ?? self.videoAspectRatio)
  }

  // MARK: - Computed properties

  /// This will be equal to `videoSize`, unless IINA is configured to allow the window to expand beyond
  /// the bounds of the video for a letterbox/pillarbox effect (separate from anything mpv includes)
  var videoContainerSize: NSSize {
    return NSSize(width: windowFrame.width - outsideTrailingBarWidth - outsideLeadingBarWidth,
                  height: windowFrame.height - outsideTopBarHeight - outsideBottomBarHeight)
  }

  var videoFrameInScreenCoords: NSRect {
    return NSRect(origin: CGPoint(x: windowFrame.origin.x + outsideLeadingBarWidth, y: windowFrame.origin.y + outsideBottomBarHeight), size: videoSize)
  }

  var outsideBarsTotalSize: NSSize {
    return NSSize(width: outsideTrailingBarWidth + outsideLeadingBarWidth, height: outsideTopBarHeight + outsideBottomBarHeight)
  }

  var minVideoHeight: CGFloat {
    // Limiting factor will most likely be sidebars
    return minVideoWidth / videoAspectRatio
  }

  var minVideoWidth: CGFloat {
    return max(AppData.minVideoSize.width, insideLeadingBarWidth + insideTrailingBarWidth + Constants.Sidebar.minSpaceBetweenInsideSidebars)
  }

  // MARK: - Functions

  static private func computeVideoContainerSize(from windowFrame: NSRect,
                                                outsideTopBarHeight: CGFloat, outsideTrailingBarWidth: CGFloat,
                                                outsideBottomBarHeight: CGFloat, outsideLeadingBarWidth: CGFloat) -> NSSize {
    return NSSize(width: windowFrame.width - outsideTrailingBarWidth - outsideLeadingBarWidth,
                  height: windowFrame.height - outsideTopBarHeight - outsideBottomBarHeight)
  }

  static private func computeVideoSize(withAspectRatio videoAspectRatio: CGFloat, toFillIn videoContainerSize: NSSize) -> NSSize {
    /// Compute `videoSize` to fit within `videoContainerSize` while maintaining `videoAspectRatio`:
    if videoAspectRatio < videoContainerSize.aspect {  // video is taller, shrink to meet height
      return NSSize(width: videoContainerSize.height * videoAspectRatio, height: videoContainerSize.height)
    } else {  // video is wider, shrink to meet width
      return NSSize(width: videoContainerSize.width, height: videoContainerSize.width / videoAspectRatio)
    }
  }

  fileprivate func computeMaxVideoContainerSize(in containerSize: NSSize) -> NSSize {
    // Resize only the video. Panels outside the video do not change size.
    // To do this, subtract the "outside" panels from the container frame
    return NSSize(width: containerSize.width - outsideBarsTotalSize.width,
                  height: containerSize.height - outsideBarsTotalSize.height)
  }

  // Computes & returns the max video size with proper aspect ratio which can fit in the given container, after subtracting outside bars
  fileprivate func computeMaxVideoSize(in containerSize: NSSize) -> NSSize {
    let maxVidConSize = computeMaxVideoContainerSize(in: containerSize)
    return MainWindowGeometry.computeVideoSize(withAspectRatio: videoAspectRatio, toFillIn: maxVidConSize)
  }

  private func constrainAboveMin(desiredVideoContainerSize: NSSize) -> NSSize {
    let constrainedWidth = max(minVideoWidth, desiredVideoContainerSize.width)
    let constrainedHeight = max(minVideoHeight, desiredVideoContainerSize.height)
    return NSSize(width: constrainedWidth, height: constrainedHeight)
  }

  private func constrainBelowMax(desiredVideoContainerSize: NSSize, maxSize: NSSize) -> NSSize {
    let outsideBarsTotalSize = self.outsideBarsTotalSize
    return NSSize(width: min(desiredVideoContainerSize.width, maxSize.width - outsideBarsTotalSize.width),
                  height: min(desiredVideoContainerSize.height, maxSize.height - outsideBarsTotalSize.height))
  }

  func constrainWithin(_ containerFrame: NSRect, centerInContainer: Bool = false) -> MainWindowGeometry {
    return scale(desiredVideoContainerSize: nil, constrainedWithin: containerFrame, centerInContainer: centerInContainer)
  }

  func scale(desiredWindowSize: NSSize? = nil,
             constrainedWithin containerFrame: NSRect? = nil, centerInContainer: Bool = false) -> MainWindowGeometry {
    if let desiredWindowSize = desiredWindowSize {
      let outsideBarsTotalSize = outsideBarsTotalSize
      let requestedVideoContainerSize = NSSize(width: desiredWindowSize.width - outsideBarsTotalSize.width,
                                               height: desiredWindowSize.height - outsideBarsTotalSize.height)
      return scale(desiredVideoContainerSize: requestedVideoContainerSize, constrainedWithin: containerFrame)
    }
    if let containerFrame = containerFrame {
      return constrainWithin(containerFrame, centerInContainer: centerInContainer)
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
  /// • If `centerInContainer` is `true`, `windowFrame` will be centered inside `containerFrame` (will be ignored if `containerFrame` is nil)
  func scale(desiredVideoContainerSize: NSSize? = nil,
             constrainedWithin containerFrame: NSRect? = nil, centerInContainer: Bool = false) -> MainWindowGeometry {
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
      if centerInContainer {
        newWindowFrame = newWindowFrame.size.centeredRect(in: containerFrame)
      }
    }

    Logger.log("Scaled MainWindowGeometry result: \(newWindowFrame)", level: .verbose)
    return self.clone(windowFrame: newWindowFrame)
  }

  func scale(desiredVideoSize: NSSize,
             constrainedWithin containerFrame: NSRect? = nil, centerInContainer: Bool = false) -> MainWindowGeometry {
    Logger.log("Scaling MainWindowGeometry desiredVideoSize: \(desiredVideoSize)", level: .debug)
    var newVideoSize = desiredVideoSize

    let newWidth = max(minVideoWidth, desiredVideoSize.width)
    /// Enforce `videoView.aspectRatio`: Recalculate height using width
    newVideoSize = NSSize(width: newWidth, height: (newWidth / videoAspectRatio).rounded())
    if newVideoSize.height != desiredVideoSize.height {
      // We don't want to see too much of this ideally
      Logger.log("While scaling: applied aspectRatio (\(videoAspectRatio)): changed newVideoSize.height by \(newVideoSize.height - desiredVideoSize.height)", level: .debug)
    }

    /// Use `videoSize` for `desiredVideoContainerSize`:
    return scale(desiredVideoContainerSize: newVideoSize, constrainedWithin: containerFrame, centerInContainer: centerInContainer)
  }

  // Resizes the window appropriately
  func resizeOutsideBars(newOutsideTopHeight: CGFloat? = nil, newOutsideTrailingWidth: CGFloat? = nil,
                         newOutsideBottomBarHeight: CGFloat? = nil, newOutsideLeadingWidth: CGFloat? = nil) -> MainWindowGeometry {

    var ΔW: CGFloat = 0
    var ΔH: CGFloat = 0
    var ΔX: CGFloat = 0
    var ΔY: CGFloat = 0
    if let newOutsideTopHeight = newOutsideTopHeight {
      let ΔTop = abs(newOutsideTopHeight) - self.outsideTopBarHeight
      ΔH += ΔTop
    }
    if let newOutsideTrailingWidth = newOutsideTrailingWidth {
      let ΔRight = abs(newOutsideTrailingWidth) - self.outsideTrailingBarWidth
      ΔW += ΔRight
    }
    if let newOutsideBottomBarHeight = newOutsideBottomBarHeight {
      let ΔBottom = abs(newOutsideBottomBarHeight) - self.outsideBottomBarHeight
      ΔH += ΔBottom
      ΔY -= ΔBottom
    }
    if let newOutsideLeadingWidth = newOutsideLeadingWidth {
      let ΔLeft = abs(newOutsideLeadingWidth) - self.outsideLeadingBarWidth
      ΔW += ΔLeft
      ΔX -= ΔLeft
    }

    let newWindowFrame = CGRect(x: windowFrame.origin.x + ΔX,
                                y: windowFrame.origin.y + ΔY,
                                width: windowFrame.width + ΔW,
                                height: windowFrame.height + ΔH)
    return self.clone(windowFrame: newWindowFrame,
                      outsideTopBarHeight: newOutsideTopHeight, outsideTrailingBarWidth: newOutsideTrailingWidth,
                      outsideBottomBarHeight: newOutsideBottomBarHeight, outsideLeadingBarWidth: newOutsideLeadingWidth)
  }

  /** Calculate the window frame from a parsed struct of mpv's `geometry` option. */
  func apply(mpvGeometry: GeometryDef, andDesiredVideoSize desiredVideoSize: NSSize? = nil, inScreenFrame screenFrame: NSRect) -> MainWindowGeometry {
    let maxVideoSize = computeMaxVideoSize(in: screenFrame.size)

    var newVideoSize = videoSize
    if let desiredVideoSize = desiredVideoSize {
      newVideoSize.width = desiredVideoSize.width
      newVideoSize.height = desiredVideoSize.height
    }
    var widthOrHeightIsSet = false
    // w and h can't take effect at same time
    if let strw = mpvGeometry.w, strw != "0" {
      var w: CGFloat
      if strw.hasSuffix("%") {
        w = CGFloat(Double(String(strw.dropLast()))! * 0.01 * Double(maxVideoSize.width))
      } else {
        w = CGFloat(Int(strw)!)
      }
      w = max(minVideoWidth, w)
      newVideoSize.width = w
      newVideoSize.height = w / videoAspectRatio
      widthOrHeightIsSet = true
    } else if let strh = mpvGeometry.h, strh != "0" {
      var h: CGFloat
      if strh.hasSuffix("%") {
        h = CGFloat(Double(String(strh.dropLast()))! * 0.01 * Double(maxVideoSize.height))
      } else {
        h = CGFloat(Int(strh)!)
      }
      h = max(AppData.minVideoSize.height, h)
      newVideoSize.height = h
      newVideoSize.width = h * videoAspectRatio
      widthOrHeightIsSet = true
    }

    var newOrigin = NSPoint()
    // x, origin is window center
    if let strx = mpvGeometry.x, let xSign = mpvGeometry.xSign {
      let x: CGFloat
      if strx.hasSuffix("%") {
        x = CGFloat(Double(String(strx.dropLast()))! * 0.01 * Double(maxVideoSize.width)) - newVideoSize.width / 2
      } else {
        x = CGFloat(Int(strx)!)
      }
      newOrigin.x = xSign == "+" ? x : maxVideoSize.width - x
      // if xSign equals "-", need set right border as origin
      if (xSign == "-") {
        newOrigin.x -= maxVideoSize.width
      }
    }
    // y
    if let stry = mpvGeometry.y, let ySign = mpvGeometry.ySign {
      let y: CGFloat
      if stry.hasSuffix("%") {
        y = CGFloat(Double(String(stry.dropLast()))! * 0.01 * Double(maxVideoSize.height)) - maxVideoSize.height / 2
      } else {
        y = CGFloat(Int(stry)!)
      }
      newOrigin.y = ySign == "+" ? y : maxVideoSize.height - y
      if (ySign == "-") {
        newOrigin.y -= maxVideoSize.height
      }
    }
    // if x and y are not specified
    if mpvGeometry.x == nil && mpvGeometry.y == nil && widthOrHeightIsSet {
      newOrigin.x = (screenFrame.width - newVideoSize.width) / 2
      newOrigin.y = (screenFrame.height - newVideoSize.height) / 2
    }

    // if the screen has offset
    newOrigin.x += screenFrame.origin.x
    newOrigin.y += screenFrame.origin.y

    let outsideBarsTotalSize = self.outsideBarsTotalSize
    let newWindowFrame = NSRect(origin: newOrigin, size: NSSize(width: newVideoSize.width + outsideBarsTotalSize.width, height: newVideoSize.height + outsideBarsTotalSize.height))
    return self.clone(windowFrame: newWindowFrame)
  }

}

extension MainWindowController {

  // MARK: - UI: Window size / aspect

  /** Set window size when info available, or video size changed. Called in response to receiving 'video-reconfig' msg  */
  func adjustFrameAfterVideoReconfig() {
    guard let window = window else { return }

    log.verbose("[AdjustFrameAfterVideoReconfig] Start")

    let oldVideoAspectRatio = videoView.aspectRatio
    // Will only change the video size & video container size. Panels outside the video do not change size
    let oldVideoSize = videoView.frame.size

    // Get "correct" video size from mpv
    let videoBaseDisplaySize = player.videoBaseDisplaySize ?? AppData.sizeWhenNoVideo
    // Update aspect ratio & constraint
    videoView.updateAspectRatio(to: videoBaseDisplaySize.aspect)
    if #available(macOS 10.12, *) {
      pip.aspectRatio = videoBaseDisplaySize
    }


    var scaleDownFactor: CGFloat? = nil

    if player.isInMiniPlayer {
      log.debug("[AdjustFrameAfterVideoReconfig] Player is in music mode; ignoring mpv video-reconfig")

    } else if player.info.isRestoring {
      // To account for imprecision(s) due to floats coming from multiple sources,
      // just compare the first 6 digits after the decimal (strings make it easier)
      let oldAspect = oldVideoAspectRatio.string6f
      let newAspect = videoView.aspectRatio.string6f
      if oldAspect == newAspect {
        log.verbose("[AdjustFrameAfterVideoReconfig A] Restore is in progress; ignoring mpv video-reconfig")
      } else {
        log.error("[AdjustFrameAfterVideoReconfig B] Aspect ratio mismatch during restore! Expected \(newAspect), found \(oldAspect). Will attempt to correct by resizing window.")
        resizeVideoContainer()
      }

    } else {
      let currentWindowGeo = getCurrentWindowGeometry()
      let newWindowGeo: MainWindowGeometry

      if shouldResizeWindowAfterVideoReconfig() {
        // get videoSize on screen
        var newVideoSize: NSSize = videoBaseDisplaySize
        log.verbose("[AdjustFrameAfterVideoReconfig C step1]  Starting calc: set newVideoSize := videoBaseDisplaySize → \(videoBaseDisplaySize)")

        // TODO
        if false && Preference.bool(for: .usePhysicalResolution) {
          let invertedScaleFactor = 1.0 / window.backingScaleFactor
          scaleDownFactor = invertedScaleFactor
          newVideoSize = videoBaseDisplaySize.multiplyThenRound(invertedScaleFactor)
          log.verbose("[AdjustFrameAfterVideoReconfig C step2] Converted newVideoSize to physical resolution → \(newVideoSize)")
        }

        let resizeWindowStrategy: Preference.ResizeWindowOption? = player.info.justStartedFile ? Preference.enum(for: .resizeWindowOption) : nil
        if let strategy = resizeWindowStrategy, strategy != .fitScreen {
          let resizeRatio = strategy.ratio
          newVideoSize = newVideoSize.multiply(CGFloat(resizeRatio))
          log.verbose("[AdjustFrameAfterVideoReconfig C step3] Applied resizeRatio (\(resizeRatio)) to newVideoSize → \(newVideoSize)")
        }

        let screenVisibleFrame = bestScreen.visibleFrame

        // check if have geometry set (initial window position/size)
        if shouldApplyInitialWindowSize, let mpvGeometry = player.getGeometry() {
          log.verbose("[AdjustFrameAfterVideoReconfig C step4 optionA] shouldApplyInitialWindowSize=Y. Converting mpv \(mpvGeometry) and constraining by screen \(screenVisibleFrame)")
          newWindowGeo = currentWindowGeo.apply(mpvGeometry: mpvGeometry, andDesiredVideoSize: newVideoSize, inScreenFrame: screenVisibleFrame)
        } else {
          if let strategy = resizeWindowStrategy, strategy == .fitScreen {
            log.verbose("[AdjustFrameAfterVideoReconfig C step4 optionB] FitToScreen strategy. Using screenFrame \(screenVisibleFrame)")
            newWindowGeo = currentWindowGeo.scale(desiredVideoContainerSize: screenVisibleFrame.size, constrainedWithin: screenVisibleFrame, centerInContainer: true)
          } else {
            log.verbose("[AdjustFrameAfterVideoReconfig C step4 optionC] Resizing windowFrame \(currentWindowGeo.windowFrame) to videoSize + outside panels → windowFrame")
            newWindowGeo = currentWindowGeo.scale(desiredVideoSize: newVideoSize, constrainedWithin: screenVisibleFrame, centerInContainer: true)
          }
        }

      } else {  /// `!shouldResizeWindowAfterVideoReconfig()`
        // user is navigating in playlist. retain same window width.
        // This often isn't possible for vertical videos, which will end up shrinking the width.
        // So try to remember the preferred width so it can be restored when possible
        var desiredVidConSize = currentWindowGeo.videoContainerSize

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

        newWindowGeo = currentWindowGeo.scale(desiredVideoContainerSize: desiredVidConSize, constrainedWithin: bestScreen.visibleFrame)
        log.verbose("[AdjustFrameAfterVideoReconfig D] Assuming user is navigating in playlist. Applying desiredVidConSize \(desiredVidConSize)")
      }

      /// Finally call `setFrame()`
      log.debug("[AdjustFrameAfterVideoReconfig] Result from newVideoSize: \(newWindowGeo.videoSize), oldVideoSize: \(oldVideoSize), isFS:\(fsState.isFullscreen.yn) → setting newWindowFrame: \(newWindowGeo.windowFrame)")
      setCurrentWindowGeometry(to: newWindowGeo, enqueueAnimation: false, setFrameImmediately: false)

      if !fsState.isFullscreen {
        // If adjusted by backingScaleFactor, need to reverse the adjustment when reporting to mpv
        let mpvVideoSize: CGSize
        if let scaleDownFactor = scaleDownFactor {
          mpvVideoSize = newWindowGeo.videoSize.multiplyThenRound(scaleDownFactor)
        } else {
          mpvVideoSize = newWindowGeo.videoSize
        }
        updateWindowParametersForMPV(withSize: mpvVideoSize)
      }

      // UI and slider
      updatePlayTime(withDuration: true)
      player.events.emit(.windowSizeAdjusted, data: newWindowGeo.windowFrame)
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
    // FIXME: when rapidly moving between files this can fall out of sync. Find a better solution
    if player.info.justStartedFile {
      // resize option applies
      let resizeTiming = Preference.enum(for: .resizeWindowTiming) as Preference.ResizeWindowTiming
      switch resizeTiming {
      case .always:
        log.verbose("[AdjustFrameAfterVideoReconfig C] JustStartedFile & resizeTiming='Always' → returning YES for shouldResize")
        return true
      case .onlyWhenOpen:
        log.verbose("[AdjustFrameAfterVideoReconfig C] JustStartedFile & resizeTiming='OnlyWhenOpen' → returning justOpenedFile (\(player.info.justOpenedFile.yesno)) for shouldResize")
        return player.info.justOpenedFile
      case .never:
        log.verbose("[AdjustFrameAfterVideoReconfig C] JustStartedFile & resizeTiming='Never' → returning NO for shouldResize")
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
  func resizeVideoContainer(desiredVideoContainerSize: CGSize? = nil, centerOnScreen: Bool = false) {
    guard !isInInteractiveMode, fsState == .windowed else { return }

    let newGeoUnconstrained = getCurrentWindowGeometry().scale(desiredVideoContainerSize: desiredVideoContainerSize)
    // User has actively resized the video. Assume this is the new preferred resolution
    player.info.setUserPreferredVideoContainerSize(newGeoUnconstrained.videoContainerSize)

    let newGeometry = newGeoUnconstrained.constrainWithin(bestScreen.visibleFrame, centerInContainer: centerOnScreen)
    log.verbose("\(fsState.isFullscreen ? "Updating priorWindowedGeometry" : "Calling setFrame()") from resizeVideoContainer (center=\(centerOnScreen.yn)), to: \(newGeometry.windowFrame)")
    setCurrentWindowGeometry(to: newGeometry, enqueueAnimation: true)
  }

  /// If in fullscreen, returns `fsState.priorWindowedGeometry`. Else builds from `currentLayout` and other variables.
  /// Must be called from the main thread.
  func getCurrentWindowGeometry() -> MainWindowGeometry {
    dispatchPrecondition(condition: .onQueue(DispatchQueue.main))

    if let priorGeo = fsState.priorWindowedGeometry {
      log.debug("GetCurrentWindowGeometry(): looks like we are in full screen. Returning priorWindowedGeometry")
      return priorGeo
    }

    return windowGeometry
  }

  func setCurrentWindowGeometry(to newGeometry: MainWindowGeometry, enqueueAnimation: Bool = true, animate: Bool = true, setFrameImmediately: Bool = true) {
    let newWindowFrame = newGeometry.windowFrame
    if fsState.isFullscreen {
      log.verbose("Updating priorWindowedGeometry because window is in full screen, with windowFrame \(newWindowFrame)")
      fsState.priorWindowedGeometry = newGeometry
      return
    }

    windowGeometry = newGeometry

    guard let window = window else { return }

    /// Using `setFrameImmediately()` usually provides a smoother animation and plays better with other animations,
    /// although this is not true in every case.
    if enqueueAnimation {
      animationQueue.run(CocoaAnimation.Task(duration: CocoaAnimation.DefaultDuration, timing: .easeInEaseOut, { [self] in
        if setFrameImmediately {
          (window as! MainWindow).setFrameImmediately(newWindowFrame, animate: animate)
        } else {
          window.setFrame(newWindowFrame, display: true, animate: animate)
        }
        player.saveState()
      }))
    } else {
      if setFrameImmediately {
        (window as! MainWindow).setFrameImmediately(newWindowFrame, animate: animate)
      } else {
        window.setFrame(newWindowFrame, display: true, animate: animate)
      }
      player.saveState()
    }
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

    if player.isInMiniPlayer {
      _ = miniPlayer.view
      return miniPlayer.windowWillResize(window, to: requestedSize)
    }

    let newSize = tryToResizeWindow(window, to: requestedSize)

    updateSpacingForTitleBarAccessories(windowWidth: newSize.width)
    return newSize
  }

  private func tryToResizeWindow(_ window: NSWindow, to requestedSize: NSSize) -> NSSize {
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

    let currentGeo = getCurrentWindowGeometry()
    let outsideBarsSize = currentGeo.outsideBarsTotalSize

    if !window.inLiveResize && ((requestedSize.height < currentGeo.minVideoHeight + outsideBarsSize.height)
                                || (requestedSize.width < currentGeo.minVideoWidth + outsideBarsSize.width)) {
      // Sending the current size seems to work much better with accessibilty requests
      // than trying to change to the min size
      log.verbose("WindowWillResize: requested smaller than min \(AppData.minVideoSize); returning existing \(window.frame.size)")
      return window.frame.size
    }

    // Need to resize window to match video aspect ratio, while
    // taking into account any outside panels

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

    if player.isInMiniPlayer {
      _ = miniPlayer.view
      // Re-evaluate space requirements for labels. May need to toggle scroll
      miniPlayer.windowDidResize()
      return
    }

    defer {
      updateSpacingForTitleBarAccessories(windowWidth: window.frame.width)
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

    if player.isInMiniPlayer {
      _ = miniPlayer.view
      miniPlayer.saveCurrentPlaylistHeight()
      return
    }

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
