//
//  Sidebars.swift
//  iina
//
//  Created by Matt Svoboda on 2023-03-26.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

fileprivate let SettingsWidth: CGFloat = 360
fileprivate let PlaylistMinWidth: CGFloat = 240
fileprivate let PlaylistMaxWidth: CGFloat = 500

fileprivate let SidebarAnimationDuration = 0.2

// How close the cursor has to be horizontally to the edge of the sidebar in order to trigger its resize:
fileprivate let sidebarResizeActivationRadius = 5.0

/** Enapsulates code relating to leading & trailing sidebars in MainWindow. */
extension MainWindowController {

  /** Type of the view embedded in sidebar. */
  enum SidebarTabGroup: String {
    case settings
    case playlist

    func width() -> CGFloat {
      switch self {
      case .settings:
        return SettingsWidth
      case .playlist:
        return CGFloat(Preference.integer(for: .playlistWidth)).clamped(to: PlaylistMinWidth...PlaylistMaxWidth)
      }
    }
  }

  enum SidebarTab: Equatable {
    case playlist
    case chapters

    case video
    case audio
    case sub
    case plugin(id: String)

    var group: SidebarTabGroup {
      switch self {
      case .playlist, .chapters:
        return .playlist
      case .video, .audio, .sub, .plugin(id: _):
        return .settings
      }
    }

    init?(name: String) {
      switch name {
      case "playlist":
        self = .playlist
      case "chapters":
        self = .chapters
      case "video":
        self = .video
      case "audio":
        self = .audio
      case "sub":
        self = .sub
      default:
        if name.hasPrefix("plugin:") {
          self = .plugin(id: String(name.dropFirst(7)))
        } else {
          return nil
        }
      }
    }

    var name: String {
      switch self {
      case .playlist: return "playlist"
      case .chapters: return "chapters"
      case .video: return "video"
      case .audio: return "audio"
      case .sub: return "sub"
      case .plugin(let id): return "plugin:\(id)"
      }
    }
  }

  class Sidebar {
    let locationID: Preference.SidebarLocation

    init(_ locationID: Preference.SidebarLocation) {
      self.locationID = locationID
    }

    // user configured:
    var placement = Preference.PanelPlacement.defaultValue
    var tabGroups: Set<SidebarTabGroup> = Set()

    // state:

    var animationState: UIAnimationState = .hidden
    var isResizing = false

    // nil means none/hidden:
    var visibleTab: SidebarTab? = nil {
      didSet {
        if visibleTab != nil {
          lastVisibleTab = visibleTab
        }
      }
    }

    var visibleTabGroup: SidebarTabGroup? {
      return visibleTab?.group
    }

    var isVisible: Bool {
      return visibleTab != nil
    }

    var currentWidth: CGFloat {
      return visibleTabGroup?.width() ?? 0
    }

    private var lastVisibleTab: SidebarTab? = nil

    var defaultTabToShow: SidebarTab? {
      // Use last visible tab if still valid:
      if let lastVisibleTab = lastVisibleTab, tabGroups.contains(lastVisibleTab.group) {
        Logger.log("Returning last visible tab for \(locationID): \(lastVisibleTab.name.quoted)", level: .verbose)
        return lastVisibleTab
      }

      // Fall back to default for whatever tab group found:
      if let group = tabGroups.first {
        switch group {
        case .playlist:
          return SidebarTab.playlist
        case .settings:
          return SidebarTab.video
        }
      }

      // If sidebar has no tab groups, can't show anything:
      Logger.log("No tab groups found for \(locationID), returning nil!", level: .warning)
      return nil
    }
  }

  // MARK: - Main Window functions
  
  // For JavascriptAPICore:
  func isShowingSettingsSidebar() -> Bool {
    return leadingSidebar.visibleTabGroup == .settings || trailingSidebar.visibleTabGroup == .settings
  }

  func isShowing(sidebarTab tab: SidebarTab) -> Bool {
    return leadingSidebar.visibleTab == tab || trailingSidebar.visibleTab == tab
  }

  @IBAction func toggleLeadingSidebarVisibility(_ sender: NSButton) {
    toggleVisibility(of: leadingSidebar)
  }

  @IBAction func toggleTrailingSidebarVisibility(_ sender: NSButton) {
    toggleVisibility(of: trailingSidebar)
  }

  func toggleVisibility(of sidebar: Sidebar) {
    // Do nothing if sidebar has no configured tabs
    guard let tab = sidebar.defaultTabToShow else { return }

    if sidebar.animationState == .shown {
      changeVisibility(forTab: tab, to: false)
    } else if sidebar.animationState == .hidden {
      changeVisibility(forTab: tab, to: true)
    }
    // Do nothing if side bar is in intermediate state
  }

  func showSidebar(forTabGroup tabGroup: SidebarTabGroup, force: Bool = false, hideIfAlreadyShown: Bool = true) {
    Logger.log("ShowSidebar for tabGroup: \(tabGroup.rawValue.quoted), force: \(force), hideIfAlreadyShown: \(hideIfAlreadyShown)",
               level: .verbose, subsystem: player.subsystem)
    switch tabGroup {
    case .playlist:
      if let tab = SidebarTab(name: playlistView.currentTab.rawValue) {
        showSidebar(tab: tab, force: force, hideIfAlreadyShown: hideIfAlreadyShown)
      }
    case .settings:
      if let tab = SidebarTab(name: quickSettingView.currentTab.name) {
        showSidebar(tab: tab, force: force, hideIfAlreadyShown: hideIfAlreadyShown)
      }
    }
  }

  func showSidebar(tab: SidebarTab, force: Bool = false, hideIfAlreadyShown: Bool = true) {
    Logger.log("ShowSidebar for tab: \(tab.name.quoted), force: \(force), hideIfAlreadyShown: \(hideIfAlreadyShown)",
               level: .verbose, subsystem: player.subsystem)
    if !force && (leadingSidebar.animationState.isInTransition || trailingSidebar.animationState.isInTransition) {
      return  // do not interrput other actions while it is animating
    }

    guard let destinationSidebar = getConfiguredSidebar(forTabGroup: tab.group) else { return }

    if destinationSidebar.visibleTab == tab && hideIfAlreadyShown {
      changeVisibility(forTab: tab, to: false)
      return
    }

    // This will change the sidebar to the displayed tab group if needed:
    changeVisibility(forTab: tab, to: true)
  }

  // Hides any visible sidebars
  func hideSidebars(animate: Bool = true, then: (() -> Void)? = nil) {
    Logger.log("Hiding all sidebars", level: .verbose)
    // Need to make sure that completionHandler (1) runs after animations, or (2) runs at all
    var completionHandler: (() -> Void)? = then
    if let visibleTab = leadingSidebar.visibleTab {
      changeVisibility(forTab: visibleTab, to: false, then: completionHandler)
      completionHandler = nil
    }
    if let visibleTab = trailingSidebar.visibleTab {
      changeVisibility(forTab: visibleTab, to: false, then: completionHandler)
      completionHandler = nil
    }
    // Run completion handler, only if it hasn't been scheduled to run already:
    if let completionHandler = completionHandler {
      completionHandler()
    }
  }

  func hideSidebarThenShowAgain(_ sidebarID: Preference.SidebarLocation) {
    guard let sidebar = sidebarsByID[sidebarID], let tab = sidebar.visibleTab else { return }
    changeVisibility(forTab: tab, to: false, then: {
      self.changeVisibility(forTab: tab, to: true)
    })
  }

  private func changeVisibility(forTab tab: SidebarTab, to show: Bool, then doAfter: (() -> Void)? = nil) {
    guard !isInInteractiveMode else { return }
    Logger.log("Changing visibility of sidebar for tab \(tab.name.quoted) to: \(show ? "SHOW" : "HIDE")",
               level: .verbose, subsystem: player.subsystem)

    let group = tab.group
    guard let sidebar = getConfiguredSidebar(forTabGroup: group) else { return }
    let currentWidth = group.width()
    Logger.log("New sidebar width for group \(group.rawValue.quoted): \(currentWidth)", level: .verbose, subsystem: player.subsystem)

    var nothingToDo = false
    if show && sidebar.isVisible {
      if sidebar.visibleTabGroup != group {
        // If tab is showing but with wrong tab group, hide it, then change it, then show again
        Logger.log("Need to change tab group for \(sidebar.locationID): will hide & re-show sidebar",
                   level: .verbose, subsystem: player.subsystem)
        guard let visibleTab = sidebar.visibleTab else {
          Logger.log("Internal error setting tab group for sidebar \(sidebar.locationID)",
                     level: .error, subsystem: player.subsystem)
          return
        }
        changeVisibility(forTab: visibleTab, to: false, then: {
          self.changeVisibility(forTab: tab, to: true, then: doAfter)
        })
        return
      } else if let visibleTab = sidebar.visibleTab, visibleTab == tab {
        Logger.log("Nothing to do; \(sidebar.locationID) is already showing tab \(visibleTab.name.quoted)",
                   level: .verbose, subsystem: player.subsystem)
        nothingToDo = true
      }
    // Else just need to change tab in tab group. Fall through
    } else if !show && !sidebar.isVisible {
      Logger.log("Nothing to do; \(sidebar.locationID) (which contains tab \(tab.name.quoted)) is already hidden",
                 level: .verbose, subsystem: player.subsystem)
      nothingToDo = true
    }

    var animationBlocks: [AnimationBlock] = []

    if nothingToDo {
      if let doAfter = doAfter {
        animationBlocks.append{ context in
          doAfter()
        }
        UIAnimation.run(animationBlocks)
      }
      return
    }

    let sidebarView: NSVisualEffectView
    switch sidebar.locationID {
    case .leadingSidebar:
      sidebarView = leadingSidebarView
      leadingSidebar.placement = Preference.enum(for: .leadingSidebarPlacement)
      if show {
        leadingSidebarView.blendingMode = leadingSidebar.placement == .outsideVideo ? .behindWindow : .withinWindow
      }
    case .trailingSidebar:
      sidebarView = trailingSidebarView
      trailingSidebar.placement = Preference.enum(for: .trailingSidebarPlacement)
      if show {
        trailingSidebarView.blendingMode = trailingSidebar.placement == .outsideVideo ? .behindWindow : .withinWindow
      }
    }

    animationBlocks.append{ [self] context in
      // This code block needs to be an AnimationBlock because it goes in the middle of the chain, but there is no visible animation.
      // Set duration to 0, or else it will look like a pause:
      context.duration = 0

      if show {
        sidebar.animationState = .willShow
        // Make it the active tab in its parent tab group (can do this whether or not it's shown):
        switch tab.group {
        case .playlist:
          guard let tabType = PlaylistViewController.TabViewType(name: tab.name) else {
            Logger.log("Cannot switch to tab \(tab.name.quoted): could not convert to PlaylistView tab!",
                       level: .error, subsystem: player.subsystem)
            return
          }
          self.playlistView.pleaseSwitchToTab(tabType)
        case .settings:
          guard let tabType = QuickSettingViewController.TabViewType(name: tab.name) else {
            Logger.log("Cannot switch to tab \(tab.name.quoted): could not convert to QuickSettingView tab!",
                       level: .error, subsystem: player.subsystem)
            return
          }
          self.quickSettingView.pleaseSwitchToTab(tabType)
        }

        sidebarView.isHidden = false

        // add view and constraints
        let viewController = (group == .playlist) ? playlistView : quickSettingView
        let tabGroupView = viewController.view
        sidebarView.addSubview(tabGroupView)
        tabGroupView.heightAnchor.constraint(equalTo: sidebarView.heightAnchor).isActive = true
        tabGroupView.widthAnchor.constraint(equalTo: sidebarView.widthAnchor).isActive = true
      } else {
        sidebar.animationState = .willHide
      }

      Logger.log("Changed animationState of \(sidebar.locationID) to \(sidebar.animationState)", level: .verbose, subsystem: player.subsystem)
    }

    // Animate the showing/hiding:
    animationBlocks.append{ [self] context in
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      guard let contentView = window?.contentView else { return }

      switch sidebar.locationID {
      case .leadingSidebar:
        updateLeadingSidebarWidth(to: currentWidth, show: show, placement: leadingSidebar.placement)

      case .trailingSidebar:
        updateTrailingSidebarWidth(to: currentWidth, show: show, placement: trailingSidebar.placement)
      }

      updateSpacingForTitleBarAccessories()
      contentView.layoutSubtreeIfNeeded()
    }

    animationBlocks.append{ [self] context in
      if show {
        sidebar.animationState = .shown
        sidebar.visibleTab = tab
      } else {  // hide
        sidebar.visibleTab = nil
        sidebarView.subviews.removeAll()
        sidebarView.isHidden = true
        sidebar.animationState = .hidden
      }
      Logger.log("Sidebar animationState is now: \(sidebar.animationState)", level: .verbose, subsystem: player.subsystem)
      if let doAfter = doAfter {
        doAfter()
      } else {
        context.duration = 0
      }
    }

    UIAnimation.run(animationBlocks)
  }

  private func updateLeadingSidebarWidth(to newWidth: CGFloat, show: Bool, placement: Preference.PanelPlacement) {
    Logger.log("LeadingSidebar showing: \(show) width: \(newWidth) placement: \(placement)", level: .verbose, subsystem: player.subsystem)
    if show {
      switch placement {
      case .outsideVideo:
        videoContainerLeadingOffsetFromLeadingSidebarLeadingConstraint.animateToConstant(newWidth)
        videoContainerLeadingOffsetFromLeadingSidebarTrailingConstraint.animateToConstant(0)
        videoContainerLeadingOffsetFromContentViewLeadingConstraint.animateToConstant(newWidth)
      case .insideVideo:
        videoContainerLeadingOffsetFromLeadingSidebarLeadingConstraint.animateToConstant(0)
        videoContainerLeadingOffsetFromLeadingSidebarTrailingConstraint.animateToConstant(-newWidth)
        videoContainerLeadingOffsetFromContentViewLeadingConstraint.animateToConstant(0)
      }
    } else {
      /// Slide left to hide
      videoContainerLeadingOffsetFromLeadingSidebarLeadingConstraint.animateToConstant(newWidth)
      videoContainerLeadingOffsetFromLeadingSidebarTrailingConstraint.animateToConstant(0)
      videoContainerLeadingOffsetFromContentViewLeadingConstraint.animateToConstant(0)
    }
  }

  private func updateTrailingSidebarWidth(to newWidth: CGFloat, show: Bool, placement: Preference.PanelPlacement) {
    Logger.log("TrailingSidebar showing: \(show) width: \(newWidth) placement: \(placement)", level: .verbose, subsystem: player.subsystem)
    if show {
      switch placement {
      case .outsideVideo:
        videoContainerTrailingOffsetFromTrailingSidebarLeadingConstraint.animateToConstant(0)
        videoContainerTrailingOffsetFromTrailingSidebarTrailingConstraint.animateToConstant(-newWidth)
        videoContainerTrailingOffsetFromContentViewTrailingConstraint.animateToConstant(-newWidth)
      case .insideVideo:
        videoContainerTrailingOffsetFromTrailingSidebarLeadingConstraint.animateToConstant(newWidth)
        videoContainerTrailingOffsetFromTrailingSidebarTrailingConstraint.animateToConstant(0)
        videoContainerTrailingOffsetFromContentViewTrailingConstraint.animateToConstant(0)
      }
    } else {
      videoContainerTrailingOffsetFromTrailingSidebarLeadingConstraint.animateToConstant(0)
      videoContainerTrailingOffsetFromTrailingSidebarTrailingConstraint.animateToConstant(-newWidth)
      videoContainerTrailingOffsetFromContentViewTrailingConstraint.animateToConstant(0)
    }
  }

  // This is so that sidebar controllers can notify when they changed tabs in their tab groups, so that
  // the tracking information here can be updated.
  func didChangeTab(to tabName: String) {
    guard let tab = SidebarTab(name: tabName) else {
      Logger.log("Could not find a matching sidebar tab for \(tabName.quoted)!", level: .error, subsystem: player.subsystem)
      return
    }
    guard let sidebar = getConfiguredSidebar(forTabGroup: tab.group) else { return }
    sidebar.visibleTab = tab
  }

  private func updateSidebarLocation(_ locationID: Preference.SidebarLocation, forTabGroup tabGroup: SidebarTabGroup) {
    let addingToSidebar: Sidebar
    let removingFromSidebar: Sidebar
    if locationID == leadingSidebar.locationID {
      addingToSidebar = leadingSidebar
      removingFromSidebar = trailingSidebar
    } else {
      addingToSidebar = trailingSidebar
      removingFromSidebar = leadingSidebar
    }
    addingToSidebar.tabGroups.insert(tabGroup)
    removingFromSidebar.tabGroups.remove(tabGroup)

    // Sidebar buttons may have changed:
    updateSpacingForTitleBarAccessories()
    updateSpacingForTitleBarAccessories()
  }

  private func getConfiguredSidebar(forTabGroup tabGroup: SidebarTabGroup) -> Sidebar? {
    for sidebar in [leadingSidebar, trailingSidebar] {
      if sidebar.tabGroups.contains(tabGroup) {
        return sidebar
      }
    }
    Logger.log("No sidebar found for tab group \(tabGroup.rawValue.quoted)!", level: .error, subsystem: player.subsystem)
    return nil
  }

  // If location of tab group changed to another sidebar (in user prefs), check if it is showing, and if so, hide it & show it on the other side
  func moveTabGroup(_ tabGroup: SidebarTabGroup, toSidebarLocation newLocationID: Preference.SidebarLocation) {
    guard let currentLocationID = getConfiguredSidebar(forTabGroup: tabGroup)?.locationID else { return }
    guard currentLocationID != newLocationID else { return }

    if let prevSidebar = sidebarsByID[currentLocationID], prevSidebar.visibleTabGroup == tabGroup, let curentVisibleTab = prevSidebar.visibleTab {
      Logger.log("Moving visible tabGroup \(tabGroup.rawValue.quoted) from \(currentLocationID) to \(newLocationID)",
                 level: .verbose, subsystem: player.subsystem)

      // Also close sidebar at new location if it is in the way.
      // This will happen in parallel to the block below it:
      if let newSidebar = sidebarsByID[newLocationID], let obstructingVisibleTab = newSidebar.visibleTab, newSidebar.isVisible {
        changeVisibility(forTab: obstructingVisibleTab, to: false)
      }

      // Close sidebar at old location. Then reopen tab group at its new location:
      changeVisibility(forTab: curentVisibleTab, to: false, then: {
        self.updateSidebarLocation(newLocationID, forTabGroup: tabGroup)
        self.changeVisibility(forTab: curentVisibleTab, to: true)
      })

    } else {
      Logger.log("Moving hidden tabGroup \(tabGroup.rawValue.quoted) from \(currentLocationID) to \(newLocationID)",
                 level: .verbose, subsystem: player.subsystem)
      self.updateSidebarLocation(newLocationID, forTabGroup: tabGroup)
    }
  }

  // MARK: - Mouse events

  func startResizingSidebar(with event: NSEvent) {
    if leadingSidebar.visibleTab == .playlist {
      let sf = leadingSidebarView.frame
      let dragRectCenterX: CGFloat = sf.origin.x + sf.width

      let activationRect = NSMakeRect(dragRectCenterX - sidebarResizeActivationRadius, sf.origin.y, 2 * sidebarResizeActivationRadius, sf.height)
      if NSPointInRect(mousePosRelatedToWindow!, activationRect) {
        Logger.log("User started resize of leading sidebar", level: .verbose, subsystem: player.subsystem)
        leadingSidebar.isResizing = true
      }
    } else if trailingSidebar.visibleTab == .playlist {
      let sf = trailingSidebarView.frame
      let dragRectCenterX: CGFloat = sf.origin.x

      let activationRect = NSMakeRect(dragRectCenterX - sidebarResizeActivationRadius, sf.origin.y, 2 * sidebarResizeActivationRadius, sf.height)
      if NSPointInRect(mousePosRelatedToWindow!, activationRect) {
        Logger.log("User started resize of trailing sidebar", level: .verbose, subsystem: player.subsystem)
        trailingSidebar.isResizing = true
      }
    }
  }

  // Returns true if handled; false if not
  func resizeSidebar(with dragEvent: NSEvent) -> Bool {
    let currentLocation = dragEvent.locationInWindow
    let newWidth: CGFloat
    let newPlaylistWidth: CGFloat

    if leadingSidebar.isResizing {
      switch leadingSidebar.placement {
      case .insideVideo:
        newWidth = currentLocation.x + 2
      case .outsideVideo:
        newWidth = currentLocation.x + 2
      }
      newPlaylistWidth = newWidth.clamped(to: PlaylistMinWidth...PlaylistMaxWidth)
      UIAnimation.disableAnimation {
        updateLeadingSidebarWidth(to: newPlaylistWidth, show: true, placement: leadingSidebar.placement)
      }
    } else if trailingSidebar.isResizing {
      switch trailingSidebar.placement {
      case .insideVideo:
        newWidth = window!.frame.width - currentLocation.x - 2
      case .outsideVideo:
        newWidth = window!.frame.width - currentLocation.x - 2
      }
      newPlaylistWidth = newWidth.clamped(to: PlaylistMinWidth...PlaylistMaxWidth)
      UIAnimation.disableAnimation {
        updateTrailingSidebarWidth(to: newPlaylistWidth, show: true, placement: trailingSidebar.placement)
      }
    } else {
      return false
    }

    Preference.set(Int(newPlaylistWidth), for: .playlistWidth)
    updateSpacingForTitleBarAccessories()
    return true
  }

  func finishResizingSidebar(with dragEvent: NSEvent) -> Bool {
    guard resizeSidebar(with: dragEvent) else { return false }
    if leadingSidebar.isResizing {
      // if it's a mouseup after resizing sidebar
      leadingSidebar.isResizing = false
      Logger.log("New width of left sidebar playlist is \(leadingSidebar.currentWidth)", level: .verbose, subsystem: player.subsystem)
      return true
    } else if trailingSidebar.isResizing {
      // if it's a mouseup after resizing sidebar
      trailingSidebar.isResizing = false
      Logger.log("New width of right sidebar playlist is \(trailingSidebar.currentWidth)", level: .verbose, subsystem: player.subsystem)
      return true
    }
    return false
  }

  func hideSidebarsOnClick() -> Bool {
    var registeredClick = false
    if let visibleTab = leadingSidebar.visibleTab, Preference.bool(for: .hideLeadingSidebarOnClick) {
      changeVisibility(forTab: visibleTab, to: false)
      registeredClick = true
    }

    if let visibleTab = trailingSidebar.visibleTab, Preference.bool(for: .hideTrailingSidebarOnClick) {
      changeVisibility(forTab: visibleTab, to: false)
      registeredClick = true
    }
    return registeredClick
  }
}

// MARK: - SidebarTabGroupViewController

private let defaultDownshift: CGFloat = 0
private let defaultTabHeight: CGFloat = 48

protocol SidebarTabGroupViewController {
  var mainWindow: MainWindowController! { get }
  func getTopOfTabsConstraint() -> NSLayoutConstraint?
  func getHeightOfTabsConstraint() -> NSLayoutConstraint?

  var customTabHeight: CGFloat? { get }

  // Implementing classes should call this, but do not need to define it (see below)
  func refreshVerticalConstraints(layout futureLayout: MainWindowController.LayoutPlan?)
}

extension SidebarTabGroupViewController {

  var customTabHeight: CGFloat? { return nil }

  /// Make sure this is called AFTER `mainWindow.setupTitleBarAndOSC()` has updated its variables
  func refreshVerticalConstraints(layout futureLayout: MainWindowController.LayoutPlan? = nil) {
    let layout = futureLayout ?? mainWindow.currentLayout
    let downshift: CGFloat
    var tabHeight: CGFloat
    if !layout.isFullScreen && layout.topPanelPlacement == Preference.PanelPlacement.outsideVideo {
      downshift = defaultDownshift
      tabHeight = defaultTabHeight
      Logger.log("MainWindow top panel is outside video; using default downshift (\(downshift)) and tab height (\(tabHeight))",
                 level: .verbose, subsystem: mainWindow.player.subsystem)
    } else {
      // Downshift: try to match title bar height
      if !layout.isFullScreen && layout.hasNoTitleBar() {
        downshift = defaultDownshift
      } else {
        // Need to adjust if has title bar, but it's style .minimal
        downshift = mainWindow.reducedTitleBarHeight
      }

      tabHeight = layout.topOSCHeight
      // Put some safeguards in place:
      if tabHeight <= 0 || tabHeight > 70 {
        tabHeight = defaultTabHeight
      }
    }

    if let customTabHeight = customTabHeight {
      // customTabHeight overrides any other height value
      tabHeight = customTabHeight
    }
    Logger.log("Sidebar downshift: \(downshift), TabHeight: \(tabHeight)", level: .verbose, subsystem: mainWindow.player.subsystem)
    getTopOfTabsConstraint()?.constant = downshift
    getHeightOfTabsConstraint()?.constant = tabHeight
  }
}
