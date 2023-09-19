//
//  PlayerWindowLayout.swift
//  iina
//
//  Created by Matt Svoboda on 8/20/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/// Size of a side the 3 square playback button icons (Play/Pause, LeftArrow, RightArrow):
fileprivate var oscBarPlaybackIconSize: CGFloat {
  CGFloat(Preference.integer(for: .oscBarPlaybackIconSize)).clamped(to: 8...OSCToolbarButton.oscBarHeight)
}
/// Scale of spacing to the left & right of each playback button (for top/bottom OSC):
fileprivate var oscBarPlaybackIconSpacing: CGFloat {
  max(0, CGFloat(Preference.integer(for: .oscBarPlaybackIconSpacing)))
}

fileprivate let oscFloatingPlayBtnsSize: CGFloat = 24
fileprivate let oscFloatingPlayBtnsHPad: CGFloat = 8
fileprivate let oscFloatingToolbarButtonIconSize: CGFloat = 14
fileprivate let oscFloatingToolbarButtonIconPadding: CGFloat = 5

// TODO: reimplement OSC title bar feature
fileprivate let oscTitleBarPlayBtnsSize: CGFloat = 18
fileprivate let oscTitleBarPlayBtnsHPad: CGFloat = 6
fileprivate let oscTitleBarToolbarButtonIconSize: CGFloat = 14
fileprivate let oscTitleBarToolbarButtonIconPadding: CGFloat = 5

fileprivate extension NSStackView.VisibilityPriority {
  static let detachEarly = NSStackView.VisibilityPriority(rawValue: 950)
  static let detachEarlier = NSStackView.VisibilityPriority(rawValue: 900)
}

extension PlayerWindowController {

  enum WindowMode: Int {
    case windowed = 1
    case fullScreen
//    case pip
    case musicMode
//    case interactiveWindow
//    case interactiveFullScreen
  }

  /// `struct LayoutSpec`: data structure which is the blueprint for building a `LayoutState`
  struct LayoutSpec {
    let leadingSidebar: Sidebar
    let trailingSidebar: Sidebar

    let mode: WindowMode
    let isLegacyStyle: Bool

    let topBarPlacement: Preference.PanelPlacement
    let bottomBarPlacement: Preference.PanelPlacement
    var leadingSidebarPlacement: Preference.PanelPlacement { return leadingSidebar.placement }
    var trailingSidebarPlacement: Preference.PanelPlacement { return trailingSidebar.placement }

    let enableOSC: Bool
    let oscPosition: Preference.OSCPosition

    init(leadingSidebar: Sidebar, trailingSidebar: Sidebar, mode: WindowMode, isLegacyStyle: Bool,
         topBarPlacement: Preference.PanelPlacement, bottomBarPlacement: Preference.PanelPlacement,
         enableOSC: Bool,
         oscPosition: Preference.OSCPosition) {
      self.mode = mode
      self.isLegacyStyle = isLegacyStyle
      if mode == .musicMode {
        // Override most properties for music mode
        self.leadingSidebar = leadingSidebar.clone(visibility: .hide)
        self.trailingSidebar = trailingSidebar.clone(visibility: .hide)
        self.topBarPlacement = .insideVideo
        self.bottomBarPlacement = .outsideVideo
        self.enableOSC = false
      } else {
        self.leadingSidebar = leadingSidebar
        self.trailingSidebar = trailingSidebar
        self.topBarPlacement = topBarPlacement
        self.bottomBarPlacement = bottomBarPlacement
        self.enableOSC = enableOSC
      }
      self.oscPosition = oscPosition
    }

    /// Factory method. Matches what is shown in the XIB
    static func defaultLayout() -> LayoutSpec {
      let leadingSidebar = Sidebar(.leadingSidebar, tabGroups: Sidebar.TabGroup.fromPrefs(for: .leadingSidebar),
                                   placement: Preference.enum(for: .leadingSidebarPlacement),
                                   visibility: .hide)
      let trailingSidebar = Sidebar(.trailingSidebar, tabGroups: Sidebar.TabGroup.fromPrefs(for: .trailingSidebar),
                                    placement: Preference.enum(for: .trailingSidebarPlacement),
                                    visibility: .hide)
      return LayoutSpec(leadingSidebar: leadingSidebar,
                        trailingSidebar: trailingSidebar,
                        mode: .windowed,
                        isLegacyStyle: false,
                        topBarPlacement:.insideVideo,
                        bottomBarPlacement: .insideVideo,
                        enableOSC: false,
                        oscPosition: .floating)
    }

    /// Factory method. Init from preferences (and fill in remainder from given `LayoutSpec`)
    static func fromPreferences(andSpec prevSpec: LayoutSpec) -> LayoutSpec {
      // If in fullscreen, top & bottom bars are always .insideVideo

      let leadingSidebar = prevSpec.leadingSidebar.clone(tabGroups: Sidebar.TabGroup.fromPrefs(for: .leadingSidebar),
                                                         placement: Preference.enum(for: .leadingSidebarPlacement))
      let trailingSidebar = prevSpec.trailingSidebar.clone(tabGroups: Sidebar.TabGroup.fromPrefs(for: .trailingSidebar),
                                                           placement: Preference.enum(for: .trailingSidebarPlacement))
      let isLegacyStyle = prevSpec.mode == .fullScreen ? Preference.bool(for: .useLegacyFullScreen) : Preference.bool(for: .useLegacyWindowedMode)
      return LayoutSpec(leadingSidebar: leadingSidebar, trailingSidebar: trailingSidebar,
                        mode: prevSpec.mode,
                        isLegacyStyle: isLegacyStyle,
                        topBarPlacement: Preference.enum(for: .topBarPlacement),
                        bottomBarPlacement: Preference.enum(for: .bottomBarPlacement),
                        enableOSC: Preference.bool(for: .enableOSC),
                        oscPosition: Preference.enum(for: .oscPosition))
    }

    // Specify any properties to override; if nil, will use self's property values.
    func clone(leadingSidebar: Sidebar? = nil,
               trailingSidebar: Sidebar? = nil,
               mode: WindowMode? = nil,
               topBarPlacement: Preference.PanelPlacement? = nil,
               bottomBarPlacement: Preference.PanelPlacement? = nil,
               enableOSC: Bool? = nil,
               oscPosition: Preference.OSCPosition? = nil,
               isLegacyStyle: Bool? = nil) -> LayoutSpec {
      return LayoutSpec(leadingSidebar: leadingSidebar ?? self.leadingSidebar,
                        trailingSidebar: trailingSidebar ?? self.trailingSidebar,
                        mode: mode ?? self.mode,
                        isLegacyStyle: isLegacyStyle ?? self.isLegacyStyle,
                        topBarPlacement: topBarPlacement ?? self.topBarPlacement,
                        bottomBarPlacement: bottomBarPlacement ?? self.bottomBarPlacement,
                        enableOSC: enableOSC ?? self.enableOSC,
                        oscPosition: self.oscPosition)
    }

    var isFullScreen: Bool {
      return mode == .fullScreen
    }

    var isNativeFullScreen: Bool {
      return mode == .fullScreen && !isLegacyStyle
    }

    var isLegacyFullScreen: Bool {
      return mode == .fullScreen && isLegacyStyle
    }

    /// Returns `true` if `otherSpec` has the same values which are configured from IINA app-wide prefs
    func hasSamePrefsValues(as otherSpec: LayoutSpec) -> Bool {
      return otherSpec.enableOSC == enableOSC
      && otherSpec.oscPosition == oscPosition
      && otherSpec.isLegacyStyle == isLegacyStyle
      && otherSpec.topBarPlacement == topBarPlacement
      && otherSpec.bottomBarPlacement == bottomBarPlacement
      && otherSpec.leadingSidebarPlacement == leadingSidebarPlacement
      && otherSpec.trailingSidebarPlacement == trailingSidebarPlacement
      && otherSpec.leadingSidebar.tabGroups == leadingSidebar.tabGroups
      && otherSpec.trailingSidebar.tabGroups == trailingSidebar.tabGroups
    }

    func getExcessSpaceBetweenInsideSidebars(leadingSidebarWidth: CGFloat? = nil, trailingSidebarWidth: CGFloat? = nil, in videoContainerWidth: CGFloat) -> CGFloat {
      let lead = leadingSidebarWidth ?? leadingSidebar.insideWidth
      let trail = trailingSidebarWidth ?? trailingSidebar.insideWidth
      return videoContainerWidth - (lead + trail + Constants.Sidebar.minSpaceBetweenInsideSidebars)
    }

    /// Returns `(shouldCloseLeadingSidebar, shouldCloseTrailingSidebar)`, indicating which sidebars should be hidden
    /// due to lack of space in the videoContainer.
    func isHideSidebarNeeded(in videoContainerWidth: CGFloat) -> (Bool, Bool) {
      var leadingSidebarSpace = leadingSidebar.insideWidth
      var trailingSidebarSpace = trailingSidebar.insideWidth
      var vidConSpace = videoContainerWidth

      var shouldCloseLeadingSidebar = false
      var shouldCloseTrailingSidebar = false
      if leadingSidebarSpace + trailingSidebarSpace > 0 {
        while getExcessSpaceBetweenInsideSidebars(leadingSidebarWidth: leadingSidebarSpace, trailingSidebarWidth: trailingSidebarSpace, in: vidConSpace) < 0 {
          if leadingSidebarSpace > 0 && leadingSidebarSpace >= trailingSidebarSpace {
            shouldCloseLeadingSidebar = true
            leadingSidebarSpace = 0
            vidConSpace -= leadingSidebarSpace
          } else if trailingSidebarSpace > 0 && trailingSidebarSpace >= leadingSidebarSpace {
            shouldCloseTrailingSidebar = true
            trailingSidebarSpace = 0
            vidConSpace -= trailingSidebarSpace
          } else {
            break
          }
        }
      }
      return (shouldCloseLeadingSidebar, shouldCloseTrailingSidebar)
    }
  }

  /// `LayoutState`: data structure which contains all the variables which describe a single layout configuration of the `PlayerWindow`.
  /// ("Layout" might have been a better name for this class, but it's already used by AppKit). Notes:
  /// • With all the different window layout configurations which are now possible, it's crucial to use this class in order for animations
  ///   to work reliably.
  /// • It should be treated like a read-only object after it's built. Its member variables are only mutable to make it easier to build.
  /// • When any member variable inside it needs to be changed, a new `LayoutState` object should be constructed to describe the new state,
  ///   and a `LayoutTransition` should be built to describe the animations needs to go from old to new.
  /// • The new `LayoutState`, once active, should be stored in the `currentLayout` of `PlayerWindowController` for future reference.
  class LayoutState {
    init(spec: LayoutSpec) {
      self.spec = spec
    }

    // All other variables in this class are derived from this spec:
    let spec: LayoutSpec

    // Visibility of views/categories

    var titleBar: Visibility = .hidden
    var titleIconAndText: Visibility = .hidden
    var trafficLightButtons: Visibility = .hidden
    var titlebarAccessoryViewControllers: Visibility = .hidden
    var leadingSidebarToggleButton: Visibility = .hidden
    var trailingSidebarToggleButton: Visibility = .hidden
    var pinToTopButton: Visibility = .hidden

    var controlBarFloating: Visibility = .hidden

    var bottomBarView: Visibility = .hidden
    var topBarView: Visibility = .hidden

    // Sizes / offsets

    var cameraHousingOffset: CGFloat = 0

    /// This exists as a fallback for the case where the title bar has a transparent background but still shows its items.
    /// For most cases, spacing between OSD and top of `videoContainerView` >= 8pts
    var osdMinOffsetFromTop: CGFloat = 0

    var sidebarDownshift: CGFloat = Constants.Sidebar.defaultDownshift
    var sidebarTabHeight: CGFloat = Constants.Sidebar.defaultTabHeight

    var titleBarHeight: CGFloat = 0
    var topOSCHeight: CGFloat = 0

    var topBarHeight: CGFloat {
      self.titleBarHeight + self.topOSCHeight
    }

    /// NOTE: Is mutable!
    var trailingBarWidth: CGFloat {
      return spec.trailingSidebar.currentWidth
    }

    /// NOTE: Is mutable!
    var leadingBarWidth: CGFloat {
      return spec.leadingSidebar.currentWidth
    }

    /// Bar widths/heights IF `outsideVideo`

    var topBarOutsideHeight: CGFloat {
      return topBarPlacement == .outsideVideo ? topBarHeight : 0
    }

    /// NOTE: Is mutable!
    var trailingBarOutsideWidth: CGFloat {
      return spec.trailingSidebar.outsideWidth
    }

    /// NOTE: Is mutable!
    var leadingBarOutsideWidth: CGFloat {
      return spec.leadingSidebar.outsideWidth
    }

    /// Bar widths/heights IF `insideVideo`

    /// NOTE: Is mutable!
    var leadingBarInsideWidth: CGFloat {
      return spec.leadingSidebar.insideWidth
    }

    /// NOTE: Is mutable!
    var trailingBarInsideWidth: CGFloat {
      return spec.trailingSidebar.insideWidth
    }

    // Derived properties & convenience accessors

    var isFullScreen: Bool {
      return spec.mode == .fullScreen
    }

    var canToggleFullScreen: Bool {
      return spec.mode == .fullScreen || spec.mode == .windowed
    }

    var isLegacyFullScreen: Bool {
      return isFullScreen && spec.isLegacyStyle
    }

    var isMusicMode: Bool {
      return spec.mode == .musicMode
    }

    var enableOSC: Bool {
      return spec.enableOSC
    }

    var oscPosition: Preference.OSCPosition {
      return spec.oscPosition
    }

    var topBarPlacement: Preference.PanelPlacement {
      return spec.topBarPlacement
    }

    var bottomBarPlacement: Preference.PanelPlacement {
      return spec.bottomBarPlacement
    }

    var leadingSidebarPlacement: Preference.PanelPlacement {
      return spec.leadingSidebarPlacement
    }

    var trailingSidebarPlacement: Preference.PanelPlacement {
      return spec.trailingSidebarPlacement
    }

    var leadingSidebar: Sidebar {
      return spec.leadingSidebar
    }

    var trailingSidebar: Sidebar {
      return spec.trailingSidebar
    }

    var canShowSidebars: Bool {
      return spec.mode == .windowed || spec.mode == .fullScreen
    }

    var hasFloatingOSC: Bool {
      return enableOSC && oscPosition == .floating
    }

    var hasTopOSC: Bool {
      return enableOSC && oscPosition == .top
    }

    var hasPermanentOSC: Bool {
      return enableOSC && ((oscPosition == .top && topBarPlacement == .outsideVideo) ||
                           (oscPosition == .bottom && bottomBarPlacement == .outsideVideo))
    }

    func sidebar(withID id: Preference.SidebarLocation) -> Sidebar {
      switch id {
      case .leadingSidebar:
        return leadingSidebar
      case .trailingSidebar:
        return trailingSidebar
      }
    }

    func computePinToTopButtonVisibility(isOnTop: Bool) -> Visibility {
      let showOnTopStatus = Preference.bool(for: .alwaysShowOnTopIcon) || isOnTop
      if isFullScreen || !showOnTopStatus {
        return .hidden
      }

      if topBarPlacement == .insideVideo {
        return .showFadeableNonTopBar
      }

      return .showAlways
    }
  }  // end class LayoutState

  // MARK: - Visibility States

  enum Visibility {
    case hidden
    case showAlways
    case showFadeableTopBar     // fade in as part of the top bar
    case showFadeableNonTopBar  // fade in as a fadeable view which is not top bar

    var isShowable: Bool {
      return self != .hidden
    }
  }

  private func apply(visibility: Visibility, to view: NSView) {
    switch visibility {
    case .hidden:
      view.alphaValue = 0
      view.isHidden = true
      fadeableViews.remove(view)
      fadeableViewsTopBar.remove(view)
    case .showAlways:
      view.alphaValue = 1
      view.isHidden = false
      fadeableViews.remove(view)
      fadeableViewsTopBar.remove(view)
    case .showFadeableTopBar:
      view.alphaValue = 1
      view.isHidden = false
      fadeableViewsTopBar.insert(view)
    case .showFadeableNonTopBar:
      view.alphaValue = 1
      view.isHidden = false
      fadeableViews.insert(view)
    }
  }

  private func apply(visibility: Visibility, _ views: NSView?...) {
    for view in views {
      if let view = view {
        apply(visibility: visibility, to: view)
      }
    }
  }

  private func applyHiddenOnly(visibility: Visibility, to view: NSView, isTopBar: Bool = true) {
    guard visibility == .hidden else { return }
    apply(visibility: visibility, view)
  }

  private func applyShowableOnly(visibility: Visibility, to view: NSView, isTopBar: Bool = true) {
    guard visibility != .hidden else { return }
    apply(visibility: visibility, view)
  }

  // MARK: - Layout Transitions

  class LayoutTransition {
    let name: String  // just used for debugging
    let fromLayout: LayoutState
    let toLayout: LayoutState
    let fromWindowGeometry: PlayerWindowGeometry
    let toWindowGeometry: PlayerWindowGeometry

    let isInitialLayout: Bool

    var animationTasks: [CocoaAnimation.Task] = []

    init(name: String, from fromLayout: LayoutState, from fromGeometry: PlayerWindowGeometry,
         to toLayout: LayoutState, to toGeometry: PlayerWindowGeometry,
         isInitialLayout: Bool = false) {
      self.name = name
      self.fromLayout = fromLayout
      self.fromWindowGeometry = fromGeometry
      self.toLayout = toLayout
      self.toWindowGeometry = toGeometry
      self.isInitialLayout = isInitialLayout
    }

    var isOSCChanging: Bool {
      return (fromLayout.enableOSC != toLayout.enableOSC) || (fromLayout.oscPosition != toLayout.oscPosition)
    }

    var needsFadeOutOldViews: Bool {
      return isTogglingLegacyWindowStyle || isTopBarPlacementChanging
      || (fromLayout.spec.mode != toLayout.spec.mode)
      || (fromLayout.bottomBarPlacement == .insideVideo && toLayout.bottomBarPlacement == .outsideVideo)
      || (fromLayout.enableOSC != toLayout.enableOSC)
      || (fromLayout.enableOSC && (fromLayout.oscPosition != toLayout.oscPosition))
      || (fromLayout.leadingSidebarToggleButton.isShowable && !toLayout.leadingSidebarToggleButton.isShowable)
      || (fromLayout.trailingSidebarToggleButton.isShowable && !toLayout.trailingSidebarToggleButton.isShowable)
      || (fromLayout.pinToTopButton.isShowable && !toLayout.pinToTopButton.isShowable)
    }

    var needsFadeInNewViews: Bool {
      return isTogglingLegacyWindowStyle || isTopBarPlacementChanging
      || (fromLayout.spec.mode != toLayout.spec.mode)
      || (fromLayout.bottomBarPlacement == .outsideVideo && toLayout.bottomBarPlacement == .insideVideo)
      || (fromLayout.enableOSC != toLayout.enableOSC)
      || (toLayout.enableOSC && (fromLayout.oscPosition != toLayout.oscPosition))
      || (!fromLayout.leadingSidebarToggleButton.isShowable && toLayout.leadingSidebarToggleButton.isShowable)
      || (!fromLayout.trailingSidebarToggleButton.isShowable && toLayout.trailingSidebarToggleButton.isShowable)
      || (!fromLayout.pinToTopButton.isShowable && toLayout.pinToTopButton.isShowable)
    }

    var needsCloseOldPanels: Bool {
      if isEnteringFullScreen {
        // Avoid bounciness and possible unwanted video scaling animation (not needed for ->FS anyway)
        return false
      }
      return isHidingLeadingSidebar || isHidingTrailingSidebar || isTopBarPlacementChanging || isBottomBarPlacementChanging
      || (fromLayout.spec.isLegacyStyle != toLayout.spec.isLegacyStyle)
      || (fromLayout.spec.mode != toLayout.spec.mode)
      || (fromLayout.enableOSC != toLayout.enableOSC)
      || (fromLayout.enableOSC && (fromLayout.oscPosition != toLayout.oscPosition))
    }

    var isTogglingLegacyWindowStyle: Bool {
      return fromLayout.spec.isLegacyStyle != toLayout.spec.isLegacyStyle
    }

    var isTogglingFullScreen: Bool {
      return fromLayout.isFullScreen != toLayout.isFullScreen
    }

    var isEnteringFullScreen: Bool {
      return !fromLayout.isFullScreen && toLayout.isFullScreen
    }

    var isExitingFullScreen: Bool {
      return fromLayout.isFullScreen && !toLayout.isFullScreen
    }

    var isEnteringMusicMode: Bool {
      return !fromLayout.isMusicMode && toLayout.isMusicMode
    }

    var isExitingMusicMode: Bool {
      return fromLayout.isMusicMode && !toLayout.isMusicMode
    }

    var isTogglingMusicMode: Bool {
      return fromLayout.isMusicMode != toLayout.isMusicMode
    }

    var isTopBarPlacementChanging: Bool {
      return fromLayout.topBarPlacement != toLayout.topBarPlacement
    }

    var isBottomBarPlacementChanging: Bool {
      return fromLayout.bottomBarPlacement != toLayout.bottomBarPlacement
    }

    var isLeadingSidebarPlacementChanging: Bool {
      return fromLayout.leadingSidebarPlacement != toLayout.leadingSidebarPlacement
    }

    var isTrailingSidebarPlacementChanging: Bool {
      return fromLayout.trailingSidebarPlacement != toLayout.trailingSidebarPlacement
    }

    lazy var isShowingLeadingSidebar: Bool = {
      return isShowing(.leadingSidebar)
    }()

    lazy var isShowingTrailingSidebar: Bool = {
      return isShowing(.trailingSidebar)
    }()

    lazy var isHidingLeadingSidebar: Bool = {
      return isHiding(.leadingSidebar)
    }()

    lazy var isHidingTrailingSidebar: Bool = {
      return isHiding(.trailingSidebar)
    }()

    lazy var isTogglingVisibilityOfAnySidebar: Bool = {
      return isShowingLeadingSidebar || isShowingTrailingSidebar || isHidingLeadingSidebar || isHidingTrailingSidebar
    }()

    /// Is opening given sidebar?
    func isShowing(_ sidebarID: Preference.SidebarLocation) -> Bool {
      let oldState = fromLayout.sidebar(withID: sidebarID)
      let newState = toLayout.sidebar(withID: sidebarID)
      if !oldState.isVisible && newState.isVisible {
        return true
      }
      return isHidingAndThenShowing(sidebarID)
    }

    /// Is closing given sidebar?
    func isHiding(_ sidebarID: Preference.SidebarLocation) -> Bool {
      let oldState = fromLayout.sidebar(withID: sidebarID)
      let newState = toLayout.sidebar(withID: sidebarID)
      if oldState.isVisible {
        if !newState.isVisible {
          return true
        }
        if let oldVisibleTabGroup = oldState.visibleTabGroup, let newVisibleTabGroup = newState.visibleTabGroup,
           oldVisibleTabGroup != newVisibleTabGroup {
          return true
        }
        if let visibleTabGroup = oldState.visibleTabGroup, !newState.tabGroups.contains(visibleTabGroup) {
          Logger.log("isHiding(sidebarID:): visibleTabGroup \(visibleTabGroup.rawValue.quoted) is not present in newState!", level: .error)
          return true
        }
      }
      return isHidingAndThenShowing(sidebarID)
    }

    func isHidingAndThenShowing(_ sidebarID: Preference.SidebarLocation) -> Bool {
      let oldState = fromLayout.sidebar(withID: sidebarID)
      let newState = toLayout.sidebar(withID: sidebarID)
      if oldState.isVisible && newState.isVisible {
        if oldState.placement != newState.placement {
          return true
        }
        guard let oldGroup = oldState.visibleTabGroup, let newGroup = newState.visibleTabGroup else {
          Logger.log("needToCloseAndReopen(sidebarID:): visibleTabGroup missing!", level: .error)
          return false
        }
        if oldGroup != newGroup {
          return true
        }
      }
      return false
    }
  }

  func setInitialWindowLayout() {
    var needsNativeFullScreen: Bool = false
    let initialLayoutSpec: LayoutSpec
    var initialGeometry: PlayerWindowGeometry? = nil
    let isRestoringFromPrevLaunch: Bool

    if let priorState = player.info.priorState, let priorLayoutSpec = priorState.layoutSpec {
      isRestoringFromPrevLaunch = true
      log.verbose("Transitioning to initial layout from prior window state")

      // Restore saved geometries
      if let priorWindowedModeGeometry = priorState.windowedModeGeometry {
        log.debug("Restoring windowedMode windowFrame to \(priorWindowedModeGeometry.windowFrame), videoAspectRatio: \(priorWindowedModeGeometry.videoAspectRatio)")
        player.videoView.updateAspectRatio(to: priorWindowedModeGeometry.videoAspectRatio)
        windowedModeGeometry = priorWindowedModeGeometry
      } else {
        log.error("Failed to get player window geometry from prefs")
      }

      if let priorMusicModeGeometry = priorState.musicModeGeometry {
        log.debug("Restoring music mode windowFrame to \(priorMusicModeGeometry.windowFrame), video=\(priorMusicModeGeometry.isVideoVisible.yn) playlist=\(priorMusicModeGeometry.isPlaylistVisible.yn)")
        musicModeGeometry = priorMusicModeGeometry
      } else {
        log.error("Failed to get player window layout and/or geometry from prefs")
      }

      if priorLayoutSpec.mode == .musicMode {
        player.overrideAutoMusicMode = true
      }

      if priorLayoutSpec.isNativeFullScreen && !currentLayout.isFullScreen {
        // Special handling for native fullscreen. Cannot avoid animation.
        // So instead restore windowed layout first, then toggle fullscreen explicitly
        initialLayoutSpec = priorLayoutSpec.clone(mode: .windowed)
        needsNativeFullScreen = true
      } else {
        initialLayoutSpec = priorLayoutSpec
      }

      // Restore window size & position
      switch initialLayoutSpec.mode {
      case .fullScreen, .windowed:
        initialGeometry = windowedModeGeometry
      case .musicMode:
        /// `musicModeGeometry` should have already been deserialized and set.
        /// But make sure we correct any size problems
        initialGeometry = musicModeGeometry.constrainWithin(bestScreen.visibleFrame).toPlayerWindowGeometry()
      }

    } else {
      isRestoringFromPrevLaunch = false
      log.verbose("Transitioning to initial layout from app prefs")
      initialLayoutSpec = LayoutSpec.fromPreferences(andSpec: currentLayout.spec)
    }

    let initialLayout = buildFutureLayoutState(from: initialLayoutSpec)

    if initialGeometry == nil {
      log.verbose("Building initial geometry from current window")
      switch initialLayoutSpec.mode {
      case .fullScreen, .windowed:
        initialGeometry = buildWindowGeometryFromCurrentFrame(using: initialLayout)
      case .musicMode:
        initialGeometry = musicModeGeometry.clone(windowFrame: window!.frame).toPlayerWindowGeometry()
      }
    }

    let name = "\(isRestoringFromPrevLaunch ? "Restore" : "Set")InitialLayout"
    let transition = LayoutTransition(name: name, from: currentLayout, from: initialGeometry!, to: initialLayout, to: initialGeometry!, isInitialLayout: true)

    // For initial layout (when window is first shown), to reduce jitteriness when drawing,
    // do all the layout in a single animation block
    CocoaAnimation.disableAnimation{
      controlBarFloating.isDragging = false
      doPreTransitionWork(transition)
      fadeOutOldViews(transition)
      closeOldPanels(transition)
      updateHiddenViewsAndConstraints(transition)
      openNewPanelsAndFinalizeOffsets(transition)
      fadeInNewViews(transition)
      doPostTransitionWork(transition)
      log.verbose("Setting window frame for initial layout to: \(initialGeometry!.windowFrame)")
      log.verbose("Done with transition to initial layout")
    }

    animationQueue.run(CocoaAnimation.Task({ [self] in
      player.window.setFrameImmediately(initialGeometry!.windowFrame)
    }))

    if Preference.bool(for: .alwaysFloatOnTop) {
      log.verbose("Setting window to OnTop per app preference")
      setWindowFloatingOnTop(true)
    }

    guard isRestoringFromPrevLaunch else { return }

    /// Stored window state may not be consistent with global IINA prefs.
    /// To check this, build another `LayoutSpec` from the global prefs, then compare it to the player's.
    let prefsSpec = LayoutSpec.fromPreferences(andSpec: initialLayoutSpec)
    let isConsistentWithPrefValues = initialLayoutSpec.hasSamePrefsValues(as: prefsSpec)
    if isConsistentWithPrefValues {
      log.verbose("Saved layout is consistent with IINA global prefs")

      if needsNativeFullScreen {
        log.verbose("Transitioning to native fullscreen from initial state")
        window?.toggleFullScreen(self)
      }
    } else {
      // Not consistent. But we already have the correct spec, so just build a layout from it and transition to correct layout
      log.debug("Player's saved layout does not match IINA app prefs. Will build and apply a corrected layout")
      let fixerTransition = buildLayoutTransition(named: "FixInvalidInitialLayout", from: initialLayout, to: prefsSpec)
      var tasks = fixerTransition.animationTasks
      if needsNativeFullScreen {
        tasks.append(CocoaAnimation.zeroDurationTask { [self] in
          log.verbose("Transitioning to native fullscreen from corrected initial state")
          window?.toggleFullScreen(self)
        })
      }
      animationQueue.run(tasks)
    }
  }

  /// First builds a new `LayoutState` based on the given `LayoutSpec`, then builds & returns a `LayoutTransition`,
  /// which contains all the information needed to animate the UI changes from the current `LayoutState` to the new one.
  @discardableResult
  func buildLayoutTransition(named transitionName: String,
                             from fromLayout: LayoutState,
                             to requestedSpec: LayoutSpec,
                             totalStartingDuration: CGFloat? = nil,
                             totalEndingDuration: CGFloat? = nil,
                             thenRun: Bool = false) -> LayoutTransition {

    let toLayout = buildFutureLayoutState(from: requestedSpec)

    let fromGeometry: PlayerWindowGeometry
    if fromLayout.isMusicMode {
      fromGeometry = musicModeGeometry.toPlayerWindowGeometry()
    } else {
      fromGeometry = windowedModeGeometry
    }

    // Geometry
    // FIXME: need to finish pulling out all geometry logic from transition code and put here
    let toGeometry: PlayerWindowGeometry

    if toLayout.isMusicMode {
      /// `videoAspectRatio` may have gone stale while not in music mode. Update it (playlist height will be recalculated if needed):
      let musicModeGeometryAspectCorrected = musicModeGeometry.clone(videoAspectRatio: videoView.aspectRatio)
      toGeometry = musicModeGeometryAspectCorrected.toPlayerWindowGeometry()

    } else if toLayout.isFullScreen {
      // This will be ignored anyway, so just save the processing cycles
      toGeometry = windowedModeGeometry
    } else {
      let bottomBarHeight: CGFloat
      if requestedSpec.enableOSC && requestedSpec.oscPosition == .bottom {
        bottomBarHeight = OSCToolbarButton.oscBarHeight
      } else {
        bottomBarHeight = 0
      }
      let outsideBottomBarHeight = toLayout.bottomBarPlacement == .outsideVideo ? bottomBarHeight : 0

      /// `windowedModeGeometry` may have gone stale or needs to be overridden. Update to match `toLayout`:
      let geo = windowedModeGeometry.clone(insideTopBarHeight: toLayout.topBarPlacement == .insideVideo ? toLayout.topBarHeight : 0,
                                           insideTrailingBarWidth: toLayout.trailingBarInsideWidth,
                                           insideBottomBarHeight: toLayout.bottomBarPlacement == .insideVideo ? bottomBarHeight : 0,
                                           insideLeadingBarWidth: toLayout.leadingBarInsideWidth,
                                           videoAspectRatio: fromGeometry.videoAspectRatio)
      // Need to recalculate windowFrame for outside bars:
      toGeometry = geo.resizeOutsideBars(newOutsideTopHeight: toLayout.topBarOutsideHeight,
                                         newOutsideTrailingWidth: toLayout.trailingBarOutsideWidth,
                                         newOutsideBottomBarHeight: outsideBottomBarHeight,
                                         newOutsideLeadingWidth: toLayout.leadingBarOutsideWidth)
    }

    let transition = LayoutTransition(name: transitionName, from: fromLayout, from: fromGeometry, to: toLayout, to: toGeometry, isInitialLayout: false)

    let startingAnimationDuration: CGFloat
    if transition.isTogglingFullScreen {
      startingAnimationDuration = 0
    } else if let totalStartingDuration = totalStartingDuration {
      startingAnimationDuration = totalStartingDuration / 3
    } else {
      startingAnimationDuration = CocoaAnimation.DefaultDuration
    }
    var showFadeableViewsDuration: CGFloat = startingAnimationDuration
    var fadeOutOldViewsDuration: CGFloat = startingAnimationDuration
    var closeOldPanelsDuration: CGFloat = startingAnimationDuration
    if transition.isEnteringMusicMode {
      showFadeableViewsDuration *= 0.3
      fadeOutOldViewsDuration *= 0.3
      closeOldPanelsDuration *= 0.3
    } else if transition.isExitingMusicMode {
      showFadeableViewsDuration = 0
      fadeOutOldViewsDuration = 0
    }

    let endingAnimationDuration: CGFloat = totalEndingDuration ?? CocoaAnimation.DefaultDuration

    let panelTimingName: CAMediaTimingFunctionName?
    if transition.isTogglingFullScreen {
      panelTimingName = nil
    } else if transition.isTogglingVisibilityOfAnySidebar {
      panelTimingName = .easeIn
    } else {
      panelTimingName = .linear
    }

    log.verbose("Building layout transition \(transition.name.quoted). EachStartDuration: \(startingAnimationDuration), EachEndDuration: \(endingAnimationDuration)")

    // Starting animations:

    // 0: Set initial var or other tasks which happen before main animations
    transition.animationTasks.append(CocoaAnimation.zeroDurationTask{ [self] in
      doPreTransitionWork(transition)
    })

    // StartingAnimation 1: Show fadeable views from current layout
    for fadeAnimation in buildAnimationToShowFadeableViews(restartFadeTimer: false, duration: showFadeableViewsDuration, forceShowTopBar: true) {
      transition.animationTasks.append(fadeAnimation)
    }

    // StartingAnimation 2: Fade out views which no longer will be shown but aren't enclosed in a panel.
    if transition.needsFadeOutOldViews {
      transition.animationTasks.append(CocoaAnimation.Task(duration: fadeOutOldViewsDuration, { [self] in
        fadeOutOldViews(transition)
      }))
    }

    // StartingAnimation 3: Close/Minimize panels which are no longer needed.
    if transition.needsCloseOldPanels {
      transition.animationTasks.append(CocoaAnimation.Task(duration: closeOldPanelsDuration, timing: panelTimingName, { [self] in
        closeOldPanels(transition)
      }))
    }

    // 0: Middle point: update style & constraints. Should have minimal visual changes
    transition.animationTasks.append(CocoaAnimation.zeroDurationTask{ [self] in
      // This also can change window styleMask
      updateHiddenViewsAndConstraints(transition)
    })

    // Extra task when toggling music mode: move & resize window
    if transition.isTogglingMusicMode {
      transition.animationTasks.append(CocoaAnimation.Task(duration: CocoaAnimation.DefaultDuration, timing: .easeInEaseOut, { [self] in
        player.window.setFrameImmediately(transition.toWindowGeometry.videoContainerFrameInScreenCoords)
      }))
    }

    // Ending animations:

    // EndingAnimation: Open new panels and fade in new views
    transition.animationTasks.append(CocoaAnimation.Task(duration: endingAnimationDuration, timing: panelTimingName, { [self] in
      // If toggling fullscreen, this also changes the window frame:
      openNewPanelsAndFinalizeOffsets(transition)

      if transition.isTogglingFullScreen {
        // Fullscreen animations don't have much time. Combine fadeIn step in same animation:
        fadeInNewViews(transition)
      }
    }))

    if !transition.isTogglingFullScreen && transition.needsFadeInNewViews {
      transition.animationTasks.append(CocoaAnimation.Task(duration: endingAnimationDuration, timing: panelTimingName, { [self] in
        fadeInNewViews(transition)
      }))
    }

    // After animations all finish
    transition.animationTasks.append(CocoaAnimation.zeroDurationTask{ [self] in
      doPostTransitionWork(transition)
    })

    if thenRun {
      animationQueue.run(transition.animationTasks)
    }
    return transition
  }

  // MARK: Transition Tasks

  private func doPreTransitionWork(_ transition: LayoutTransition) {
    log.verbose("[\(transition.name)] DoPreTransitionWork")
    controlBarFloating.isDragging = false

    /// Some methods where reference `currentLayout` get called as a side effect of the transition animations.
    /// To avoid possible bugs as a result, let's update this at the very beginning.
    currentLayout = transition.toLayout

    /// Set this here because we are setting `currentLayout`
    if transition.toLayout.spec.mode == .windowed {
      windowedModeGeometry = transition.toWindowGeometry
    }

    guard let window = window else { return }

    if transition.isEnteringFullScreen {
      // Entering FullScreen
      let isTogglingLegacyStyle = transition.isTogglingLegacyWindowStyle
      /// `windowedModeGeometry` should already be kept up to date. Might be hard to track down bugs...
      log.verbose("Entering fullscreen, priorWindowedGeometry := \(windowedModeGeometry)")

      // Hide traffic light buttons & title during the animation.
      // Do not move this block. It needs to go here.
      hideBuiltInTitleBarItems()

      if #unavailable(macOS 10.14) {
        // Set the appearance to match the theme so the title bar matches the theme
        let iinaTheme = Preference.enum(for: .themeMaterial) as Preference.Theme
        switch(iinaTheme) {
        case .dark, .ultraDark: window.appearance = NSAppearance(named: .vibrantDark)
        default: window.appearance = NSAppearance(named: .vibrantLight)
        }
      }

      setWindowFloatingOnTop(false, updateOnTopStatus: false)

      if isTogglingLegacyStyle {
        // Legacy fullscreen cannot handle transition while playing and will result in a black flash or jittering.
        // This will briefly freeze the video output, which is slightly better
        videoView.videoLayer.suspend()

        // stylemask
        log.verbose("Removing window styleMask.titled")
        if #available(macOS 10.16, *) {
          window.styleMask.remove(.titled)
        } else {
          window.styleMask.insert(.fullScreen)
        }
      }
      // Let mpv decide the correct render region in full screen
      player.mpv.setFlag(MPVOption.Window.keepaspect, true)

      resetViewsForFullScreenTransition()

    } else if transition.isExitingFullScreen {
      // Exiting FullScreen

      resetViewsForFullScreenTransition()

      apply(visibility: .hidden, to: additionalInfoView)

      if transition.isTogglingLegacyWindowStyle {
        videoView.videoLayer.suspend()
      }
      // Hide traffic light buttons & title during the animation:
      hideBuiltInTitleBarItems()

      player.mpv.setFlag(MPVOption.Window.keepaspect, false)
    }
  }

  private func fadeOutOldViews(_ transition: LayoutTransition) {
    let futureLayout = transition.toLayout
    log.verbose("[\(transition.name)] FadeOutOldViews")

    // Title bar & title bar accessories:

    let needToHideTopBar = transition.isTopBarPlacementChanging || transition.isTogglingLegacyWindowStyle

    // Hide all title bar items if top bar placement is changing
    if needToHideTopBar || futureLayout.titleIconAndText == .hidden {
      apply(visibility: .hidden, documentIconButton, titleTextField)
    }

    if needToHideTopBar || futureLayout.trafficLightButtons == .hidden {
      /// Workaround for Apple bug (as of MacOS 13.3.1) where setting `alphaValue=0` on the "minimize" button will
      /// cause `window.performMiniaturize()` to be ignored. So to hide these, use `isHidden=true` + `alphaValue=1` instead.
      for button in trafficLightButtons {
        button.isHidden = true
      }
    }

    if needToHideTopBar || futureLayout.titlebarAccessoryViewControllers == .hidden {
      // Hide all title bar accessories (if needed):
      leadingTitleBarAccessoryView.alphaValue = 0
      fadeableViewsTopBar.remove(leadingTitleBarAccessoryView)
      trailingTitleBarAccessoryView.alphaValue = 0
      fadeableViewsTopBar.remove(trailingTitleBarAccessoryView)
    } else {
      /// We may have gotten here in response to one of these buttons' visibility being toggled in the prefs,
      /// so we need to allow for showing/hiding these individually.
      /// Setting `.isHidden = true` for these icons visibly messes up their layout.
      /// So just set alpha value for now, and hide later in `updateHiddenViewsAndConstraints()`
      if futureLayout.leadingSidebarToggleButton == .hidden {
        leadingSidebarToggleButton.alphaValue = 0
        fadeableViewsTopBar.remove(leadingSidebarToggleButton)
      }
      if futureLayout.trailingSidebarToggleButton == .hidden {
        trailingSidebarToggleButton.alphaValue = 0
        fadeableViewsTopBar.remove(trailingSidebarToggleButton)
      }
      if futureLayout.pinToTopButton == .hidden {
        pinToTopButton.alphaValue = 0
        fadeableViewsTopBar.remove(pinToTopButton)
      }
    }

    if transition.fromLayout.hasFloatingOSC && !futureLayout.hasFloatingOSC {
      // Hide floating OSC
      apply(visibility: futureLayout.controlBarFloating, to: controlBarFloating)
    }

    // Change blending modes
    if transition.isTogglingFullScreen {
      /// Need to use `.withinWindow` during animation or else panel tint can change in odd ways
      topBarView.blendingMode = .withinWindow
      bottomBarView.blendingMode = .withinWindow
      leadingSidebarView.blendingMode = .withinWindow
      trailingSidebarView.blendingMode = .withinWindow
    }

    if transition.isEnteringMusicMode {
      hideOSD()
    }
  }

  private func closeOldPanels(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let futureLayout = transition.toLayout
    log.verbose("[\(transition.name)] CloseOldPanels: title_H=\(futureLayout.titleBarHeight), topOSC_H=\(futureLayout.topOSCHeight)")

    if transition.fromLayout.titleBarHeight > 0 && futureLayout.titleBarHeight == 0 {
      titleBarHeightConstraint.animateToConstant(0)
    }
    if transition.fromLayout.topOSCHeight > 0 && futureLayout.topOSCHeight == 0 {
      topOSCHeightConstraint.animateToConstant(0)
    }
    if transition.fromLayout.osdMinOffsetFromTop > 0 && futureLayout.osdMinOffsetFromTop == 0 {
      osdMinOffsetFromTopConstraint.animateToConstant(0)
    }

    // Update heights of top & bottom bars:

    let windowFrame = window.frame
    var windowYDelta: CGFloat = 0
    var windowHeightDelta: CGFloat = 0

    var needsTopBarHeightUpdate = false
    var newTopBarHeight: CGFloat = 0
    if !transition.isInitialLayout && transition.isTopBarPlacementChanging {
      needsTopBarHeightUpdate = true
      // close completely. will animate reopening if needed later
      newTopBarHeight = 0
    } else if futureLayout.topBarHeight < transition.fromLayout.topBarHeight {
      needsTopBarHeightUpdate = true
      newTopBarHeight = futureLayout.topBarHeight
    } else if futureLayout.cameraHousingOffset < transition.fromLayout.cameraHousingOffset {
      // Exiting legacy fullscreen on MacBook display with magic camera bar.
      // Need to update camera housing constraint for a better animation
      needsTopBarHeightUpdate = true
      newTopBarHeight = transition.fromLayout.topBarHeight  // leave the same
    }

    if needsTopBarHeightUpdate {
      // By default, when the window size changes, the system will add or subtract space from the bottom of the window.
      // Override this behavior to expand/contract upwards instead.
      if transition.fromLayout.topBarPlacement == .outsideVideo {
        windowHeightDelta -= videoContainerTopOffsetFromContentViewTopConstraint.constant
      }
      if transition.toLayout.topBarPlacement == .outsideVideo {
        windowHeightDelta += newTopBarHeight
      }

      updateTopBarHeight(to: newTopBarHeight, transition: transition)

      // Update sidebar vertical alignments to match:
      updateSidebarVerticalConstraints(layout: futureLayout)
    }

    var needsBottomBarHeightUpdate = false
    var newBottomBarHeight: CGFloat = 0
    if !transition.isInitialLayout && transition.isBottomBarPlacementChanging || transition.isTogglingMusicMode {
      needsBottomBarHeightUpdate = true
      // close completely. will animate reopening if needed later
      newBottomBarHeight = 0
    } else if transition.toWindowGeometry.outsideBottomBarHeight < transition.fromWindowGeometry.outsideBottomBarHeight {
      needsBottomBarHeightUpdate = true
      newBottomBarHeight = transition.toWindowGeometry.outsideBottomBarHeight
    }

    if needsBottomBarHeightUpdate {
      /// Because we are calling `setFrame()` to update the top bar, we also need to take the bottom bar into
      /// account. Otherwise the system may choose to move the window in an unwanted arbitrary direction.
      /// We want the bottom bar, if "outside" the video, to expand/collapse on the bottom side.
      if transition.fromLayout.bottomBarPlacement == .outsideVideo {
        windowHeightDelta -= videoContainerBottomOffsetFromContentViewBottomConstraint.constant
        windowYDelta -= videoContainerBottomOffsetFromContentViewBottomConstraint.constant
      }
      if transition.toLayout.bottomBarPlacement == .outsideVideo {
        windowHeightDelta += newBottomBarHeight
        windowYDelta += newBottomBarHeight
      }

      updateBottomBarHeight(to: newBottomBarHeight, bottomBarPlacement: transition.toLayout.bottomBarPlacement)
    }

    let isWindowHeightChanging = windowYDelta != 0 || windowHeightDelta != 0
    // Do not do this when first opening the window though, because it will cause the window location restore to be incorrect.
    // Also do not apply when toggling fullscreen because it is not relevant and will cause glitches in the animation.
    if isWindowHeightChanging && !transition.isInitialLayout && !transition.isTogglingFullScreen && !futureLayout.isFullScreen {
      let newWindowSize = CGSize(width: windowFrame.width, height: windowFrame.height + windowHeightDelta)
      let newOrigin = CGPoint(x: windowFrame.origin.x, y: windowFrame.origin.y - windowYDelta)
      let newWindowFrame = NSRect(origin: newOrigin, size: newWindowSize)
      log.debug("Calling setFrame() from closeOldPanels with newWindowFrame \(newWindowFrame)")
      player.window.setFrameImmediately(newWindowFrame)
    } else if transition.isTogglingFullScreen && transition.fromLayout.isLegacyFullScreen && transition.fromLayout.cameraHousingOffset > 0 {
      // Exiting legacy FS: get rid of camera housing immediately for nicer animation
      if let newWindowFrame = window.screen?.frameWithoutCameraHousing {
        player.window.setFrameImmediately(newWindowFrame)
      }
    }

    // Sidebars (if closing)
    animateShowOrHideSidebars(transition: transition, layout: transition.fromLayout,
                              setLeadingTo: transition.isHidingLeadingSidebar ? .hide : nil,
                              setTrailingTo: transition.isHidingTrailingSidebar ? .hide : nil)
    updateSpacingForTitleBarAccessories(transition.toLayout, windowWidth: transition.toWindowGeometry.windowFrame.width)

    window.contentView?.layoutSubtreeIfNeeded()
  }

  private func updateHiddenViewsAndConstraints(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let futureLayout = transition.toLayout
    log.verbose("[\(transition.name)] UpdateHiddenViewsAndConstraints")

    if transition.isTogglingLegacyWindowStyle {
      if transition.toLayout.spec.isLegacyStyle && !transition.isExitingFullScreen {
        log.verbose("Removing window styleMask.titled")
        window.styleMask.remove(.titled)
        window.styleMask.insert(.resizable)
        window.styleMask.insert(.closable)
        window.styleMask.insert(.miniaturizable)

        /// if `isTogglingLegacyWindowStyle==true && isExitingFullScreen==true`, we are toggling out of legacy FS
        /// -> don't change `styleMask` to `.titled` here - it will look bad if screen has camera housing. Change at end of animation
      } else if !transition.isTogglingFullScreen {
        log.verbose("Inserting window styleMask.titled")
        window.styleMask.insert(.titled)

        // Remove fake traffic light buttons (if any)
        if let fakeLeadingTitleBarView = fakeLeadingTitleBarView {
          for subview in fakeLeadingTitleBarView.subviews {
            subview.removeFromSuperview()
          }
          fakeLeadingTitleBarView.removeFromSuperview()
          self.fakeLeadingTitleBarView = nil
        }

        /// Setting `.titled` style will show buttons & title by default, but we don't want to show them until after panel open animation:
        for button in trafficLightButtons {
          button.isHidden = true
        }
        window.titleVisibility = .hidden
      }
      // Changing the window style while paused will lose displayed video. Draw it again:
      videoView.videoLayer.draw(forced: true)
    }

    applyHiddenOnly(visibility: futureLayout.leadingSidebarToggleButton, to: leadingSidebarToggleButton)
    applyHiddenOnly(visibility: futureLayout.trailingSidebarToggleButton, to: trailingSidebarToggleButton)
    applyHiddenOnly(visibility: futureLayout.pinToTopButton, to: pinToTopButton)

    if futureLayout.titleIconAndText == .hidden || transition.isTopBarPlacementChanging {
      /// Note: MUST use `titleVisibility` to guarantee that `documentIcon` & `titleTextField` are shown/hidden consistently.
      /// Setting `isHidden=true` on `titleTextField` and `documentIcon` do not animate and do not always work.
      /// We can use `alphaValue=0` to fade out in `fadeOutOldViews()`, but `titleVisibility` is needed to remove them.
      window.titleVisibility = .hidden
    }

    /// These should all be either 0 height or unchanged from `transition.fromLayout`
    apply(visibility: futureLayout.bottomBarView, to: bottomBarView)
    if !transition.isEnteringFullScreen {
      apply(visibility: futureLayout.topBarView, to: topBarView)
    }

    if transition.isOSCChanging {
      // Remove subviews from OSC
      for view in [fragVolumeView, fragToolbarView, fragPlaybackControlButtonsView, fragPositionSliderView] {
        view?.removeFromSuperview()
      }
    }

    if transition.isTopBarPlacementChanging {
      updateTopBarPlacement(placement: futureLayout.topBarPlacement)
    }

    if transition.isBottomBarPlacementChanging {
      updateBottomBarPlacement(placement: futureLayout.bottomBarPlacement)
    }

    if transition.isOSCChanging && futureLayout.enableOSC {
      switch futureLayout.oscPosition {
      case .top:
        log.verbose("Setting up control bar: \(futureLayout.oscPosition)")
        currentControlBar = controlBarTop
        addControlBarViews(to: oscTopMainView,
                           playBtnSize: oscBarPlaybackIconSize, playBtnSpacing: oscBarPlaybackIconSpacing)

      case .bottom:
        log.verbose("Setting up control bar: \(futureLayout.oscPosition)")
        currentControlBar = bottomBarView
        if !bottomBarView.subviews.contains(oscBottomMainView) {
          bottomBarView.addSubview(oscBottomMainView)
          oscBottomMainView.addConstraintsToFillSuperview(top: 0, bottom: 0, leading: 8, trailing: 8)
        }
        addControlBarViews(to: oscBottomMainView,
                           playBtnSize: oscBarPlaybackIconSize, playBtnSpacing: oscBarPlaybackIconSpacing)

      case .floating:
        // Wait to add these in the next task. For some reason, adding too soon here can cause volume slider to disappear
        break
      }
    }

    // Sidebars: finish closing (if closing)
    if transition.isHidingLeadingSidebar, let visibleTab = transition.fromLayout.leadingSidebar.visibleTab {
      /// Remove `tabGroupView` from its parent (also removes constraints):
      let viewController = (visibleTab.group == .playlist) ? playlistView : quickSettingView
      viewController.view.removeFromSuperview()
    }
    if transition.isHidingTrailingSidebar, let visibleTab = transition.fromLayout.trailingSidebar.visibleTab {
      /// Remove `tabGroupView` from its parent (also removes constraints):
      let viewController = (visibleTab.group == .playlist) ? playlistView : quickSettingView
      viewController.view.removeFromSuperview()
    }

    // Music mode
    if transition.isEnteringMusicMode {
      oscBottomMainView.removeFromSuperview()
      bottomBarView.addSubview(miniPlayer.view, positioned: .above, relativeTo: oscBottomMainView)
      miniPlayer.view.addConstraintsToFillSuperview(top: 0, leading: 8, trailing: 8)

      let bottomConstraint = miniPlayer.view.superview!.bottomAnchor.constraint(equalTo: miniPlayer.view.bottomAnchor, constant: 0)
      bottomConstraint.priority = .defaultHigh
      bottomConstraint.isActive = true

      // move playist view
      let playlistView = playlistView.view
      playlistView.removeFromSuperview()
      miniPlayer.playlistWrapperView.addSubview(playlistView)
      playlistView.addConstraintsToFillSuperview()

      // Update music mode UI
      updateTitle()
      setMaterial(Preference.enum(for: .themeMaterial))
      updateMusicModeButtonsVisibility()
      
    } else if transition.isExitingMusicMode {
      _ = miniPlayer.view
      miniPlayer.cleanUpForMusicModeExit()
      updateMusicModeButtonsVisibility()
    }

    // Sidebars: if (re)opening
    if let tabToShow = transition.toLayout.leadingSidebar.visibleTab {
      if transition.isShowingLeadingSidebar {
        prepareLayoutForOpening(leadingSidebar: transition.toLayout.leadingSidebar)
      } else if transition.fromLayout.leadingSidebar.visibleTabGroup == transition.toLayout.leadingSidebar.visibleTabGroup {
        // Tab group is already showing, but just need to switch tab
        switchToTabInTabGroup(tab: tabToShow)
      }
    }
    if let tabToShow = transition.toLayout.trailingSidebar.visibleTab {
      if transition.isShowingTrailingSidebar {
        prepareLayoutForOpening(trailingSidebar: transition.toLayout.trailingSidebar)
      } else if transition.fromLayout.trailingSidebar.visibleTabGroup == transition.toLayout.trailingSidebar.visibleTabGroup {
        // Tab group is already showing, but just need to switch tab
        switchToTabInTabGroup(tab: tabToShow)
      }
    }

    updateDepthOrderOfBars(topBar: futureLayout.topBarPlacement, bottomBar: futureLayout.bottomBarPlacement,
                           leadingSidebar: futureLayout.leadingSidebarPlacement, trailingSidebar: futureLayout.trailingSidebarPlacement)

    // So that panels toggling between "inside" and "outside" don't change until they need to (different strategy than fullscreen)
    if !transition.isTogglingFullScreen {
      updatePanelBlendingModes(to: futureLayout)
    }

    // Refresh volume & play time in UI
    updateVolumeUI()
    player.syncUITime()

    window.contentView?.layoutSubtreeIfNeeded()
  }

  private func openNewPanelsAndFinalizeOffsets(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let futureLayout = transition.toLayout
    log.verbose("[\(transition.name)] OpenNewPanelsAndFinalizeOffsets. TitleHeight: \(futureLayout.titleBarHeight), TopOSC: \(futureLayout.topOSCHeight)")

    // Update heights to their final values:
    topOSCHeightConstraint.animateToConstant(futureLayout.topOSCHeight)
    titleBarHeightConstraint.animateToConstant(futureLayout.titleBarHeight)
    osdMinOffsetFromTopConstraint.animateToConstant(futureLayout.osdMinOffsetFromTop)

    // Update heights of top & bottom bars:

    // TODO: move these calculations into the `toGeometry` calculation when transition is built
    var windowYDelta: CGFloat = 0
    var windowHeightDelta: CGFloat = 0

    if transition.fromLayout.topBarPlacement == .outsideVideo {
      windowHeightDelta -= videoContainerTopOffsetFromContentViewTopConstraint.constant
    }
    windowHeightDelta += futureLayout.topBarOutsideHeight
    updateTopBarHeight(to: futureLayout.topBarHeight, transition: transition)

    if transition.fromLayout.bottomBarPlacement == .outsideVideo {
      windowHeightDelta -= videoContainerBottomOffsetFromContentViewBottomConstraint.constant
      windowYDelta -= videoContainerBottomOffsetFromContentViewBottomConstraint.constant
    }
    if transition.toLayout.bottomBarPlacement == .outsideVideo {
      windowHeightDelta += transition.toWindowGeometry.outsideBottomBarHeight
      windowYDelta += transition.toWindowGeometry.outsideBottomBarHeight
    }
    let bottomBarHeight = transition.toLayout.bottomBarPlacement == .insideVideo ? transition.toWindowGeometry.insideBottomBarHeight : transition.toWindowGeometry.outsideBottomBarHeight
    updateBottomBarHeight(to: bottomBarHeight, bottomBarPlacement: transition.toLayout.bottomBarPlacement)

    if transition.isEnteringFullScreen {
      // Entering FullScreen
      if transition.toLayout.isLegacyFullScreen {
        // Set window frame including camera housing (if any) so that it is filled with black pixels
        setWindowFrameForLegacyFullScreen()
      } else {
        // Native FullScreen: set frame not including camera housing because it looks better with the native animation
        let screen = bestScreen
        Logger.log("Calling setFrame() to animate into full screen, to: \(screen.frameWithoutCameraHousing)", level: .verbose)
        player.window.setFrameImmediately(screen.frameWithoutCameraHousing)
      }
    } else if transition.isExitingFullScreen {
      // Exiting FullScreen
      let priorWindowFrame = transition.toWindowGeometry.windowFrame
      log.verbose("Calling setFrame() exiting \(transition.fromLayout.isLegacyFullScreen ? "legacy " : "")full screen, from priorWindowedFrame: \(priorWindowFrame)")
      player.window.setFrameImmediately(priorWindowFrame)
    } else if !transition.isInitialLayout && !futureLayout.isFullScreen {
      let windowFrame = window.frame
      let newWindowSize = CGSize(width: windowFrame.width, height: windowFrame.height + windowHeightDelta)
      let newOrigin = CGPoint(x: windowFrame.origin.x, y: windowFrame.origin.y - windowYDelta)
      let newWindowFrame = NSRect(origin: newOrigin, size: newWindowSize)
      log.debug("Calling setFrame() from openNewPanelsAndFinalizeOffsets with newWindowFrame \(newWindowFrame)")
      player.window.setFrameImmediately(newWindowFrame)
    }

    // Sidebars (if opening)
    let leadingSidebar = transition.toLayout.leadingSidebar
    let trailingSidebar = transition.toLayout.trailingSidebar
    animateShowOrHideSidebars(transition: transition,
                              layout: transition.toLayout,
                              setLeadingTo: transition.isShowingLeadingSidebar ? leadingSidebar.visibility : nil,
                              setTrailingTo: transition.isShowingTrailingSidebar ? trailingSidebar.visibility : nil)
    updateSpacingForTitleBarAccessories(transition.toLayout, windowWidth: transition.toWindowGeometry.windowFrame.width)

    // Update sidebar vertical alignments
    updateSidebarVerticalConstraints(layout: futureLayout)

    // Set up floating OSC views here. Doing this in prev or next task while animating results in visibility bugs
    if transition.isOSCChanging && futureLayout.enableOSC && futureLayout.hasFloatingOSC {
      currentControlBar = controlBarFloating

      oscFloatingPlayButtonsContainerView.addView(fragPlaybackControlButtonsView, in: .center)
      // There sweems to be a race condition when adding to these StackViews.
      // Sometimes it still contains the old view, and then trying to add again will cause a crash.
      // Must check if it already contains the view before adding.
      if !oscFloatingUpperView.views(in: .leading).contains(fragVolumeView) {
        oscFloatingUpperView.addView(fragVolumeView, in: .leading)
      }
      let toolbarView = rebuildToolbar(iconSize: oscFloatingToolbarButtonIconSize, iconPadding: oscFloatingToolbarButtonIconPadding)
      oscFloatingUpperView.addView(toolbarView, in: .trailing)
      fragToolbarView = toolbarView

      oscFloatingUpperView.setVisibilityPriority(.detachEarly, for: fragVolumeView)
      oscFloatingUpperView.setVisibilityPriority(.detachEarlier, for: toolbarView)
      oscFloatingUpperView.setClippingResistancePriority(.defaultLow, for: .horizontal)

      oscFloatingLowerView.addSubview(fragPositionSliderView)
      fragPositionSliderView.addConstraintsToFillSuperview()
      // center control bar
      let cph = Preference.float(for: .controlBarPositionHorizontal)
      let cpv = Preference.float(for: .controlBarPositionVertical)
      controlBarFloating.xConstraint.constant = window.frame.width * CGFloat(cph)
      controlBarFloating.yConstraint.constant = window.frame.height * CGFloat(cpv)

      playbackButtonsSquareWidthConstraint.constant = oscFloatingPlayBtnsSize
      playbackButtonsHorizontalPaddingConstraint.constant = oscFloatingPlayBtnsHPad
    }

    bottomBarView.layoutSubtreeIfNeeded()
    window.contentView?.layoutSubtreeIfNeeded()
  }

  private func fadeInNewViews(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let futureLayout = transition.toLayout
    log.verbose("[\(transition.name)] FadeInNewViews")

    if futureLayout.titleIconAndText.isShowable {
      window.titleVisibility = .visible
    }

    applyShowableOnly(visibility: futureLayout.controlBarFloating, to: controlBarFloating)

    if futureLayout.isFullScreen {
      if Preference.bool(for: .displayTimeAndBatteryInFullScreen) {
        apply(visibility: .showFadeableNonTopBar, to: additionalInfoView)
      }
    } else {
      /// Special case for `trafficLightButtons` due to quirks. Do not use `fadeableViews`. ALways set `alphaValue = 1`.
      for button in trafficLightButtons {
        button.alphaValue = 1
      }
      titleTextField?.alphaValue = 1
      documentIconButton?.alphaValue = 1

      if futureLayout.trafficLightButtons != .hidden {

        // TODO: figure out whether to try to replicate title bar, or just leave it out
        if false && futureLayout.spec.isLegacyStyle && fakeLeadingTitleBarView == nil {
          // Add fake traffic light buttons. Needs a lot of work...
          let btnTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
          let trafficLightButtons: [NSButton] = btnTypes.compactMap{ NSWindow.standardWindowButton($0, for: .titled) }
          let leadingStackView = NSStackView(views: trafficLightButtons)
          leadingStackView.wantsLayer = true
          leadingStackView.layer?.backgroundColor = .clear
          leadingStackView.orientation = .horizontal
          window.contentView!.addSubview(leadingStackView)
          leadingStackView.leadingAnchor.constraint(equalTo: leadingStackView.superview!.leadingAnchor).isActive = true
          leadingStackView.trailingAnchor.constraint(equalTo: leadingStackView.superview!.trailingAnchor).isActive = true
          leadingStackView.topAnchor.constraint(equalTo: leadingStackView.superview!.topAnchor).isActive = true
          leadingStackView.heightAnchor.constraint(equalToConstant: PlayerWindowController.standardTitleBarHeight).isActive = true
          leadingStackView.detachesHiddenViews = false
          leadingStackView.spacing = 6
          /// Because of possible top OSC, `titleBarView` may have reduced height.
          /// So do not vertically center the buttons. Use offset from top instead:
          leadingStackView.alignment = .top
          leadingStackView.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 0, right: 6)
          for btn in trafficLightButtons {
            btn.alphaValue = 1
//            btn.isHighlighted = true
            btn.display()
          }
          leadingStackView.layout()
          fakeLeadingTitleBarView = leadingStackView
        }

        // This works for legacy too
        for button in trafficLightButtons {
          button.isHidden = false
        }
      }

      /// Title bar accessories get removed by legacy fullscreen or if window `styleMask` did not include `.titled`.
      /// Add them back:
      addTitleBarAccessoryViews()
    }

    applyShowableOnly(visibility: futureLayout.leadingSidebarToggleButton, to: leadingSidebarToggleButton)
    applyShowableOnly(visibility: futureLayout.trailingSidebarToggleButton, to: trailingSidebarToggleButton)
    applyShowableOnly(visibility: futureLayout.pinToTopButton, to: pinToTopButton)

    // Add back title bar accessories (if needed):
    applyShowableOnly(visibility: futureLayout.titlebarAccessoryViewControllers, to: leadingTitleBarAccessoryView)
    applyShowableOnly(visibility: futureLayout.titlebarAccessoryViewControllers, to: trailingTitleBarAccessoryView)
  }

  private func doPostTransitionWork(_ transition: LayoutTransition) {
    log.verbose("[\(transition.name)] DoPostTransitionWork")
    // Update blending mode:
    updatePanelBlendingModes(to: transition.toLayout)
    /// This should go in `fadeInNewViews()`, but for some reason putting it here fixes a bug where the document icon won't fade out
    apply(visibility: transition.toLayout.titleIconAndText, titleTextField, documentIconButton)

    fadeableViewsAnimationState = .shown
    fadeableTopBarAnimationState = .shown
    resetFadeTimer()

    guard let window = window else { return }

    if transition.isEnteringFullScreen {
      // Entered FullScreen

      let isLegacy = transition.toLayout.isLegacyFullScreen
      if isLegacy {
        // Enter legacy full screen
        window.styleMask.insert(.borderless)
        window.styleMask.remove(.resizable)

        // auto hide menubar and dock (this will freeze all other animations, so must do it last)
        NSApp.presentationOptions.insert(.autoHideMenuBar)
        NSApp.presentationOptions.insert(.autoHideDock)

        window.level = .floating
      } else {
        /// Special case: need to wait until now to call `trafficLightButtons.isHidden = false` due to their quirks
        for button in trafficLightButtons {
          button.isHidden = false
        }
      }

      videoView.needsLayout = true
      videoView.layoutSubtreeIfNeeded()
      if transition.isTogglingLegacyWindowStyle {
        videoView.videoLayer.resume()
      }

      if Preference.bool(for: .blackOutMonitor) {
        blackOutOtherMonitors()
      }

      if player.info.isPaused {
        if Preference.bool(for: .playWhenEnteringFullScreen) {
          player.resume()
        } else {
          // When playback is paused the display link is stopped in order to avoid wasting energy on
          // needless processing. It must be running while transitioning to full screen mode. Now that
          // the transition has completed it can be stopped.
          videoView.displayIdle()
        }
      }

      if #available(macOS 10.12.2, *) {
        player.touchBarSupport.toggleTouchBarEsc(enteringFullScr: true)
      }

      updateWindowParametersForMPV()

      // Exit PIP if necessary
      if pipStatus == .inPIP,
         #available(macOS 10.12, *) {
        exitPIP()
      }

      player.events.emit(.windowFullscreenChanged, data: true)

    } else if transition.isExitingFullScreen {
      // Exited FullScreen

      let wasLegacy = transition.fromLayout.isLegacyFullScreen
      let isLegacyWindowedMode = transition.toLayout.spec.isLegacyStyle
      if wasLegacy {
        // Go back to titled style
        window.styleMask.remove(.borderless)
        window.styleMask.insert(.resizable)
        if #available(macOS 10.16, *) {
          if !isLegacyWindowedMode {
            log.verbose("Inserting window styleMask.titled")
            window.styleMask.insert(.titled)
          }
          window.level = .normal
        } else {
          window.styleMask.remove(.fullScreen)
        }

        restoreDockSettings()
      } else if isLegacyWindowedMode {
        log.verbose("Removing window styleMask.titled")
        window.styleMask.remove(.titled)
      }

      if Preference.bool(for: .blackOutMonitor) {
        removeBlackWindows()
      }

      if player.info.isPaused {
        // When playback is paused the display link is stopped in order to avoid wasting energy on
        // needless processing. It must be running while transitioning from full screen mode. Now that
        // the transition has completed it can be stopped.
        videoView.displayIdle()
      }

      if #available(macOS 10.12.2, *) {
        player.touchBarSupport.toggleTouchBarEsc(enteringFullScr: false)
      }

      // Must not access mpv while it is asynchronously processing stop and quit commands.
      // See comments in resetViewsForFullScreenTransition for details.
      guard !isClosing else { return }

      videoView.needsLayout = true
      videoView.layoutSubtreeIfNeeded()
      if transition.isTogglingLegacyWindowStyle {
        videoView.videoLayer.resume()
      }

      if Preference.bool(for: .pauseWhenLeavingFullScreen) && player.info.isPlaying {
        player.pause()
      }

      // restore ontop status
      if player.info.isPlaying {
        setWindowFloatingOnTop(isOntop, updateOnTopStatus: false)
      }

      resetCollectionBehavior()
      updateWindowParametersForMPV()

      if !isLegacyWindowedMode {
        // Workaround for AppKit quirk : do this here to ensure document icon & title don't get stuck in "visible" or "hidden" states
        apply(visibility: transition.toLayout.titleIconAndText, documentIconButton, titleTextField)
        for button in trafficLightButtons {
          /// Special case for fullscreen transition due to quirks of `trafficLightButtons`.
          /// In most cases it's best to avoid setting `alphaValue = 0` for these because doing so will disable their menu items,
          /// but should be ok for brief animations
          button.alphaValue = 1
          button.isHidden = false
        }
        window.titleVisibility = .visible
      }

      player.events.emit(.windowFullscreenChanged, data: false)
    }
    // Need to make sure this executes after styleMask is .titled
    addTitleBarAccessoryViews()

    log.verbose("[\(transition.name)] Done with transition. IsFullScreen:\(transition.toLayout.isFullScreen.yn), IsLegacy:\(transition.toLayout.spec.isLegacyStyle), Mode:\(currentLayout.spec.mode) mpvFS:\(player.mpv.getFlag(MPVOption.Window.fullscreen))")
    player.saveState()
  }

  // MARK: - Bars Layout

  /**
   This ONLY updates the constraints to toggle between `inside` and `outside` placement types.
   Whether it is actually shown is a concern for somewhere else.
          "Outside"
         ┌─────────────┐
         │  Title Bar  │   Top of    Top of
         ├─────────────┤    Video    Video
         │   Top OSC   │        │    │            "Inside"
   ┌─────┼─────────────┼─────┐◄─┘    └─►┌─────┬─────────────┬─────┐
   │     │            V│     │          │     │  Title Bar V│     │
   │ Left│            I│Right│          │ Left├────────────I│Right│
   │ Side│            D│Side │          │ Side│   Top OSC  D│Side │
   │  bar│            E│bar  │          │  bar├────────────E│bar  │
   │     │  VIDEO     O│     │          │     │  VIDEO     O│     │
   └─────┴─────────────┴─────┘          └─────┴─────────────┴─────┘
   */
  private func updateTopBarPlacement(placement: Preference.PanelPlacement) {
    log.verbose("Updating top bar placement to: \(placement)")
    guard let window = window, let contentView = window.contentView else { return }
    contentView.removeConstraint(topBarLeadingSpaceConstraint)
    contentView.removeConstraint(topBarTrailingSpaceConstraint)

    switch placement {
    case .insideVideo:
      // Align left & right sides with sidebars (top bar will squeeze to make space for sidebars)
      topBarLeadingSpaceConstraint = topBarView.leadingAnchor.constraint(equalTo: leadingSidebarView.trailingAnchor, constant: 0)
      topBarTrailingSpaceConstraint = topBarView.trailingAnchor.constraint(equalTo: trailingSidebarView.leadingAnchor, constant: 0)

    case .outsideVideo:
      // Align left & right sides with window (sidebars go below top bar)
      topBarLeadingSpaceConstraint = topBarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0)
      topBarTrailingSpaceConstraint = topBarView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: 0)

    }
    topBarLeadingSpaceConstraint.isActive = true
    topBarTrailingSpaceConstraint.isActive = true
  }

  private func updateTopBarHeight(to topBarHeight: CGFloat, transition: LayoutTransition) {
    let placement = transition.toLayout.topBarPlacement
    let cameraHousingOffset = transition.toLayout.cameraHousingOffset
    log.verbose("TopBar height: \(topBarHeight), placement: \(placement), cameraHousing: \(cameraHousingOffset)")

    switch placement {
    case .insideVideo:
      videoContainerTopOffsetFromTopBarBottomConstraint.animateToConstant(-topBarHeight)
      videoContainerTopOffsetFromTopBarTopConstraint.animateToConstant(0)
      videoContainerTopOffsetFromContentViewTopConstraint.animateToConstant(0 + cameraHousingOffset)
    case .outsideVideo:
      videoContainerTopOffsetFromTopBarBottomConstraint.animateToConstant(0)
      videoContainerTopOffsetFromTopBarTopConstraint.animateToConstant(topBarHeight)
      videoContainerTopOffsetFromContentViewTopConstraint.animateToConstant(topBarHeight + cameraHousingOffset)
    }
  }

  func updateDepthOrderOfBars(topBar: Preference.PanelPlacement, bottomBar: Preference.PanelPlacement,
                                leadingSidebar: Preference.PanelPlacement, trailingSidebar: Preference.PanelPlacement) {
    guard let window = window, let contentView = window.contentView else { return }

    // If a sidebar is "outsideVideo", need to put it behind the video because:
    // (1) Don't want sidebar to cast a shadow on the video
    // (2) Animate sidebar open/close with "slide in" / "slide out" from behind the video
    if leadingSidebar == .outsideVideo {
      contentView.addSubview(leadingSidebarView, positioned: .below, relativeTo: videoContainerView)
    }
    if trailingSidebar == .outsideVideo {
      contentView.addSubview(trailingSidebarView, positioned: .below, relativeTo: videoContainerView)
    }

    contentView.addSubview(topBarView, positioned: .above, relativeTo: videoContainerView)
    contentView.addSubview(bottomBarView, positioned: .above, relativeTo: videoContainerView)

    if leadingSidebar == .insideVideo {
      contentView.addSubview(leadingSidebarView, positioned: .above, relativeTo: videoContainerView)

      if topBar == .insideVideo {
        contentView.addSubview(topBarView, positioned: .below, relativeTo: leadingSidebarView)
      }
      if bottomBar == .insideVideo {
        contentView.addSubview(bottomBarView, positioned: .below, relativeTo: leadingSidebarView)
      }
    }

    if trailingSidebar == .insideVideo {
      contentView.addSubview(trailingSidebarView, positioned: .above, relativeTo: videoContainerView)

      if topBar == .insideVideo {
        contentView.addSubview(topBarView, positioned: .below, relativeTo: trailingSidebarView)
      }
      if bottomBar == .insideVideo {
        contentView.addSubview(bottomBarView, positioned: .below, relativeTo: trailingSidebarView)
      }
    }
  }

  private func updateBottomBarPlacement(placement: Preference.PanelPlacement) {
    log.verbose("Updating bottom bar placement to: \(placement)")
    guard let window = window, let contentView = window.contentView else { return }
    contentView.removeConstraint(bottomBarLeadingSpaceConstraint)
    contentView.removeConstraint(bottomBarTrailingSpaceConstraint)

    switch placement {
    case .insideVideo:
      bottomBarTopBorder.isHidden = true

      // Align left & right sides with sidebars (top bar will squeeze to make space for sidebars)
      bottomBarLeadingSpaceConstraint = bottomBarView.leadingAnchor.constraint(equalTo: leadingSidebarView.trailingAnchor, constant: 0)
      bottomBarTrailingSpaceConstraint = bottomBarView.trailingAnchor.constraint(equalTo: trailingSidebarView.leadingAnchor, constant: 0)
    case .outsideVideo:
      bottomBarTopBorder.isHidden = false

      // Align left & right sides with window (sidebars go below top bar)
      bottomBarLeadingSpaceConstraint = bottomBarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0)
      bottomBarTrailingSpaceConstraint = bottomBarView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: 0)
    }
    bottomBarLeadingSpaceConstraint.isActive = true
    bottomBarTrailingSpaceConstraint.isActive = true
  }

  func updateBottomBarHeight(to bottomBarHeight: CGFloat, bottomBarPlacement: Preference.PanelPlacement) {
    log.verbose("Updating bottomBar height to: \(bottomBarHeight), placement: \(bottomBarPlacement)")

    switch bottomBarPlacement {
    case .insideVideo:
      videoContainerBottomOffsetFromBottomBarTopConstraint.animateToConstant(bottomBarHeight)
      videoContainerBottomOffsetFromBottomBarBottomConstraint.animateToConstant(0)
      videoContainerBottomOffsetFromContentViewBottomConstraint.animateToConstant(0)
    case .outsideVideo:
      videoContainerBottomOffsetFromBottomBarTopConstraint.animateToConstant(0)
      videoContainerBottomOffsetFromBottomBarBottomConstraint.animateToConstant(-bottomBarHeight)
      videoContainerBottomOffsetFromContentViewBottomConstraint.animateToConstant(bottomBarHeight)
    }
  }

  // This method should only make a layout plan. It should not alter or reference the current layout.
  func buildFutureLayoutState(from layoutSpec: LayoutSpec) -> LayoutState {
    let window = window!

    let futureLayout = LayoutState(spec: layoutSpec)

    // Title bar & title bar accessories:

    if futureLayout.isFullScreen {
      futureLayout.titleIconAndText = .showAlways
      futureLayout.trafficLightButtons = .showAlways

      if futureLayout.isLegacyFullScreen, let unusableHeight = window.screen?.cameraHousingHeight {
        // This screen contains an embedded camera. Want to avoid having part of the window obscured by the camera housing.
        futureLayout.cameraHousingOffset = unusableHeight
      }
    } else if !futureLayout.isMusicMode {
      let visibleState: Visibility = futureLayout.topBarPlacement == .insideVideo ? .showFadeableTopBar : .showAlways

      futureLayout.topBarView = visibleState

      // If legacy window mode, do not show title bar.
      if !layoutSpec.isLegacyStyle {
        futureLayout.titleBar = visibleState

        futureLayout.trafficLightButtons = visibleState
        futureLayout.titleIconAndText = visibleState
        // May be overridden depending on OSC layout anyway
        futureLayout.titleBarHeight = PlayerWindowController.standardTitleBarHeight

        futureLayout.titlebarAccessoryViewControllers = visibleState

        // LeadingSidebar toggle button
        let hasLeadingSidebar = !layoutSpec.leadingSidebar.tabGroups.isEmpty
        if hasLeadingSidebar && Preference.bool(for: .showLeadingSidebarToggleButton) {
          futureLayout.leadingSidebarToggleButton = visibleState
        }
        // TrailingSidebar toggle button
        let hasTrailingSidebar = !layoutSpec.trailingSidebar.tabGroups.isEmpty
        if hasTrailingSidebar && Preference.bool(for: .showTrailingSidebarToggleButton) {
          futureLayout.trailingSidebarToggleButton = visibleState
        }

        // "On Top" (mpv) AKA "Pin to Top" (OS)
        futureLayout.pinToTopButton = futureLayout.computePinToTopButtonVisibility(isOnTop: isOntop)
      }

      if futureLayout.topBarPlacement == .insideVideo {
        futureLayout.osdMinOffsetFromTop = futureLayout.titleBarHeight + 8
      }

    }

    // OSC:

    if layoutSpec.enableOSC {
      // add fragment views
      switch layoutSpec.oscPosition {
      case .floating:
        futureLayout.controlBarFloating = .showFadeableNonTopBar  // floating is always fadeable
      case .top:
        if futureLayout.titleBar.isShowable {
          // If legacy window mode, do not show title bar.
          // Otherwise reduce its height a bit because it will share space with OSC
          futureLayout.titleBarHeight = PlayerWindowController.reducedTitleBarHeight
        }

        let visibility: Visibility = futureLayout.topBarPlacement == .insideVideo ? .showFadeableTopBar : .showAlways
        futureLayout.topBarView = visibility
        futureLayout.topOSCHeight = OSCToolbarButton.oscBarHeight
      case .bottom:
        futureLayout.bottomBarView = (futureLayout.bottomBarPlacement == .insideVideo) ? .showFadeableNonTopBar : .showAlways
      }
    } else {  // No OSC
      currentControlBar = nil

      if layoutSpec.mode == .musicMode {
        assert(futureLayout.bottomBarPlacement == .outsideVideo)
        futureLayout.bottomBarView = .showAlways
      }
    }

    /// Sidebar tabHeight and downshift.
    /// Downshift: try to match height of title bar
    /// Tab height: if top OSC is `insideVideo`, try to match its height
    if futureLayout.isMusicMode {
      /// Special case for music mode. Only really applies to `playlistView`,
      /// because `quickSettingView` is never shown in this mode.
      futureLayout.sidebarTabHeight = Constants.Sidebar.musicModeTabHeight
    } else if futureLayout.topBarView.isShowable && futureLayout.topBarPlacement == .insideVideo {
      futureLayout.sidebarDownshift = futureLayout.titleBarHeight

      let tabHeight = futureLayout.topOSCHeight
      // Put some safeguards in place. Don't want to waste space or be too tiny to read.
      // Leave default height if not in reasonable range.
      if tabHeight >= Constants.Sidebar.minTabHeight && tabHeight <= Constants.Sidebar.maxTabHeight {
        futureLayout.sidebarTabHeight = tabHeight
      }
    }

    return futureLayout
  }

  // MARK: - Title bar items

  func addTitleBarAccessoryViews() {
    guard let window = window else { return }
    if leadingTitlebarAccesoryViewController == nil {
      let controller = NSTitlebarAccessoryViewController()
      leadingTitlebarAccesoryViewController = controller
      controller.view = leadingTitleBarAccessoryView
      controller.layoutAttribute = .leading

      leadingTitleBarAccessoryView.heightAnchor.constraint(equalToConstant: PlayerWindowController.standardTitleBarHeight).isActive = true
    }
    if trailingTitlebarAccesoryViewController == nil {
      let controller = NSTitlebarAccessoryViewController()
      trailingTitlebarAccesoryViewController = controller
      controller.view = trailingTitleBarAccessoryView
      controller.layoutAttribute = .trailing

      trailingTitleBarAccessoryView.heightAnchor.constraint(equalToConstant: PlayerWindowController.standardTitleBarHeight).isActive = true
    }
    if window.styleMask.contains(.titled) && window.titlebarAccessoryViewControllers.isEmpty {
      window.addTitlebarAccessoryViewController(leadingTitlebarAccesoryViewController!)
      window.addTitlebarAccessoryViewController(trailingTitlebarAccesoryViewController!)

      trailingTitleBarAccessoryView.translatesAutoresizingMaskIntoConstraints = false
      leadingTitleBarAccessoryView.translatesAutoresizingMaskIntoConstraints = false
    }
  }

  func updateSpacingForTitleBarAccessories(_ layout: LayoutState? = nil, windowWidth: CGFloat) {
    let layout = layout ?? self.currentLayout

    updateSpacingForLeadingTitleBarAccessory(layout)
    updateSpacingForTrailingTitleBarAccessory(layout, windowWidth: windowWidth)
  }

  // Updates visibility of buttons on the left side of the title bar. Also when the left sidebar is visible,
  // sets the horizontal space needed to push the title bar right, so that it doesn't overlap onto the left sidebar.
  private func updateSpacingForLeadingTitleBarAccessory(_ layout: LayoutState) {
    let sidebarButtonSpace: CGFloat = layout.leadingSidebarToggleButton.isShowable ? leadingSidebarToggleButton.frame.width : 0

    // Subtract space taken by the 3 standard buttons + other visible buttons
    // Add standard space before title text by default
    let trailingSpace: CGFloat = layout.topBarPlacement == .outsideVideo ? 8 : max(8, layout.leadingSidebar.insideWidth - trafficLightButtonsWidth - sidebarButtonSpace)
    leadingTitleBarTrailingSpaceConstraint.animateToConstant(trailingSpace)

    leadingTitleBarAccessoryView.layoutSubtreeIfNeeded()
  }

  // Updates visibility of buttons on the right side of the title bar. Also when the right sidebar is visible,
  // sets the horizontal space needed to push the title bar left, so that it doesn't overlap onto the right sidebar.
  private func updateSpacingForTrailingTitleBarAccessory(_ layout: LayoutState, windowWidth: CGFloat) {
    var spaceForButtons: CGFloat = 0

    if layout.trailingSidebarToggleButton.isShowable {
      spaceForButtons += trailingSidebarToggleButton.frame.width
    }
    if layout.pinToTopButton.isShowable {
      spaceForButtons += pinToTopButton.frame.width
    }

    let leadingSpaceNeeded: CGFloat = layout.topBarPlacement == .outsideVideo ? 0 : max(0, layout.trailingSidebar.currentWidth - spaceForButtons)
    // The title icon & text looks very bad if we try to push it too far to the left. Try to detect this and just remove the offset in this case
    let maxSpaceAllowed: CGFloat = max(0, windowWidth * 0.5 - 20)
    let leadingSpace = leadingSpaceNeeded > maxSpaceAllowed ? 0 : leadingSpaceNeeded
    trailingTitleBarLeadingSpaceConstraint.animateToConstant(leadingSpace)

    // Add padding to the side for buttons
    let isAnyButtonVisible = layout.trailingSidebarToggleButton.isShowable || layout.pinToTopButton.isShowable
    let buttonMargin: CGFloat = isAnyButtonVisible ? 8 : 0
    trailingTitleBarTrailingSpaceConstraint.animateToConstant(buttonMargin)

    trailingTitleBarAccessoryView.layoutSubtreeIfNeeded()
  }

  private func hideBuiltInTitleBarItems() {
    apply(visibility: .hidden, documentIconButton, titleTextField)
    for button in trafficLightButtons {
      /// Special case for fullscreen transition due to quirks of `trafficLightButtons`.
      /// In most cases it's best to avoid setting `alphaValue = 0` for these because doing so will disable their menu items,
      /// but should be ok for brief animations
      button.alphaValue = 0
      button.isHidden = false
    }
    window?.titleVisibility = .hidden
  }

  func updatePinToTopButton() {
    let buttonVisibility = currentLayout.computePinToTopButtonVisibility(isOnTop: isOntop)
    pinToTopButton.state = isOntop ? .on : .off
    apply(visibility: buttonVisibility, to: pinToTopButton)
    if buttonVisibility == .showFadeableTopBar {
      showFadeableViews()
    }
    if let window = window {
      updateSpacingForTitleBarAccessories(windowWidth: window.frame.width)
    }
    PlayerSaveState.save(player)
  }

  // MARK: - Controller content layout

  private func addControlBarViews(to containerView: NSStackView, playBtnSize: CGFloat, playBtnSpacing: CGFloat,
                                  toolbarIconSize: CGFloat? = nil, toolbarIconSpacing: CGFloat? = nil) {
    let toolbarView = rebuildToolbar(iconSize: toolbarIconSize, iconPadding: toolbarIconSpacing)
    containerView.addView(fragPlaybackControlButtonsView, in: .leading)
    containerView.addView(fragPositionSliderView, in: .leading)
    containerView.addView(fragVolumeView, in: .leading)
    containerView.addView(toolbarView, in: .leading)
    fragToolbarView = toolbarView

    containerView.setClippingResistancePriority(.defaultLow, for: .horizontal)
    containerView.setVisibilityPriority(.mustHold, for: fragPositionSliderView)
    containerView.setVisibilityPriority(.detachEarly, for: fragVolumeView)
    containerView.setVisibilityPriority(.detachEarlier, for: toolbarView)

    playbackButtonsSquareWidthConstraint.constant = playBtnSize
    playbackButtonsHorizontalPaddingConstraint.constant = playBtnSpacing
  }

  private func rebuildToolbar(iconSize: CGFloat? = nil, iconPadding: CGFloat? = nil) -> NSStackView {
    let buttonTypeRawValues = Preference.array(for: .controlBarToolbarButtons) as? [Int] ?? []
    var buttonTypes = buttonTypeRawValues.compactMap(Preference.ToolBarButton.init(rawValue:))
    if #available(macOS 10.12.2, *) {} else {
      buttonTypes = buttonTypes.filter { $0 != .pip }
    }
    log.verbose("Adding buttons to OSC toolbar: \(buttonTypes)")

    var toolButtons: [OSCToolbarButton] = []
    for buttonType in buttonTypes {
      let button = OSCToolbarButton()
      button.setStyle(buttonType: buttonType, iconSize: iconSize, iconPadding: iconPadding)
      button.action = #selector(self.toolBarButtonAction(_:))
      toolButtons.append(button)
    }

    if let stackView = fragToolbarView {
      stackView.views.forEach { stackView.removeView($0) }
      stackView.removeFromSuperview()
      fragToolbarView = nil
    }
    let toolbarView = NSStackView(views: toolButtons)
    toolbarView.orientation = .horizontal

    for button in toolButtons {
      toolbarView.setVisibilityPriority(.detachOnlyIfNecessary, for: button)
    }

    // FIXME: this causes a crash due to conflicting constraints. Need to rewrite layout for toolbar button spacing!
    // It's not possible to control the icon padding from inside the buttons in all cases.
    // Instead we can get the same effect with a little more work, by controlling the stack view:
    //    if !toolButtons.isEmpty {
    //      let button = toolButtons[0]
    //      toolbarView.spacing = 2 * button.iconPadding
    //      toolbarView.edgeInsets = .init(top: button.iconPadding, left: button.iconPadding,
    //                                     bottom: button.iconPadding, right: button.iconPadding)
    //      Logger.log("Toolbar spacing: \(toolbarView.spacing), edgeInsets: \(toolbarView.edgeInsets)", level: .verbose, subsystem: player.subsystem)
    //    }
    return toolbarView
  }

  // MARK: - Misc support functions

  private func resetViewsForFullScreenTransition() {
    // When playback is paused the display link is stopped in order to avoid wasting energy on
    // needless processing. It must be running while transitioning to/from full screen mode.
    videoView.displayActive()

    if isInInteractiveMode {
      exitInteractiveMode(immediately: true)
    }

    thumbnailPeekView.isHidden = true
    timePreviewWhenSeek.isHidden = true
    isMouseInSlider = false
  }

  private func updatePanelBlendingModes(to futureLayout: LayoutState) {
    // Fullscreen + "behindWindow" doesn't blend properly and looks ugly
    if futureLayout.topBarPlacement == .insideVideo || futureLayout.isFullScreen {
      topBarView.blendingMode = .withinWindow
    } else {
      topBarView.blendingMode = .behindWindow
    }

    // Fullscreen + "behindWindow" doesn't blend properly and looks ugly
    if futureLayout.bottomBarPlacement == .insideVideo || futureLayout.isFullScreen {
      bottomBarView.blendingMode = .withinWindow
    } else {
      bottomBarView.blendingMode = .behindWindow
    }

    updateSidebarBlendingMode(.leadingSidebar, layout: futureLayout)
    updateSidebarBlendingMode(.trailingSidebar, layout: futureLayout)
  }

}
