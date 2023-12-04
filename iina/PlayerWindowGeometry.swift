//
//  PlayerWindowGeometry.swift
//  iina
//
//  Created by Matt Svoboda on 7/11/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/**
 `ScreenFitOption`
  Describes how a given player window must fit inside its given screen.
 */
enum ScreenFitOption: Int {

  case noConstraints = 0

  /// Constrains inside `screen.visibleFrame`
  case keepInVisibleScreen

  /// Constrains and centers inside `screen.visibleFrame`
  case centerInVisibleScreen

  /// Constrains inside `screen.frame`
  case legacyFullScreen

  /// Constrains inside `screen.frameWithoutCameraHousing`. Provided here for completeness, but not used at present.
  case nativeFullScreen

  var isFullScreen: Bool {
    switch self {
    case .legacyFullScreen, .nativeFullScreen:
      return true
    default:
      return false
    }
  }
}

/**
`PlayerWindowGeometry`
 Data structure which describes the basic layout configuration of a player window (`PlayerWindowController`).

 For `let wc = PlayerWindowController()`, an instance of this class describes:
 1. The size & position (`windowFrame`) of an IINA player `NSWindow`.
 2. The size of the window's viewport (`viewportView` in a `PlayerWindowController` instance).
    The viewport contains the `videoView` and all of the `Preference.PanelPlacement.inside` views (`viewportSize`). size is inferred by subtracting the bar sizes
 from `windowFrame`.
 3. Either the height or width of each of the 4 `outsideViewport` bars, measured as the distance between the
    outside edge of `viewportView` and the outermost edge of the bar. This is the minimum needed to determine
    its size & position; the rest can be inferred from `windowFrame` and `viewportSize`.
    If instead the bar is hidden or is shown as `insideViewport`, its outside value will be `0`.
 4. Either  height or width of each of the 4 `insideViewport` bars. These are measured from the nearest outside wall of
    `viewportView`.  If instead the bar is hidden or is shown as `outsideViewport`, its inside value will be `0`.
 5. The size of the video itself (`videoView`), which may or may not be equal to the size of `viewportView`,
    depending on whether empty space is allowed around the video.
 6. The video aspect ratio. This is stored here mainly to create a central reference for it, to avoid differing
    values which can arise if calculating it from disparate sources.

 Below is an example of a player window with letterboxed video, where the viewport is taller than `videoView`.
 • Identifiers beginning with `wc.` refer to fields in the `PlayerWindowController` instance.
 • Identifiers beginning with `geo.` are `PlayerWindowGeometry` fields.
 • The window's frame (`windowFrame`) is the outermost rectangle.
 • The frame of `wc.videoView` is the innermost dotted-lined rectangle.
 • The frame of `wc.viewportView` contains `wc.videoView` and additional space for black bars.
 •
 ~
 ~                            `geo.viewportSize.width`
 ~                             (of `wc.viewportView`)
 ~                             ◄---------------►
 ┌─────────────────────────────────────────────────────────────────────────────┐`geo.windowFrame`
 │                                 ▲`geo.topMarginHeight`                      │
 │                                 ▼ (only used to cover Macbook notch)        │
 ├─────────────────────────────────────────────────────────────────────────────┤
 │                               ▲                                             │
 │                               ┊`geo.outsideTopBarHeight`                    │
 │                               ▼   (`wc.topBarView`)                         │
 ├────────────────────────────┬─────────────────┬──────────────────────────────┤ ─ ◄--- `geo.insideTopBarHeight == 0`
 │                            │black bar (empty)│                              │ ▲
 │                            ├─────────────────┤                              │ ┊ `geo.viewportSize.height`
 │◄--------------------------►│ `geo.videoSize` │◄----------------------------►│ ┊  (of `wc.viewportView`)
 │                            │(`wc.videoView`) │ `geo.outsideTrailingBarWidth`│ ┊
 │`geo.outsideLeadingBarWidth`├─────────────────┤ (of `wc.trailingSidebarView`)│ ┊
 │(of `wc.leadingSidebarView`)│black bar (empty)│                              │ ▼
 ├────────────────────────────┴─────────────────┴──────────────────────────────┤ ─ ◄--- `geo.insideBottomBarHeight == 0`
 │                                ▲                                            │
 │                                ┊`geo.outsideBottomBarHeight`                │
 │                                ▼   (of `wc.bottomBarView`)                  │
 └─────────────────────────────────────────────────────────────────────────────┘
 */
struct PlayerWindowGeometry: Equatable {
  // MARK: - Stored properties

  // The ID of the screen on which this window is displayed
  let screenID: String
  let fitOption: ScreenFitOption

  /// The size & position (`window.frame`) of an IINA player `NSWindow`.
  let windowFrame: NSRect

  // Extra black space (if any) above outsideTopBar, used for covering MacBook's magic camera housing while in legacy fullscreen
  let topMarginHeight: CGFloat

  // Outside panels
  let outsideTopBarHeight: CGFloat
  let outsideTrailingBarWidth: CGFloat
  let outsideBottomBarHeight: CGFloat
  let outsideLeadingBarWidth: CGFloat

  // Inside panels
  let insideTopBarHeight: CGFloat
  let insideTrailingBarWidth: CGFloat
  let insideBottomBarHeight: CGFloat
  let insideLeadingBarWidth: CGFloat

  let videoAspectRatio: CGFloat
  let videoSize: NSSize

  var lockViewportToVideoSize: Bool {
    return Preference.bool(for: .lockViewportToVideoSize)
  }

  // MARK: - Initializers

  init(windowFrame: NSRect, screenID: String, fitOption: ScreenFitOption, topMarginHeight: CGFloat,
       outsideTopBarHeight: CGFloat, outsideTrailingBarWidth: CGFloat, outsideBottomBarHeight: CGFloat, outsideLeadingBarWidth: CGFloat,
       insideTopBarHeight: CGFloat, insideTrailingBarWidth: CGFloat, insideBottomBarHeight: CGFloat, insideLeadingBarWidth: CGFloat,
       videoAspectRatio: CGFloat, videoSize: NSSize? = nil) {

    self.windowFrame = windowFrame
    self.screenID = screenID
    self.fitOption = fitOption

    assert(topMarginHeight >= 0, "Expected topMarginHeight >= 0, found \(topMarginHeight)")
    self.topMarginHeight = topMarginHeight

    assert(outsideTopBarHeight >= 0, "Expected outsideTopBarHeight >= 0, found \(outsideTopBarHeight)")
    assert(outsideTrailingBarWidth >= 0, "Expected outsideTrailingBarWidth >= 0, found \(outsideTrailingBarWidth)")
    assert(outsideBottomBarHeight >= 0, "Expected outsideBottomBarHeight >= 0, found \(outsideBottomBarHeight)")
    assert(outsideLeadingBarWidth >= 0, "Expected outsideLeadingBarWidth >= 0, found \(outsideLeadingBarWidth)")
    self.outsideTopBarHeight = outsideTopBarHeight
    self.outsideTrailingBarWidth = outsideTrailingBarWidth
    self.outsideBottomBarHeight = outsideBottomBarHeight
    self.outsideLeadingBarWidth = outsideLeadingBarWidth

    assert(insideTopBarHeight >= 0, "Expected insideTopBarHeight >= 0, found \(insideTopBarHeight)")
    assert(insideTrailingBarWidth >= 0, "Expected insideTrailingBarWidth >= 0, found \(insideTrailingBarWidth)")
    assert(insideBottomBarHeight >= 0, "Expected insideBottomBarHeight >= 0, found \(insideBottomBarHeight)")
    assert(insideLeadingBarWidth >= 0, "Expected insideLeadingBarWidth >= 0, found \(insideLeadingBarWidth)")
    self.insideTopBarHeight = insideTopBarHeight
    self.insideTrailingBarWidth = insideTrailingBarWidth
    self.insideBottomBarHeight = insideBottomBarHeight
    self.insideLeadingBarWidth = insideLeadingBarWidth

    self.videoAspectRatio = videoAspectRatio

    let viewportSize = PlayerWindowGeometry.computeViewportSize(from: windowFrame, topMarginHeight: topMarginHeight, outsideTopBarHeight: outsideTopBarHeight, outsideTrailingBarWidth: outsideTrailingBarWidth, outsideBottomBarHeight: outsideBottomBarHeight, outsideLeadingBarWidth: outsideLeadingBarWidth)
    self.videoSize = videoSize ?? PlayerWindowGeometry.computeVideoSize(withAspectRatio: videoAspectRatio, toFillIn: viewportSize)
  }

  static func fullScreenWindowFrame(in screen: NSScreen, legacy: Bool) -> NSRect {
    if legacy {
      return screen.frame
    } else {
      return screen.frameWithoutCameraHousing
    }
  }

  /// See also `LayoutState.buildFullScreenGeometry()`.
  static func forFullScreen(in screen: NSScreen, legacy: Bool,
                            outsideTopBarHeight: CGFloat, outsideTrailingBarWidth: CGFloat, 
                            outsideBottomBarHeight: CGFloat, outsideLeadingBarWidth: CGFloat,
                            insideTopBarHeight: CGFloat, insideTrailingBarWidth: CGFloat, 
                            insideBottomBarHeight: CGFloat, insideLeadingBarWidth: CGFloat,
                            videoAspectRatio: CGFloat) -> PlayerWindowGeometry {

    let windowFrame = fullScreenWindowFrame(in: screen, legacy: legacy)
    let fitOption: ScreenFitOption
    let topMarginHeight: CGFloat
    if legacy {
      topMarginHeight = Preference.bool(for: .allowVideoToOverlapCameraHousing) ? 0 : screen.cameraHousingHeight ?? 0
      fitOption = .legacyFullScreen
    } else {
      topMarginHeight = 0
      fitOption = .nativeFullScreen
    }

    return PlayerWindowGeometry(windowFrame: windowFrame, screenID: screen.screenID, fitOption: fitOption, 
                                topMarginHeight: topMarginHeight,
                                outsideTopBarHeight: outsideTopBarHeight, outsideTrailingBarWidth: outsideTrailingBarWidth,
                                outsideBottomBarHeight: outsideBottomBarHeight, outsideLeadingBarWidth: outsideLeadingBarWidth,
                                insideTopBarHeight: insideTopBarHeight, insideTrailingBarWidth: insideTrailingBarWidth,
                                insideBottomBarHeight: insideBottomBarHeight, insideLeadingBarWidth: insideLeadingBarWidth,
                                videoAspectRatio: videoAspectRatio)
  }

  func clone(windowFrame: NSRect? = nil, screenID: String? = nil, fitOption: ScreenFitOption? = nil,
             topMarginHeight: CGFloat? = nil,
             outsideTopBarHeight: CGFloat? = nil, outsideTrailingBarWidth: CGFloat? = nil,
             outsideBottomBarHeight: CGFloat? = nil, outsideLeadingBarWidth: CGFloat? = nil,
             insideTopBarHeight: CGFloat? = nil, insideTrailingBarWidth: CGFloat? = nil,
             insideBottomBarHeight: CGFloat? = nil, insideLeadingBarWidth: CGFloat? = nil,
             videoAspectRatio: CGFloat? = nil, videoSize: NSSize? = nil) -> PlayerWindowGeometry {

    return PlayerWindowGeometry(windowFrame: windowFrame ?? self.windowFrame,
                                screenID: screenID ?? self.screenID,
                                fitOption: fitOption ?? self.fitOption,
                                topMarginHeight: topMarginHeight ?? self.topMarginHeight,
                                outsideTopBarHeight: outsideTopBarHeight ?? self.outsideTopBarHeight,
                                outsideTrailingBarWidth: outsideTrailingBarWidth ?? self.outsideTrailingBarWidth,
                                outsideBottomBarHeight: outsideBottomBarHeight ?? self.outsideBottomBarHeight,
                                outsideLeadingBarWidth: outsideLeadingBarWidth ?? self.outsideLeadingBarWidth,
                                insideTopBarHeight: insideTopBarHeight ?? self.insideTopBarHeight,
                                insideTrailingBarWidth: insideTrailingBarWidth ?? self.insideTrailingBarWidth,
                                insideBottomBarHeight: insideBottomBarHeight ?? self.insideBottomBarHeight,
                                insideLeadingBarWidth: insideLeadingBarWidth ?? self.insideLeadingBarWidth,
                                videoAspectRatio: videoAspectRatio ?? self.videoAspectRatio,
                                videoSize: videoSize)
  }

  func hasEqual(windowFrame windowFrame2: NSRect? = nil, videoSize videoSize2: NSSize? = nil) -> Bool {
    return PlayerWindowGeometry.areEqual(windowFrame1: windowFrame, windowFrame2: windowFrame2, videoSize1: videoSize, videoSize2: videoSize2)
  }

  static func areEqual(windowFrame1: NSRect? = nil, windowFrame2: NSRect? = nil, videoSize1: NSSize? = nil, videoSize2: NSSize? = nil) -> Bool {
    if let windowFrame1, let windowFrame2 {
      if !windowFrame1.equalTo(windowFrame2) {
        return false
      }
    }
    if let videoSize1, let videoSize2 {
      if !(videoSize1.width == videoSize2.width && videoSize1.height == videoSize2.height) {
        return false
      }
    }
    return true
  }

  // MARK: - Computed properties

  /// This will be equal to `videoSize`, unless IINA is configured to allow the window to expand beyond
  /// the bounds of the video for a letterbox/pillarbox effect (separate from anything mpv includes)
  var viewportSize: NSSize {
    return NSSize(width: windowFrame.width - outsideTrailingBarWidth - outsideLeadingBarWidth,
                  height: windowFrame.height - outsideTopBarHeight - outsideBottomBarHeight)
  }

  var viewportFrameInScreenCoords: NSRect {
    let origin = CGPoint(x: windowFrame.origin.x + outsideLeadingBarWidth, 
                         y: windowFrame.origin.y + outsideBottomBarHeight)
    return NSRect(origin: origin, size: viewportSize)
  }

  var videoFrameInScreenCoords: NSRect {
    let videoFrameInWindowCoords = videoFrameInWindowCoords
    let origin = CGPoint(x: windowFrame.origin.x + videoFrameInWindowCoords.origin.x,
                         y: windowFrame.origin.y + videoFrameInWindowCoords.origin.y)
    return NSRect(origin: origin, size: videoSize)
  }

  var videoFrameInWindowCoords: NSRect {
    let viewportSize = viewportSize
    assert(viewportSize.width - videoSize.width >= 0)
    assert(viewportSize.height - videoSize.height >= 0)
    let leadingBlackSpace = (viewportSize.width - videoSize.width) * 0.5
    let bottomBlackSpace = (viewportSize.height - videoSize.height) * 0.5
    let origin = CGPoint(x: outsideLeadingBarWidth + leadingBlackSpace,
                         y: outsideBottomBarHeight + bottomBlackSpace)
    return NSRect(origin: origin, size: videoSize)
  }

  var outsideBarsTotalWidth: CGFloat {
    return outsideTrailingBarWidth + outsideLeadingBarWidth
  }

  var outsideBarsTotalHeight: CGFloat {
    return outsideTopBarHeight + outsideBottomBarHeight
  }

  var outsideBarsTotalSize: NSSize {
    return NSSize(width: outsideBarsTotalWidth, height: outsideTopBarHeight + outsideBottomBarHeight)
  }

  var minVideoHeight: CGFloat {
    // Limiting factor will most likely be sidebars
    return minVideoWidth / videoAspectRatio
  }

  var minVideoWidth: CGFloat {
    return max(AppData.minVideoSize.width, insideLeadingBarWidth + insideTrailingBarWidth + Constants.Sidebar.minSpaceBetweenInsideSidebars)
  }

  var hasTopPaddingForCameraHousing: Bool {
    return topMarginHeight > 0
  }

  // MARK: - Functions

  /// Returns the limiting frame for the given `fitOption`, inside which the player window must fit.
  /// If no fit needed, returns `nil`.
  static func getContainerFrame(forScreenID screenID: String, fitOption: ScreenFitOption) -> NSRect? {
    let screen = NSScreen.getScreenOrDefault(screenID: screenID)

    switch fitOption {
    case .noConstraints:
      return nil
    case .keepInVisibleScreen, .centerInVisibleScreen:
      return screen.visibleFrame
    case .legacyFullScreen:
      return screen.frame
    case .nativeFullScreen:
      return screen.frameWithoutCameraHousing
    }
  }

  private func getContainerFrame(fitOption: ScreenFitOption? = nil) -> NSRect? {
    return PlayerWindowGeometry.getContainerFrame(forScreenID: screenID, fitOption: fitOption ?? self.fitOption)
  }
  
  static func computeViewportSize(from windowFrame: NSRect, topMarginHeight: CGFloat,
                                  outsideTopBarHeight: CGFloat, outsideTrailingBarWidth: CGFloat,
                                  outsideBottomBarHeight: CGFloat, outsideLeadingBarWidth: CGFloat) -> NSSize {
    return NSSize(width: windowFrame.width - outsideTrailingBarWidth - outsideLeadingBarWidth,
                  height: windowFrame.height - outsideTopBarHeight - outsideBottomBarHeight - topMarginHeight)
  }

  static func computeVideoSize(withAspectRatio videoAspectRatio: CGFloat, toFillIn viewportSize: NSSize) -> NSSize {
    if viewportSize.width == 0 || viewportSize.height == 0 {
      return NSSize(width: 0, height: 0)
    }
    /// Compute `videoSize` to fit within `viewportSize` while maintaining `videoAspectRatio`:
    if videoAspectRatio < viewportSize.aspect {  // video is taller, shrink to meet height
      var videoWidth = viewportSize.height * videoAspectRatio
      // Snap to viewport if within 1 px to smooth out division imprecision
      if abs(videoWidth - viewportSize.width) < 1 {
        videoWidth = viewportSize.width
      }
      return NSSize(width: videoWidth, height: viewportSize.height)
    } else {  // video is wider, shrink to meet width
      var videoHeight = viewportSize.width / videoAspectRatio
      // Snap to viewport if within 1 px to smooth out division imprecision
      if abs(videoHeight - viewportSize.height) < 1 {
        videoHeight = viewportSize.height
      }
      return NSSize(width: viewportSize.width, height: videoHeight)
    }
  }

  fileprivate func computeMaxViewportSize(in containerSize: NSSize) -> NSSize {
    // Resize only the video. Panels outside the video do not change size.
    // To do this, subtract the "outside" panels from the container frame
    return NSSize(width: containerSize.width - outsideBarsTotalSize.width,
                  height: containerSize.height - outsideBarsTotalSize.height)
  }

  // Computes & returns the max video size with proper aspect ratio which can fit in the given container, after subtracting outside bars
  fileprivate func computeMaxVideoSize(in containerSize: NSSize) -> NSSize {
    let maxVidConSize = computeMaxViewportSize(in: containerSize)
    return PlayerWindowGeometry.computeVideoSize(withAspectRatio: videoAspectRatio, toFillIn: maxVidConSize)
  }

  private func constrainAboveMin(desiredViewportSize: NSSize) -> NSSize {
    let constrainedWidth = max(minVideoWidth, desiredViewportSize.width)
    let constrainedHeight = max(minVideoHeight, desiredViewportSize.height)
    return NSSize(width: constrainedWidth, height: constrainedHeight)
  }

  private func constrainBelowMax(desiredViewportSize: NSSize, maxSize: NSSize) -> NSSize {
    let outsideBarsTotalSize = self.outsideBarsTotalSize
    return NSSize(width: min(desiredViewportSize.width, maxSize.width - outsideBarsTotalSize.width),
                  height: min(desiredViewportSize.height, maxSize.height - outsideBarsTotalSize.height))
  }

  func refit(_ newFit: ScreenFitOption? = nil, lockViewportToVideoSize: Bool? = nil) -> PlayerWindowGeometry {
    return scaleViewport(fitOption: newFit, lockViewportToVideoSize: lockViewportToVideoSize)
  }

  /// Computes a new `PlayerWindowGeometry`, attempting to attain the given window size.
  func scaleWindow(to desiredWindowSize: NSSize? = nil,
                   screenID: String? = nil,
                   fitOption: ScreenFitOption? = nil) -> PlayerWindowGeometry {
    let requestedViewportSize: NSSize?
    if let desiredWindowSize = desiredWindowSize {
      let outsideBarsTotalSize = outsideBarsTotalSize
      requestedViewportSize = NSSize(width: desiredWindowSize.width - outsideBarsTotalSize.width,
                                     height: desiredWindowSize.height - outsideBarsTotalSize.height)
    } else {
      requestedViewportSize = nil
    }
    return scaleViewport(to: requestedViewportSize, screenID: screenID, fitOption: fitOption)
  }

  /// Computes a new `PlayerWindowGeometry` from this one:
  /// • If `desiredSize` is given, the `windowFrame` will be shrunk or grown as needed, as will the `videoSize` which will
  /// be resized to fit in the new `viewportSize` based on `videoAspectRatio`.
  /// • If `lockViewportToVideoSize` is provided, it will be applied to the resulting `PlayerWindowGeometry`;
  /// otherwise `self.lockViewportToVideoSize` will be used. If `true`, `viewportSize` will be shrunk to the same size as `videoSize`, 
  /// and `windowFrame` will be resized accordingly.
  /// • If `screenID` is provided, it will be associated with the resulting `PlayerWindowGeometry`; otherwise `self.screenID` will be used.
  /// • If `fitOption` is provided, it will be applied to the resulting `PlayerWindowGeometry`; otherwise `self.fitOption` will be used.
  func scaleViewport(to desiredSize: NSSize? = nil,
                     screenID: String? = nil,
                     fitOption: ScreenFitOption? = nil,
                     lockViewportToVideoSize: Bool? = nil) -> PlayerWindowGeometry {

    let lockViewportToVideoSize = lockViewportToVideoSize ?? self.lockViewportToVideoSize

    var newViewportSize = desiredSize ?? viewportSize
    Logger.log("[geo] ScaleViewport start, newViewportSize: \(newViewportSize), lockViewportToVideoSize: \(lockViewportToVideoSize.yn)", level: .verbose)

    /// Make sure `viewportSize` is at least as large as `minVideoSize`:
    newViewportSize = constrainAboveMin(desiredViewportSize: newViewportSize)

    let newScreenID = screenID ?? self.screenID
    // do not center in screen again unless explicitly requested
    var newFitOption = fitOption ?? (self.fitOption == .centerInVisibleScreen ? .keepInVisibleScreen : self.fitOption)
    if newFitOption == .legacyFullScreen || newFitOption == .nativeFullScreen {
      // Programmer screwed up
      Logger.log("[geo] ScaleViewport: invalid fit option: \(newFitOption). Defaulting to 'none'", level: .error)
      newFitOption = .noConstraints
    }

    let containerFrame: NSRect? = PlayerWindowGeometry.getContainerFrame(forScreenID: newScreenID, fitOption: newFitOption)

    /// Constrain `viewportSize` within `containerFrame` if relevant:
    if let containerFrame = containerFrame {
      newViewportSize = constrainBelowMax(desiredViewportSize: newViewportSize, maxSize: containerFrame.size)
    }

    /// Compute `videoSize` to fit within `viewportSize` while maintaining `videoAspectRatio`:
    let newVideoSize = PlayerWindowGeometry.computeVideoSize(withAspectRatio: videoAspectRatio, toFillIn: newViewportSize)
    if lockViewportToVideoSize {
      newViewportSize = newVideoSize
    }

    let outsideBarsSize = self.outsideBarsTotalSize
    let newWindowSize = NSSize(width: round(newViewportSize.width + outsideBarsSize.width),
                               height: round(newViewportSize.height + outsideBarsSize.height))

    // Round the results to prevent excessive window drift due to small imprecisions in calculation
    let deltaX = (newWindowSize.width - windowFrame.size.width) / 2
    let deltaY = (newWindowSize.height - windowFrame.size.height) / 2
    let newWindowOrigin = NSPoint(x: (windowFrame.origin.x - deltaX),
                                  y: (windowFrame.origin.y - deltaY))

    // Move window if needed to make sure the window is not offscreen
    var newWindowFrame = NSRect(origin: newWindowOrigin, size: newWindowSize)
    if let containerFrame = containerFrame {
      Logger.log("[geo] Constraining in containerFrame: \(containerFrame)", level: .verbose)
      newWindowFrame = newWindowFrame.constrain(in: containerFrame)
      if newFitOption == .centerInVisibleScreen {
        newWindowFrame = newWindowFrame.size.centeredRect(in: containerFrame)
      }
    }

    Logger.log("[geo] ScaleViewport done. New windowFrame: \(newWindowFrame)", level: .verbose)
    return self.clone(windowFrame: newWindowFrame, screenID: newScreenID, fitOption: newFitOption, videoSize: newVideoSize)
  }

  func scaleVideo(to desiredVideoSize: NSSize,
                  screenID: String? = nil,
                  fitOption: ScreenFitOption? = nil,
                  lockViewportToVideoSize: Bool? = nil) -> PlayerWindowGeometry {

    let lockViewportToVideoSize = lockViewportToVideoSize ?? self.lockViewportToVideoSize
    Logger.log("[geo] ScaleVideo start, desiredVideoSize: \(desiredVideoSize), videoAspect: \(videoAspectRatio), lockViewportToVideoSize: \(lockViewportToVideoSize)", level: .debug)
    var newVideoSize = desiredVideoSize

    let newWidth = max(minVideoWidth, desiredVideoSize.width)
    /// Enforce `videoView` aspectRatio: Recalculate height using width
    newVideoSize = NSSize(width: newWidth, height: (newWidth / videoAspectRatio))
    if newVideoSize.height != desiredVideoSize.height {
      // We don't want to see too much of this ideally
      Logger.log("[geo] ScaleVideo applied aspectRatio (\(videoAspectRatio)): changed newVideoSize.height by \(newVideoSize.height - desiredVideoSize.height)", level: .debug)
    }

    let newViewportSize: NSSize
    if lockViewportToVideoSize {
      /// Use `videoSize` for `desiredViewportSize`:
      newViewportSize = newVideoSize
    } else {
      let scaleRatio = newWidth / videoSize.width
      newViewportSize = viewportSize.multiply(scaleRatio)
    }

    return scaleViewport(to: newViewportSize, screenID: screenID, fitOption: fitOption, lockViewportToVideoSize: lockViewportToVideoSize)
  }

  // Resizes the window appropriately
  func withResizedOutsideBars(newOutsideTopBarHeight: CGFloat? = nil, newOutsideTrailingBarWidth: CGFloat? = nil,
                              newOutsideBottomBarHeight: CGFloat? = nil, newOutsideLeadingBarWidth: CGFloat? = nil) -> PlayerWindowGeometry {

    var ΔW: CGFloat = 0
    var ΔH: CGFloat = 0
    var ΔX: CGFloat = 0
    var ΔY: CGFloat = 0
    if let newOutsideTopBarHeight = newOutsideTopBarHeight {
      let ΔTop = abs(newOutsideTopBarHeight) - self.outsideTopBarHeight
      ΔH += ΔTop
    }
    if let newOutsideTrailingBarWidth = newOutsideTrailingBarWidth {
      let ΔRight = abs(newOutsideTrailingBarWidth) - self.outsideTrailingBarWidth
      ΔW += ΔRight
    }
    if let newOutsideBottomBarHeight = newOutsideBottomBarHeight {
      let ΔBottom = abs(newOutsideBottomBarHeight) - self.outsideBottomBarHeight
      ΔH += ΔBottom
      ΔY -= ΔBottom
    }
    if let newOutsideLeadingBarWidth = newOutsideLeadingBarWidth {
      let ΔLeft = abs(newOutsideLeadingBarWidth) - self.outsideLeadingBarWidth
      ΔW += ΔLeft
      ΔX -= ΔLeft
    }

    let newWindowFrame = CGRect(x: windowFrame.origin.x + ΔX,
                                y: windowFrame.origin.y + ΔY,
                                width: windowFrame.width + ΔW,
                                height: windowFrame.height + ΔH)
    return self.clone(windowFrame: newWindowFrame,
                      outsideTopBarHeight: newOutsideTopBarHeight, outsideTrailingBarWidth: newOutsideTrailingBarWidth,
                      outsideBottomBarHeight: newOutsideBottomBarHeight, outsideLeadingBarWidth: newOutsideLeadingBarWidth)
  }

  func withResizedBars(outsideTopBarHeight: CGFloat? = nil, outsideTrailingBarWidth: CGFloat? = nil,
                       outsideBottomBarHeight: CGFloat? = nil, outsideLeadingBarWidth: CGFloat? = nil,
                       insideTopBarHeight: CGFloat? = nil, insideTrailingBarWidth: CGFloat? = nil,
                       insideBottomBarHeight: CGFloat? = nil, insideLeadingBarWidth: CGFloat? = nil,
                       videoAspectRatio: CGFloat? = nil) -> PlayerWindowGeometry {

    // Inside bars
    var newGeo = clone(insideTopBarHeight: insideTopBarHeight,
                       insideTrailingBarWidth: insideTrailingBarWidth,
                       insideBottomBarHeight: insideBottomBarHeight,
                       insideLeadingBarWidth: insideLeadingBarWidth,
                       videoAspectRatio: videoAspectRatio)
    
    newGeo = newGeo.withResizedOutsideBars(newOutsideTopBarHeight: outsideTopBarHeight,
                                           newOutsideTrailingBarWidth: outsideTrailingBarWidth,
                                           newOutsideBottomBarHeight: outsideBottomBarHeight,
                                           newOutsideLeadingBarWidth: outsideLeadingBarWidth)
    return newGeo.scaleViewport()
  }
  
  /** Calculate the window frame from a parsed struct of mpv's `geometry` option. */
  func apply(mpvGeometry: GeometryDef, andDesiredVideoSize desiredVideoSize: NSSize? = nil) -> PlayerWindowGeometry {
    assert(fitOption != .noConstraints)
    let screenFrame: NSRect = getContainerFrame()!
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

  /// Here, `videoSizeUnscaled` and `cropbox` must be the same scale, which may be different than `self.videoSize`.
  /// The cropbox is the section of the video rect which remains after the crop. Its origin is the lower left of the video.
  func cropVideo(from videoSizeUnscaled: NSSize, to cropbox: NSRect) -> PlayerWindowGeometry {
    // First scale the cropbox to the current window scale
    let scaleRatio = self.videoSize.width / videoSizeUnscaled.width
    let cropboxScaled = NSRect(x: cropbox.origin.x * scaleRatio,
                               y: cropbox.origin.y * scaleRatio,
                               width: cropbox.width * scaleRatio,
                               height: cropbox.height * scaleRatio)

    if cropboxScaled.origin.x > videoSize.width || cropboxScaled.origin.y > videoSize.height {
      Logger.log("[geo] Cannot crop video: the cropbox is completely outside the video! CropboxScaled: \(cropboxScaled), videoSize: \(videoSize)", level: .error)
      return self
    }

    Logger.log("[geo] Cropping from cropbox: \(cropbox), scaled: \(scaleRatio)x -> \(cropboxScaled)")

    let widthRemoved = videoSize.width - cropboxScaled.width
    let heightRemoved = videoSize.height - cropboxScaled.height
    let newWindowFrame = NSRect(x: windowFrame.origin.x + cropboxScaled.origin.x,
                                y: windowFrame.origin.y + cropboxScaled.origin.y,
                                width: windowFrame.width - widthRemoved,
                                height: windowFrame.height - heightRemoved)

    let newVideoAspectRatio = cropbox.size.aspect

    let newFitOption = self.fitOption == .centerInVisibleScreen ? .keepInVisibleScreen : self.fitOption
    Logger.log("[geo] Cropped to new windowFrame: \(newWindowFrame), videoAspectRatio: \(newVideoAspectRatio), screenID: \(screenID), fitOption: \(newFitOption)")
    return self.clone(windowFrame: newWindowFrame, fitOption: newFitOption, videoAspectRatio: newVideoAspectRatio)
  }

  func uncropVideo(videoDisplayRotatedSize: NSSize, cropbox: NSRect, videoScale: CGFloat) -> PlayerWindowGeometry {
    let cropboxScaled = NSRect(x: cropbox.origin.x * videoScale,
                               y: cropbox.origin.y * videoScale,
                               width: cropbox.width * videoScale,
                               height: cropbox.height * videoScale)
    // Figure out part which wasn't cropped:
    let antiCropboxSizeScaled = NSSize(width: (videoDisplayRotatedSize.width - cropbox.width) * videoScale,
                                       height: (videoDisplayRotatedSize.height - cropbox.height) * videoScale)
    let newVideoAspectRatio = videoDisplayRotatedSize.aspect
    let newWindowFrame = NSRect(x: windowFrame.origin.x - cropboxScaled.origin.x,
                                y: windowFrame.origin.y - cropboxScaled.origin.y,
                                width: windowFrame.width + antiCropboxSizeScaled.width,
                                height: windowFrame.height + antiCropboxSizeScaled.height)
    return self.clone(windowFrame: newWindowFrame, videoAspectRatio: newVideoAspectRatio).refit()
  }
}


// MARK: - PlayerWindowController geometry functions

extension PlayerWindowController {

  /// Set window size when info available, or video size changed. Called in response to receiving `video-reconfig` msg
  func mpvVideoDidReconfig() {
    // Get "correct" video size from mpv
    guard let videoParams = player.info.videoParams, let videoDisplayRotatedSize = videoParams.videoDisplayRotatedSize else {
      log.error("[MPVVideoReconfig] Could not get videoDisplayRotatedSize from mpv! Cancelling adjustment")
      return
    }
    log.verbose("[MPVVideoReconfig] Start, videoDisplayRotatedSize: \(videoDisplayRotatedSize)")

    let newVideoAspectRatio = videoDisplayRotatedSize.aspect
    if #available(macOS 10.12, *) {
      pip.aspectRatio = videoDisplayRotatedSize
    }
    guard let screen = window?.screen else { return }

    if isInInteractiveMode, let cropController = self.cropSettingsView, cropController.cropBoxView.didSubmit {
      /// Interactive mode after sumbit: finish crop submission and exit
      cropController.cropBoxView.didSubmit = false
      let originalVideoSize = cropController.cropBoxView.actualSize
      let newVideoFrameUnscaled = NSRect(x: cropController.cropx, y: cropController.cropyFlippedForMac,
                                         width: cropController.cropw, height: cropController.croph)

      animationPipeline.submit(IINAAnimation.Task({ [self] in
        log.verbose("[MPVVideoReconfig] Cropping video from origVideoSize: \(originalVideoSize), currentVideoSize: \(cropController.cropBoxView.videoRect), cropResult: \(newVideoFrameUnscaled)")
        let croppedGeometry = windowedModeGeometry.cropVideo(from: originalVideoSize, to: newVideoFrameUnscaled)
        windowedModeGeometry = croppedGeometry
        player.info.videoAspectRatio = croppedGeometry.videoAspectRatio
        player.info.setIntendedViewportSize(from: croppedGeometry)

        // fade out all this stuff before crop
        cropController.view.alphaValue = 0
        cropController.view.isHidden = true
        cropController.cropBoxView.isHidden = true
        cropController.cropBoxView.alphaValue = 0
        cropController.view.removeFromSuperview()
        cropController.cropBoxView.removeFromSuperview()

        if currentLayout.isFullScreen {
          let newInteractiveModeGeo = currentLayout.buildFullScreenGeometry(inside: screen, videoAspectRatio: croppedGeometry.videoAspectRatio)
          videoView.apply(newInteractiveModeGeo)
        } else {
          let imGeoPrev = interactiveModeGeometry ?? InteractiveModeGeometry.from(windowedModeGeometry)
          interactiveModeGeometry = imGeoPrev.cropVideo(from: originalVideoSize, to: newVideoFrameUnscaled)
          player.window.setFrameImmediately(interactiveModeGeometry!.windowFrame)
        }

        animationPipeline.submitZeroDuration({ [self] in
          forceDraw()
          exitInteractiveMode()
        })
      }))

    } else if !isInInteractiveMode, let prevCrop = player.info.videoFiltersDisabled[Constants.FilterLabel.crop] {
      // Not yet in interactive mode, but the active crop was just disabled prior to entering it,
      // so that full video can be seen during interactive mode
      let prevCropRect = prevCrop.cropRect(origVideoSize: videoDisplayRotatedSize, flipYForMac: true)

      // Extra video-reconfig notifications are generated by this process. Ignore the ones we don't care about:
      guard videoParams.videoDisplayWidth == videoParams.videoRawWidth && videoParams.videoDisplayHeight == videoParams.videoRawHeight else {
        log.verbose("[MPVVideoReconfig] Found a disabled crop filter \(prevCrop.stringFormat.quoted), but videoRawSize \(videoParams.videoRawSize) does not yet match videoDisplaySize \(videoParams.videoDisplaySize); ignoring")
        return
      }

      log.verbose("[MPVVideoReconfig] Found a disabled crop filter: \(prevCrop.stringFormat.quoted). Will enter interactive crop.")
      log.verbose("[MPVVideoReconfig] VideoDisplayRotatedSize: \(videoDisplayRotatedSize), PrevCropRect: \(prevCropRect)")

      animationPipeline.submit(IINAAnimation.Task({ [self] in
        let uncroppedWindowedGeo = windowedModeGeometry.uncropVideo(videoDisplayRotatedSize: videoDisplayRotatedSize, cropbox: prevCropRect,
                                                                    videoScale: player.info.cachedWindowScale)
        // Update the cached objects
        player.info.videoAspectRatio = uncroppedWindowedGeo.videoAspectRatio
        windowedModeGeometry = uncroppedWindowedGeo

        if currentLayout.isFullScreen {
          let fsGeo = currentLayout.buildFullScreenGeometry(inside: screen, videoAspectRatio: uncroppedWindowedGeo.videoAspectRatio)
          videoView.apply(fsGeo)
          forceDraw()
        } else {
          applyWindowGeometry(uncroppedWindowedGeo)
        }
        enterInteractiveMode(.crop)
      }))

    } else if player.info.isRestoring {
      if isInInteractiveMode {
        /// If restoring into interactive mode, we didn't have `videoDisplayRotatedSize` while doing layout. Add it now (if needed)
        animationPipeline.submitZeroDuration({ [self] in
          let videoSize: NSSize
          if currentLayout.isFullScreen {
            let newInteractiveModeGeo = currentLayout.buildFullScreenGeometry(inside: screen, 
                                                                              videoAspectRatio: videoDisplayRotatedSize.aspect)
            videoSize = newInteractiveModeGeo.videoSize
          } else { // windowed
            videoSize = interactiveModeGeometry?.videoSize ?? windowedModeGeometry.videoSize
          }
          log.debug("[MPVVideoReconfig] Restoring crop box origVideoSize=\(videoDisplayRotatedSize), videoSize=\(videoSize)")
          addOrReplaceCropBoxSelection(origVideoSize: videoDisplayRotatedSize, videoSize: videoSize)
        })
        // fall through and apply new parameters
      }

      // Confirm aspect ratio is consistent. To account for imprecision(s) due to floats coming from multiple sources,
      // just compare the first 6 digits after the decimal.
      let oldAspect = player.info.videoAspectRatio.stringTrunc2f
      let newAspect = newVideoAspectRatio.stringTrunc2f
      if oldAspect == newAspect {
        log.verbose("[MPVVideoReconfig A] Restore is in progress; ignoring mpv video-reconfig")
      } else {
        log.error("[MPVVideoReconfig B] Aspect ratio mismatch during restore! Expected \(newAspect), found \(oldAspect). Will attempt to correct by resizing window.")
        /// Set variables and resize viewport to fit properly
        windowedModeGeometry = windowedModeGeometry.clone(videoAspectRatio: newVideoAspectRatio)
        player.info.videoAspectRatio = newVideoAspectRatio
        if currentLayout.mode == .windowed {
          resizeViewport()
        }
      }

    } else if player.isInMiniPlayer {
      log.debug("[MPVVideoReconfig] Player is in music mode; will update its geometry")
      /// Keep prev `windowFrame`. Just adjust height to fit new video aspect ratio
      /// (unless it doesn't fit in screen; see `applyMusicModeGeometry()`)
      let newGeometry = musicModeGeometry.clone(videoAspectRatio: newVideoAspectRatio)
      applyMusicModeGeometryInAnimationTask(newGeometry)

    } else {
      let windowGeo = windowedModeGeometry.clone(videoAspectRatio: videoDisplayRotatedSize.aspect)

      // Will only change the video size & video container size. Panels outside the video do not change size
      let newWindowGeo: PlayerWindowGeometry
      if shouldResizeWindowAfterVideoReconfig() {
        newWindowGeo = resizeWindowAfterVideoReconfig(from: windowGeo, videoDisplayRotatedSize: videoDisplayRotatedSize)
        if currentLayout.mode == .windowed {
          // Update intended viewport to new size
          player.info.setIntendedViewportSize(from: newWindowGeo)
        }
      } else {
        newWindowGeo = resizeMinimallyAfterVideoReconfig(from: windowGeo, videoDisplayRotatedSize: videoDisplayRotatedSize)
      }

      /// Finally call `setFrame()`
      log.debug("[MPVVideoReconfig] Result from newVideoSize: \(newWindowGeo.videoSize), isFS:\(isFullScreen.yn) → setting newWindowFrame: \(newWindowGeo.windowFrame)")
      applyWindowGeometry(newWindowGeo)

      // UI and slider
      player.events.emit(.windowSizeAdjusted, data: newWindowGeo.windowFrame)
    }

    log.debug("[MPVVideoReconfig] Done")
  }

  private func shouldResizeWindowAfterVideoReconfig() -> Bool {
    // FIXME: when rapidly moving between files this can fall out of sync. Find a better solution
    if player.info.justStartedFile {
      // resize option applies
      let resizeTiming = Preference.enum(for: .resizeWindowTiming) as Preference.ResizeWindowTiming
      switch resizeTiming {
      case .always:
        log.verbose("[MPVVideoReconfig C] JustStartedFile & resizeTiming='Always' → returning YES for shouldResize")
        return true
      case .onlyWhenOpen:
        log.verbose("[MPVVideoReconfig C] JustStartedFile & resizeTiming='OnlyWhenOpen' → returning justOpenedFile (\(player.info.justOpenedFile.yesno)) for shouldResize")
        return player.info.justOpenedFile
      case .never:
        log.verbose("[MPVVideoReconfig C] JustStartedFile & resizeTiming='Never' → returning NO for shouldResize")
        return false
      }
    }
    // video size changed during playback
    log.verbose("[MPVVideoReconfig C] JustStartedFile=NO → returning YES for shouldResize")
    return true
  }

  private func resizeWindowAfterVideoReconfig(from windowGeo: PlayerWindowGeometry, 
                                              videoDisplayRotatedSize: NSSize) -> PlayerWindowGeometry {
    // get videoSize on screen
    var newVideoSize: NSSize = videoDisplayRotatedSize
    log.verbose("[MPVVideoReconfig C-1]  Starting calc: set newVideoSize := videoDisplayRotatedSize → \(videoDisplayRotatedSize)")

    let resizeWindowStrategy: Preference.ResizeWindowOption? = player.info.justStartedFile ? Preference.enum(for: .resizeWindowOption) : nil
    if let resizeWindowStrategy, resizeWindowStrategy != .fitScreen {
      let resizeRatio = resizeWindowStrategy.ratio
      newVideoSize = newVideoSize.multiply(CGFloat(resizeRatio))
      log.verbose("[MPVVideoReconfig C-2] Applied resizeRatio (\(resizeRatio)) to newVideoSize → \(newVideoSize)")
    }

    let screenID = player.isInMiniPlayer ? musicModeGeometry.screenID : windowedModeGeometry.screenID
    let screenVisibleFrame = NSScreen.getScreenOrDefault(screenID: screenID).visibleFrame

    // check if have mpv geometry set (initial window position/size)
    if shouldApplyInitialWindowSize, let mpvGeometry = player.getGeometry() {
      log.verbose("[MPVVideoReconfig C-3] shouldApplyInitialWindowSize=Y. Converting mpv \(mpvGeometry) and constraining by screen \(screenVisibleFrame)")
      return windowGeo.apply(mpvGeometry: mpvGeometry, andDesiredVideoSize: newVideoSize)

    } else if let strategy = resizeWindowStrategy, strategy == .fitScreen {
      log.verbose("[MPVVideoReconfig C-4] FitToScreen strategy. Using screenFrame \(screenVisibleFrame)")
      return windowGeo.scaleViewport(to: screenVisibleFrame.size, fitOption: .centerInVisibleScreen)

    } else if !player.info.justStartedFile {
      if Preference.bool(for: .lockViewportToVideoSize) {
        // Try to match previous scale
        newVideoSize = newVideoSize.multiply(player.info.cachedWindowScale)
        log.verbose("[MPVVideoReconfig C-5] Resizing windowFrame \(windowGeo.windowFrame) to prev scale (\(player.info.cachedWindowScale))")
        return windowGeo.scaleVideo(to: newVideoSize, fitOption: .keepInVisibleScreen)
      } else {
        log.verbose("[MPVVideoReconfig C-6] Using prev windowFrame \(windowGeo.windowFrame) with new aspect")
        return windowGeo
      }
    } else {  // started file
      log.verbose("[MPVVideoReconfig C-7] Resizing windowFrame \(windowGeo.windowFrame) to videoSize + outside panels → center windowFrame")
      return windowGeo.scaleVideo(to: newVideoSize, fitOption: .centerInVisibleScreen)
    }
  }

  private func resizeMinimallyAfterVideoReconfig(from windowGeo: PlayerWindowGeometry, 
                                                 videoDisplayRotatedSize: NSSize) -> PlayerWindowGeometry {
    // User is navigating in playlist. retain same window width.
    // This often isn't possible for vertical videos, which will end up shrinking the width.
    // So try to remember the preferred width so it can be restored when possible
    var desiredViewportSize = windowGeo.viewportSize

    if Preference.bool(for: .lockViewportToVideoSize) {
      if let prefVidConSize = player.info.intendedViewportSize  {
        // Just use existing size in this case:
        desiredViewportSize = prefVidConSize
      }

      let minNewVidConHeight = desiredViewportSize.width / videoDisplayRotatedSize.aspect
      if desiredViewportSize.height < minNewVidConHeight {
        // Try to increase height if possible, though it may still be shrunk to fit screen
        desiredViewportSize = NSSize(width: desiredViewportSize.width, height: minNewVidConHeight)
      }
    }

    log.verbose("[MPVVideoReconfig D] Assuming user is navigating in playlist. Applying desiredViewportSize \(desiredViewportSize)")
    return windowGeo.scaleViewport(to: desiredViewportSize)
  }

  // MARK: - Window geometry functions

  func setVideoScale(_ desiredVideoScale: CGFloat) {
    guard let window = window else { return }
    guard currentLayout.mode == .windowed || currentLayout.mode == .musicMode else { return }

    guard let videoDisplayRotatedSize = player.info.videoParams?.videoDisplayRotatedSize else {
      log.error("SetWindowScale failed: could not get videoDisplayRotatedSize")
      return
    }

    var desiredVideoSize = videoDisplayRotatedSize.multiply(desiredVideoScale)

    log.verbose("SetVideoScale: requested scale=\(desiredVideoScale)x, videoDisplayRotatedSize=\(videoDisplayRotatedSize) → desiredVideoSize=\(desiredVideoSize)")

    // TODO
    if false && Preference.bool(for: .usePhysicalResolution) {
      desiredVideoSize = window.convertFromBacking(NSRect(origin: window.frame.origin, size: desiredVideoSize)).size
      log.verbose("SetWindowScale: converted desiredVideoSize to physical resolution: \(desiredVideoSize)")
    }

    switch currentLayout.mode {
    case .windowed:
      let newGeoUnconstrained = windowedModeGeometry.scaleVideo(to: desiredVideoSize, fitOption: .noConstraints)
      // User has actively resized the video. Assume this is the new preferred resolution
      player.info.setIntendedViewportSize(from: newGeoUnconstrained)

      let newGeometry = newGeoUnconstrained.refit(.keepInVisibleScreen)
      log.verbose("SetVideoScale: calling applyWindowGeometry")
      applyWindowGeometry(newGeometry)
    case .musicMode:
      // will return nil if video is not visible
      guard let newMusicModeGeometry = musicModeGeometry.scaleVideo(to: desiredVideoSize) else { return }
      log.verbose("SetVideoScale: calling applyMusicModeGeometry")
      applyMusicModeGeometryInAnimationTask(newMusicModeGeometry)
    default:
      return
    }
  }

  /**
   Resizes and repositions the window, attempting to match `desiredViewportSize`, but the actual resulting
   video size will be scaled if needed so it is`>= AppData.minVideoSize` and `<= screen.visibleFrame`.
   The window's position will also be updated to maintain its current center if possible, but also to
   ensure it is placed entirely inside `screen.visibleFrame`.
   */
  func resizeViewport(to desiredViewportSize: CGSize? = nil, centerOnScreen: Bool = false) {
    guard currentLayout.mode == .windowed || currentLayout.mode == .musicMode else { return }

    switch currentLayout.mode {
    case .windowed:
      let newGeoUnconstrained = windowedModeGeometry.scaleViewport(to: desiredViewportSize, fitOption: .noConstraints)
      // User has actively resized the video. Assume this is the new preferred resolution
      player.info.setIntendedViewportSize(from: newGeoUnconstrained)

      let fitOption: ScreenFitOption = centerOnScreen ? .centerInVisibleScreen : .keepInVisibleScreen
      let newGeometry = newGeoUnconstrained.refit(fitOption)
      log.verbose("Calling applyWindowGeometry from resizeViewport (center=\(centerOnScreen.yn)), to: \(newGeometry.windowFrame)")
      applyWindowGeometry(newGeometry)
    case .musicMode:
      /// In music mode, `viewportSize==videoSize` always. Will get `nil` here if video is not visible
      guard let newMusicModeGeometry = musicModeGeometry.scaleVideo(to: desiredViewportSize) else { return }
      log.verbose("Calling applyMusicModeGeometry from resizeViewport, to: \(newMusicModeGeometry.windowFrame)")
      applyMusicModeGeometryInAnimationTask(newMusicModeGeometry)
    default:
      return
    }
  }

  func scaleVideoByIncrement(_ widthStep: CGFloat) {
    let currentViewportSize: NSSize
    switch currentLayout.mode {
    case .windowed:
      currentViewportSize = windowedModeGeometry.viewportSize
    case .musicMode:
      guard let viewportSize = musicModeGeometry.viewportSize else { return }
      currentViewportSize = viewportSize
    default:
      return
    }
    let heightStep = widthStep / currentViewportSize.aspect
    let desiredViewportSize = CGSize(width: currentViewportSize.width + widthStep, height: currentViewportSize.height + heightStep)
    log.verbose("Incrementing viewport width by \(widthStep), to desired size \(desiredViewportSize)")
    resizeViewport(to: desiredViewportSize)
  }

  /// Updates the appropriate in-memory cached geometry (based on the current window mode) using the current window & view frames.
  /// Param `updatePreferredSizeAlso` only applies to `.windowed` mode.
  func updateCachedGeometry(updatePreferredSizeAlso: Bool = true) {
    guard !currentLayout.isFullScreen, !player.info.isRestoring else {
      log.verbose("Not updating cached geometry: isFS=\(currentLayout.isFullScreen.yn), isRestoring=\(player.info.isRestoring)")
      return
    }
    log.verbose("Updating cached \(currentLayout.mode) geometry from current window")

    switch currentLayout.mode {
    case .windowed:
      windowedModeGeometry = buildWindowGeometryFromCurrentFrame(using: currentLayout)
      if updatePreferredSizeAlso {
        player.info.setIntendedViewportSize(from: windowedModeGeometry)
      }
      player.saveState()
    case .windowedInteractive:
      interactiveModeGeometry = InteractiveModeGeometry.from(buildWindowGeometryFromCurrentFrame(using: currentLayout))
    case .musicMode:
      musicModeGeometry = musicModeGeometry.clone(windowFrame: window!.frame, 
                                                  screenID: bestScreen.screenID)
      player.saveState()
    case .fullScreen, .fullScreenInteractive:
      break  // will never get here; see guard above
    }
  }

  // For windowed mode
  func buildWindowGeometryFromCurrentFrame(using layout: LayoutState) -> PlayerWindowGeometry {
    assert(layout.mode == .windowed || layout.mode == .windowedInteractive,
           "buildWindowGeometryFromCurrentFrame(): unexpected mode: \(layout.mode)")
    // TODO: find a better solution than just replicating this logic here
    let insideBottomBarHeight = (layout.bottomBarPlacement == .insideViewport && layout.enableOSC && layout.oscPosition == .bottom) ? OSCToolbarButton.oscBarHeight : 0
    let outsideBottomBarHeight = (layout.bottomBarPlacement == .outsideViewport && layout.enableOSC && layout.oscPosition == .bottom) ? OSCToolbarButton.oscBarHeight : 0

    let geo = PlayerWindowGeometry(windowFrame: window!.frame,
                                   screenID: bestScreen.screenID,
                                   fitOption: .keepInVisibleScreen,
                                   topMarginHeight: 0,  // is only nonzero when in legacy FS
                                   outsideTopBarHeight: layout.outsideTopBarHeight,
                                   outsideTrailingBarWidth: layout.outsideTrailingBarWidth,
                                   outsideBottomBarHeight: outsideBottomBarHeight,
                                   outsideLeadingBarWidth: layout.outsideLeadingBarWidth,
                                   insideTopBarHeight: layout.topBarPlacement == .insideViewport ? layout.topBarHeight : 0,
                                   insideTrailingBarWidth: layout.insideTrailingBarWidth,
                                   insideBottomBarHeight: insideBottomBarHeight,
                                   insideLeadingBarWidth: layout.insideLeadingBarWidth,
                                   videoAspectRatio: player.info.videoAspectRatio,
                                   videoSize: videoView.frame.size)
    return geo.scaleViewport()
  }

  /// Called from `windowWillResize()` if in `windowed` mode.
  func resizeWindow(to requestedSize: NSSize) -> PlayerWindowGeometry {
    assert(currentLayout.isWindowed, "Trying to resize in windowed mode but current mode is unexpected: \(currentLayout.mode)")
    let currentGeo: PlayerWindowGeometry
    switch currentLayout.spec.mode {
    case .windowed:
      currentGeo = windowedModeGeometry
    case .windowedInteractive:
      if let interactiveModeGeometry {
        currentGeo = interactiveModeGeometry.toPlayerWindowGeometry()
      } else {
        log.error("WindowWillResize: could not find interactiveModeGeometry; will substitute windowedModeGeometry")
        currentGeo = windowedModeGeometry
      }
      if requestedSize.width < InteractiveModeGeometry.minWindowWidth {
        log.verbose("WindowWillResize: requested width (\(requestedSize.width)) is less than min width for interactive mode (\(InteractiveModeGeometry.minWindowWidth)). Denying resize")
        return currentGeo
      }
    default:
      log.error("WindowWillResize: requested mode is invalid: \(currentLayout.spec.mode). Will fall back to windowedModeGeometry")
      return windowedModeGeometry
    }
    guard let window = window else { return currentGeo }

    if denyNextWindowResize {
      let currentFrame = window.frame
      log.verbose("WindowWillResize: denying this resize; will stay at \(currentFrame.size)")
      denyNextWindowResize = false
      return currentGeo.clone(windowFrame: currentFrame)
    }

    if player.info.isRestoring {
      guard let savedState = player.info.priorState else { return currentGeo.clone(windowFrame: window.frame) }

      if let savedLayoutSpec = savedState.layoutSpec {
        // If getting here, restore is in progress. Don't allow size changes, but don't worry
        // about whether the saved size is valid. It will be handled elsewhere.
        if savedLayoutSpec.mode == .musicMode, let savedMusicModeGeo = savedState.musicModeGeometry {
          log.verbose("WindowWillResize: denying request due to restore; returning saved musicMode size \(savedMusicModeGeo.windowFrame.size)")
          return savedMusicModeGeo.toPlayerWindowGeometry()
        } else if savedLayoutSpec.mode == .windowed, let savedWindowedModeGeo = savedState.windowedModeGeometry {
          log.verbose("WindowWillResize: denying request due to restore; returning saved windowedMode size \(savedWindowedModeGeo.windowFrame.size)")
          return savedWindowedModeGeo
        }
      }
      log.error("WindowWillResize: failed to restore window frame; returning existing: \(window.frame.size)")
      return currentGeo.clone(windowFrame: window.frame)
    }

    let outsideBarsSize = currentGeo.outsideBarsTotalSize

    if !window.inLiveResize && ((requestedSize.height < currentGeo.minVideoHeight + outsideBarsSize.height)
                                || (requestedSize.width < currentGeo.minVideoWidth + outsideBarsSize.width)) {
      // Sending the current size seems to work much better with accessibilty requests
      // than trying to change to the min size
      log.verbose("WindowWillResize: requested smaller than min \(AppData.minVideoSize); returning existing \(window.frame.size)")
      return currentGeo.clone(windowFrame: window.frame)
    }

    // Need to resize window to match video aspect ratio, while taking into account any outside panels.
    let lockViewportToVideoSize = Preference.bool(for: .lockViewportToVideoSize) || currentLayout.isInteractiveMode
    if !lockViewportToVideoSize {
      // No need to resize window to match video aspect ratio.
      let intendedGeo = currentGeo.scaleWindow(to: requestedSize, fitOption: .noConstraints)

      if currentLayout.mode == .windowed && window.inLiveResize {
        // User has resized the video. Assume this is the new preferred resolution until told otherwise. Do not constrain.
        player.info.setIntendedViewportSize(from: intendedGeo)
      }
      let requestedGeoConstrained = intendedGeo.refit(.keepInVisibleScreen)
      return requestedGeoConstrained
    }

    let outsideBarsTotalSize = currentGeo.outsideBarsTotalSize

    // Option A: resize height based on requested width
    let requestedVideoWidth = requestedSize.width - outsideBarsTotalSize.width
    let resizeFromWidthRequestedVideoSize = NSSize(width: requestedVideoWidth,
                                                   height: requestedVideoWidth / currentGeo.videoAspectRatio)
    let resizeFromWidthGeo = currentGeo.scaleVideo(to: resizeFromWidthRequestedVideoSize,
                                                   lockViewportToVideoSize: lockViewportToVideoSize)

    // Option B: resize width based on requested height
    let requestedVideoHeight = requestedSize.height - outsideBarsTotalSize.height
    let resizeFromHeightRequestedVideoSize = NSSize(width: requestedVideoHeight * currentGeo.videoAspectRatio,
                                                    height: requestedVideoHeight)
    let resizeFromHeightGeo = currentGeo.scaleVideo(to: resizeFromHeightRequestedVideoSize,
                                                    lockViewportToVideoSize: lockViewportToVideoSize)

    let chosenGeometry: PlayerWindowGeometry
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

      if currentLayout.mode == .windowed {
        // User has resized the video. Assume this is the new preferred resolution until told otherwise.
        player.info.setIntendedViewportSize(from: chosenGeometry)
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
    log.verbose("WindowWillResize isLive:\(window.inLiveResize.yn) req:\(requestedSize) returning:\(chosenGeometry.windowFrame.size)")
    return chosenGeometry
  }

  func updateFloatingOSCAfterWindowDidResize() {
    guard let window = window, currentLayout.oscPosition == .floating else { return }
    controlBarFloating.moveTo(centerRatioH: floatingOSCCenterRatioH,
                              originRatioV: floatingOSCOriginRatioV, layout: currentLayout, viewportSize: viewportView.frame.size)

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

  // MARK: - Apply Geometry

  /// Set the window frame and if needed the content view frame to appropriately use the full screen.
  /// For screens that contain a camera housing the content view will be adjusted to not use that area of the screen.
  func applyLegacyFullScreenGeometry(_ geometry: PlayerWindowGeometry) {
    guard let window = window else { return }
    let layout = currentLayout
    if !layout.isInteractiveMode {
      videoView.apply(geometry)
    }
    guard !geometry.windowFrame.equalTo(window.frame) else {
      log.verbose("No need to update windowFrame for legacyFullScreen - no change")
      return
    }

    if currentLayout.hasFloatingOSC {
      controlBarFloating.moveTo(centerRatioH: floatingOSCCenterRatioH, originRatioV: floatingOSCOriginRatioV,
                                layout: currentLayout, viewportSize: geometry.viewportSize)
    }

    log.verbose("Calling setFrame for legacyFullScreen, to \(geometry)")
    let topBarHeight = layout.topBarPlacement == .insideViewport ? geometry.insideTopBarHeight : geometry.outsideTopBarHeight
    updateTopBarHeight(to: topBarHeight, topBarPlacement: layout.topBarPlacement, cameraHousingOffset: geometry.topMarginHeight)
    player.window.setFrameImmediately(geometry.windowFrame)
  }

  /// Updates/redraws current `window.frame` and its internal views from `newGeometry`. Animated.
  /// Also updates cached `windowedModeGeometry` and saves updated state.
  func applyWindowGeometry(_ newGeometry: PlayerWindowGeometry) {
    log.verbose("ApplyWindowGeometry windowFrame: \(newGeometry.windowFrame), videoAspectRatio: \(newGeometry.videoAspectRatio)")
    // Update video aspect ratio always
    player.info.videoAspectRatio = newGeometry.videoAspectRatio

    var ticket: Int = 0
    $geoUpdateTicketCounter.withLock {
      $0 += 1
      ticket = $0
    }

    animationPipeline.submit(IINAAnimation.Task(duration: IINAAnimation.DefaultDuration, timing: .easeInEaseOut, { [self] in
      guard ticket == geoUpdateTicketCounter else {
        return
      }
      log.verbose("Applying geoUpdate \(ticket)")

      switch currentLayout.spec.mode {
      case .musicMode:
        log.error("ApplyWindowGeometry cannot be used in music mode!")
        return
      case .fullScreen:
        // Make sure video constraints are up to date, even in full screen. Also remember that FS & windowed mode share same screen.
        let fsGeo = currentLayout.buildFullScreenGeometry(inScreenID: newGeometry.screenID, 
                                                          videoAspectRatio: newGeometry.videoAspectRatio)
        videoView.apply(fsGeo)

      case .windowed:
        // Make sure this is up-to-date
        videoView.apply(newGeometry)

      case .windowedInteractive, .fullScreenInteractive:
        // VideoView size constraints not used
        break
      }

      if currentLayout.mode == .windowed && !isWindowHidden {
        player.window.setFrameImmediately(newGeometry.windowFrame)
      }

      // Update this, even if not currently in windowed mode
      windowedModeGeometry = newGeometry
      player.saveState()

      log.verbose("Calling updateWinParamsForMPV from apply() with videoSize: \(newGeometry.videoSize)")
      updateWindowParametersForMPV(withSize: newGeometry.videoSize)
    }))
  }

  // Not animated
  func applyWindowGeometryLivePreview(_ newGeometry: PlayerWindowGeometry) {
    log.verbose("applyWindowGeometryLivePreview: \(newGeometry)")
    videoView.videoLayer.enterAsynchronousMode()
    // Update video aspect ratio
    player.info.videoAspectRatio = newGeometry.videoAspectRatio

    IINAAnimation.disableAnimation{
      // Make sure this is up-to-date
      videoView.apply(newGeometry)

      if currentLayout.oscPosition == .floating {
        // Update floating control bar position
        controlBarFloating.moveTo(centerRatioH: floatingOSCCenterRatioH,
                                  originRatioV: floatingOSCOriginRatioV, layout: currentLayout, viewportSize: newGeometry.viewportSize)
      }
    }

    if !isFullScreen {
      player.window.setFrameImmediately(newGeometry.windowFrame, animate: false)
    }
  }

  /// Same as `applyMusicModeGeometry()`, but enqueues inside an `IINAAnimation.Task` for a nice smooth animation
  func applyMusicModeGeometryInAnimationTask(_ geometry: MusicModeGeometry, setFrame: Bool = true, animate: Bool = true, updateCache: Bool = true) {
    animationPipeline.submit(IINAAnimation.Task(timing: .easeInEaseOut, { [self] in
      applyMusicModeGeometry(geometry)
    }))
  }

  /// Updates the current window and its subviews to match the given `MusicModeGeometry`, and caches it.
  func applyMusicModeGeometry(_ geometry: MusicModeGeometry, setFrame: Bool = true, animate: Bool = true, updateCache: Bool = true) {
    let geometry = geometry.refit()  // enforces internal constraints, and constrains to screen
    log.verbose("Applying \(geometry), setFrame=\(setFrame.yn) updateCache=\(updateCache.yn)")
    // Update defaults:
    Preference.set(geometry.isVideoVisible, for: .musicModeShowAlbumArt)
    Preference.set(geometry.isPlaylistVisible, for: .musicModeShowPlaylist)

    player.info.videoAspectRatio = geometry.videoAspectRatio

    videoView.videoLayer.enterAsynchronousMode()
    miniPlayer.resetScrollingLabels()
    updateMusicModeButtonsVisibility()

    /// Try to detect & remove unnecessary constraint updates - `updateBottomBarHeight()` may cause animation glitches if called twice
    let hasVideoVisChange = geometry.isVideoVisible == (viewportViewHeightContraint?.isActive ?? false)
    var hasChange: Bool = !geometry.windowFrame.equalTo(window!.frame) || hasVideoVisChange
    if let newVideoSize = geometry.videoSize, let currentVideoSize = videoView.lastSetVideoSize,
       !newVideoSize.equalTo(currentVideoSize) {
      hasChange = true
    }
    if hasChange {
      /// Make sure to call `apply` AFTER `applyVideoViewVisibilityConstraints`:
      miniPlayer.applyVideoViewVisibilityConstraints(isVideoVisible: geometry.isVideoVisible)
      updateBottomBarHeight(to: geometry.bottomBarHeight, bottomBarPlacement: .outsideViewport)
      videoView.apply(geometry.toPlayerWindowGeometry())
      if setFrame {
        player.window.setFrameImmediately(geometry.windowFrame, animate: animate)
      } else {
        log.verbose("Not updating music mode windowFrame or constraints - no changes needed")
      }
    }
    if updateCache {
      musicModeGeometry = geometry
      player.saveState()

      /// For the case where video is hidden but playlist is shown, AppKit won't allow the window's height to be changed by the user
      /// unless we remove this constraint from the the window's `contentView`. For all other situations this constraint should be active.
      /// Need to execute this in its own task so that other animations are not affected.
      let shouldDisableConstraint = !geometry.isVideoVisible && geometry.isPlaylistVisible
      animationPipeline.submitZeroDuration({ [self] in
        viewportBottomOffsetFromContentViewBottomConstraint.isActive = !shouldDisableConstraint
      })
    }
  }

}
