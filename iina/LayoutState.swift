//
//  LayoutState.swift
//  iina
//
//  Created by Matt Svoboda on 10/3/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

extension PlayerWindowController {

  enum WindowMode: Int {
    case windowed = 1
    case fullScreen
    case musicMode
    //    case interactiveWindow
    //    case interactiveFullScreen
  }

  /// `LayoutSpec`: data structure containing a window's layout configuration, and is the blueprint for building a `LayoutState`.
  /// Most of the fields in this struct can be derived from IINA's application settings, although some state like active sidebar tab
  /// and window mode can vary for each window.
  /// See also: `LayoutState.from()`, which contains the logic to compile a `LayoutState` from a `LayoutSpec`.
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
        self.topBarPlacement = .insideViewport
        self.bottomBarPlacement = .outsideViewport
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
                        topBarPlacement:.insideViewport,
                        bottomBarPlacement: .insideViewport,
                        enableOSC: false,
                        oscPosition: .floating)
    }

    /// Factory method. Init from preferences, except for `mode` and tab params
    static func fromPreferences(andMode newMode: WindowMode? = nil,
                                isLegacyStyle: Bool? = nil,
                                fillingInFrom oldSpec: LayoutSpec) -> LayoutSpec {

      let leadingSidebarVisibility = oldSpec.leadingSidebar.visibility
      let leadingSidebarLastVisibleTab = oldSpec.leadingSidebar.lastVisibleTab
      let trailingSidebarVisibility = oldSpec.trailingSidebar.visibility
      let trailingSidebarLastVisibleTab = oldSpec.trailingSidebar.lastVisibleTab

      let leadingSidebar =  Sidebar(.leadingSidebar,
                                    tabGroups: Sidebar.TabGroup.fromPrefs(for: .leadingSidebar),
                                    placement: Preference.enum(for: .leadingSidebarPlacement),
                                    visibility: leadingSidebarVisibility,
                                    lastVisibleTab: leadingSidebarLastVisibleTab)
      let trailingSidebar = Sidebar(.trailingSidebar,
                                    tabGroups: Sidebar.TabGroup.fromPrefs(for: .trailingSidebar),
                                    placement: Preference.enum(for: .trailingSidebarPlacement),
                                    visibility: trailingSidebarVisibility,
                                    lastVisibleTab: trailingSidebarLastVisibleTab)
      let mode = newMode ?? oldSpec.mode
      let isLegacyStyle = isLegacyStyle ?? (mode == .fullScreen ? Preference.bool(for: .useLegacyFullScreen) : Preference.bool(for: .useLegacyWindowedMode))
      return LayoutSpec(leadingSidebar: leadingSidebar, trailingSidebar: trailingSidebar,
                        mode: mode,
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

    func getExcessSpaceBetweenInsideSidebars(leadingSidebarWidth: CGFloat? = nil, trailingSidebarWidth: CGFloat? = nil, in viewportWidth: CGFloat) -> CGFloat {
      let lead = leadingSidebarWidth ?? leadingSidebar.insideWidth
      let trail = trailingSidebarWidth ?? trailingSidebar.insideWidth
      return viewportWidth - (lead + trail + Constants.Sidebar.minSpaceBetweenInsideSidebars)
    }

    /// Returns `(shouldCloseLeadingSidebar, shouldCloseTrailingSidebar)`, indicating which sidebars should be hidden
    /// due to lack of space in the viewport.
    func isHideSidebarNeeded(in viewportWidth: CGFloat) -> (Bool, Bool) {
      var leadingSidebarSpace = leadingSidebar.insideWidth
      var trailingSidebarSpace = trailingSidebar.insideWidth
      var vidConSpace = viewportWidth

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

    var controlBarFloating: Visibility = .hidden

    var bottomBarView: Visibility = .hidden
    var topBarView: Visibility = .hidden

    // Sizes / offsets

    /// This exists as a fallback for the case where the title bar has a transparent background but still shows its items.
    /// For most cases, spacing between OSD and top of `viewportView` >= 8pts
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

    /// Bar widths/heights IF `outsideViewport`

    var outsideTopBarHeight: CGFloat {
      return topBarPlacement == .outsideViewport ? topBarHeight : 0
    }

    /// NOTE: Is mutable!
    var outsideTrailingBarWidth: CGFloat {
      return spec.trailingSidebar.outsideWidth
    }

    /// NOTE: Is mutable!
    var outsideLeadingBarWidth: CGFloat {
      return spec.leadingSidebar.outsideWidth
    }

    /// Bar widths/heights IF `insideViewport`

    /// NOTE: Is mutable!
    var insideLeadingBarWidth: CGFloat {
      return spec.leadingSidebar.insideWidth
    }

    /// NOTE: Is mutable!
    var insideTrailingBarWidth: CGFloat {
      return spec.trailingSidebar.insideWidth
    }

    // Derived properties & convenience accessors

    var isFullScreen: Bool {
      return spec.mode == .fullScreen
    }

    var canToggleFullScreen: Bool {
      return spec.mode == .fullScreen || spec.mode == .windowed
    }

    var isNativeFullScreen: Bool {
      return isFullScreen && !spec.isLegacyStyle
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
      return enableOSC && ((oscPosition == .top && topBarPlacement == .outsideViewport) ||
                           (oscPosition == .bottom && bottomBarPlacement == .outsideViewport))
    }

    var mode: WindowMode {
      return spec.mode
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

      if topBarPlacement == .insideViewport {
        return .showFadeableNonTopBar
      }

      return .showAlways
    }

    // MARK: - Build LayoutState from LayoutSpec

    static func from(_ layoutSpec: LayoutSpec) -> LayoutState {
      let outputLayout = LayoutState(spec: layoutSpec)

      // Title bar & title bar accessories:

      if outputLayout.isFullScreen {
        outputLayout.titleIconAndText = .showAlways
        outputLayout.trafficLightButtons = .showAlways

      } else if !outputLayout.isMusicMode {
        let visibleState: Visibility = outputLayout.topBarPlacement == .insideViewport ? .showFadeableTopBar : .showAlways

        outputLayout.topBarView = visibleState

        // If legacy window mode, do not show title bar.
        if !layoutSpec.isLegacyStyle {
          outputLayout.titleBar = visibleState

          outputLayout.trafficLightButtons = visibleState
          outputLayout.titleIconAndText = visibleState
          // May be overridden depending on OSC layout anyway
          outputLayout.titleBarHeight = PlayerWindowController.standardTitleBarHeight

          outputLayout.titlebarAccessoryViewControllers = visibleState

          // LeadingSidebar toggle button
          let hasLeadingSidebar = !layoutSpec.leadingSidebar.tabGroups.isEmpty
          if hasLeadingSidebar && Preference.bool(for: .showLeadingSidebarToggleButton) {
            outputLayout.leadingSidebarToggleButton = visibleState
          }
          // TrailingSidebar toggle button
          let hasTrailingSidebar = !layoutSpec.trailingSidebar.tabGroups.isEmpty
          if hasTrailingSidebar && Preference.bool(for: .showTrailingSidebarToggleButton) {
            outputLayout.trailingSidebarToggleButton = visibleState
          }
        }

        if outputLayout.topBarPlacement == .insideViewport {
          outputLayout.osdMinOffsetFromTop = outputLayout.titleBarHeight + 8
        }

      }

      // OSC:

      if layoutSpec.enableOSC {
        // add fragment views
        switch layoutSpec.oscPosition {
        case .floating:
          outputLayout.controlBarFloating = .showFadeableNonTopBar  // floating is always fadeable
        case .top:
          if outputLayout.titleBar.isShowable {
            // If legacy window mode, do not show title bar.
            // Otherwise reduce its height a bit because it will share space with OSC
            outputLayout.titleBarHeight = PlayerWindowController.reducedTitleBarHeight
          }

          let visibility: Visibility = outputLayout.topBarPlacement == .insideViewport ? .showFadeableTopBar : .showAlways
          outputLayout.topBarView = visibility
          outputLayout.topOSCHeight = OSCToolbarButton.oscBarHeight
        case .bottom:
          outputLayout.bottomBarView = (outputLayout.bottomBarPlacement == .insideViewport) ? .showFadeableNonTopBar : .showAlways
        }
      } else {  // No OSC
        if layoutSpec.mode == .musicMode {
          assert(outputLayout.bottomBarPlacement == .outsideViewport)
          outputLayout.bottomBarView = .showAlways
        }
      }

      /// Sidebar tabHeight and downshift.
      /// Downshift: try to match height of title bar
      /// Tab height: if top OSC is `insideViewport`, try to match its height
      if outputLayout.isMusicMode {
        /// Special case for music mode. Only really applies to `playlistView`,
        /// because `quickSettingView` is never shown in this mode.
        outputLayout.sidebarTabHeight = Constants.Sidebar.musicModeTabHeight
      } else if outputLayout.topBarView.isShowable && outputLayout.topBarPlacement == .insideViewport {
        outputLayout.sidebarDownshift = outputLayout.titleBarHeight

        let tabHeight = outputLayout.topOSCHeight
        // Put some safeguards in place. Don't want to waste space or be too tiny to read.
        // Leave default height if not in reasonable range.
        if tabHeight >= Constants.Sidebar.minTabHeight && tabHeight <= Constants.Sidebar.maxTabHeight {
          outputLayout.sidebarTabHeight = tabHeight
        }
      }

      return outputLayout
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

  func apply(visibility: Visibility, to view: NSView) {
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

  func apply(visibility: Visibility, _ views: NSView?...) {
    for view in views {
      if let view = view {
        apply(visibility: visibility, to: view)
      }
    }
  }

  func applyHiddenOnly(visibility: Visibility, to view: NSView, isTopBar: Bool = true) {
    guard visibility == .hidden else { return }
    apply(visibility: visibility, view)
  }

  func applyShowableOnly(visibility: Visibility, to view: NSView, isTopBar: Bool = true) {
    guard visibility != .hidden else { return }
    apply(visibility: visibility, view)
  }
}
