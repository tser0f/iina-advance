//
//  LayoutState.swift
//  iina
//
//  Created by Matt Svoboda on 10/3/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

extension PlayWindowController {

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

  /// `LayoutState`: data structure which contains all the variables which describe a single layout configuration of the `PlayWindow`.
  /// ("Layout" might have been a better name for this class, but it's already used by AppKit). Notes:
  /// • With all the different window layout configurations which are now possible, it's crucial to use this class in order for animations
  ///   to work reliably.
  /// • It should be treated like a read-only object after it's built. Its member variables are only mutable to make it easier to build.
  /// • When any member variable inside it needs to be changed, a new `LayoutState` object should be constructed to describe the new state,
  ///   and a `LayoutTransition` should be built to describe the animations needs to go from old to new.
  /// • The new `LayoutState`, once active, should be stored in the `currentLayout` of `PlayWindowController` for future reference.
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

    var outsideTopBarHeight: CGFloat {
      return topBarPlacement == .outsideVideo ? topBarHeight : 0
    }

    /// NOTE: Is mutable!
    var outsideTrailingBarWidth: CGFloat {
      return spec.trailingSidebar.outsideWidth
    }

    /// NOTE: Is mutable!
    var outsideLeadingBarWidth: CGFloat {
      return spec.leadingSidebar.outsideWidth
    }

    /// Bar widths/heights IF `insideVideo`

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
