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
    Logger.log("ShowSidebar for tabGroup: \(tabGroup.rawValue.quoted), force: \(force), hideIfAlreadyShown: \(hideIfAlreadyShown)")
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
    Logger.log("ShowSidebar for tab: \(tab.name.quoted), force: \(force), hideIfAlreadyShown: \(hideIfAlreadyShown)")
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
    // Need to make sure that completionHandler (1) runs at all, and (2) runs after animations
    var completionHandler: (() -> Void)? = then
    if let visibleTab = leadingSidebar.visibleTab {
      changeVisibility(forTab: visibleTab, to: false, then: completionHandler)
      completionHandler = nil
    }
    if let visibleTab = trailingSidebar.visibleTab {
      changeVisibility(forTab: visibleTab, to: false, then: completionHandler)
      completionHandler = nil
    }
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
    Logger.log("Changing visibility of sidebar for tab \(tab.name.quoted) to: \(show ? "SHOW" : "HIDE")", level: .verbose)

    let group = tab.group
    guard let sidebar = getConfiguredSidebar(forTabGroup: group) else { return }
    let currentWidth = group.width()
    Logger.log("New sidebar width for group \(group.rawValue.quoted): \(currentWidth)")

    var nothingToDo = false
    if show && sidebar.isVisible {
      if sidebar.visibleTabGroup != group {
        // If tab is open but with wrong tab group, hide it, then change it, then show again
        Logger.log("Need to change tab group for \(sidebar.locationID): will hide & reopen", level: .verbose)
        guard let visibleTab = sidebar.visibleTab else {
          Logger.log("Internal error setting tab group for sidebar \(sidebar.locationID)", level: .error)
          return
        }
        changeVisibility(forTab: visibleTab, to: false, then: {
          self.changeVisibility(forTab: tab, to: true, then: doAfter)
        })
        return
      } else if let visibleTab = sidebar.visibleTab, visibleTab == tab {
        Logger.log("Nothing to do; \(sidebar.locationID) is already showing tab \(visibleTab.name.quoted)", level: .verbose)
        nothingToDo = true
      }
      // Else just need to change tab in tab group. Fall through
    } else if !show && !sidebar.isVisible {
      Logger.log("Nothing to do; \(sidebar.locationID) (which contains tab \(tab.name.quoted)) is already hidden", level: .verbose)
      nothingToDo = true
    }

    var blockChain: [AnimationBlock] = []

    if nothingToDo {
      if let doAfter = doAfter {
        blockChain.append{ context in
          doAfter()
        }
        UIAnimation.run(blockChain)
      }
      return
    }

    let sidebarView: NSVisualEffectView
    switch sidebar.locationID {
    case .leadingSidebar:
      sidebarView = leadingSidebarView
    case .trailingSidebar:
      sidebarView = trailingSidebarView
    }

    blockChain.append{ [self] context in
      // This code block needs to be an AnimationBlock because it goes in the middle of the chain, but there is no visible animation.
      // Set duration to 0, or else it will look like a pause:
      context.duration = 0

      if show {
        sidebar.animationState = .willShow
        // Make it the active tab in its parent tab group (can do this whether or not it's shown):
        switch tab.group {
        case .playlist:
          guard let tabType = PlaylistViewController.TabViewType(name: tab.name) else {
            Logger.log("Cannot switch to tab \(tab.name.quoted): could not convert to PlaylistView tab!", level: .error)
            return
          }
          self.playlistView.pleaseSwitchToTab(tabType)
        case .settings:
          guard let tabType = QuickSettingViewController.TabViewType(name: tab.name) else {
            Logger.log("Cannot switch to tab \(tab.name.quoted): could not convert to QuickSettingView tab!", level: .error)
            return
          }
          self.quickSettingView.pleaseSwitchToTab(tabType)
        }

        // Adjust sidebar widths (& related constraints) before showing in case it's not up to date
        switch sidebar.locationID {
        case .leadingSidebar:
          videoContainerLeadingToLeadingSidebarConstraint.constant = currentWidth
          windowContentViewLeadingConstraint.constant = 0
          leadingSidebarWidthConstraint.constant = currentWidth
        case .trailingSidebar:
          videoContainerTrailingToTrailingSidebarConstraint.constant = -currentWidth  // note: opposite here vs leading sidebar
          windowContentViewTrailingConstraint.constant = 0
          trailingSidebarWidthConstraint.constant = currentWidth
        }

        // add view and constraints
        let viewController = (group == .playlist) ? playlistView : quickSettingView
        let tabGroupView = viewController.view
        sidebarView.addSubview(tabGroupView)
        tabGroupView.heightAnchor.constraint(equalTo: sidebarView.heightAnchor).isActive = true
        tabGroupView.widthAnchor.constraint(equalTo: sidebarView.widthAnchor).isActive = true

        sidebarView.isHidden = false
      } else {
        sidebar.animationState = .willHide
      }

      Logger.log("Changed animationState of \(sidebar.locationID) to \(sidebar.animationState)", level: .verbose)
    }

    blockChain.append{ [self] context in
      context.timingFunction = CAMediaTimingFunction(name: .easeIn)
      guard let contentView = window?.contentView else { return }

      switch sidebar.locationID {
      case .leadingSidebar:
        contentView.removeConstraint(videoContainerLeadingToLeadingSidebarConstraint)
        contentView.removeConstraint(windowContentViewLeadingConstraint)

        let leadingSidebarPlacement: Preference.PanelPlacement = Preference.enum(for: .leadingSidebarPlacement)
        leadingSidebar.placement = leadingSidebarPlacement
        if show && leadingSidebarPlacement == .outsideVideo {
          videoContainerLeadingToLeadingSidebarConstraint = videoContainerView.leadingAnchor.constraint(equalTo: leadingSidebarView.trailingAnchor, constant: 0)
          windowContentViewLeadingConstraint = contentView.leadingAnchor.constraint(equalTo: leadingSidebarView.leadingAnchor, constant: 0)
        } else { // inside video, or hidden
          let newWidth = show ? 0 : currentWidth
          videoContainerLeadingToLeadingSidebarConstraint = videoContainerView.leadingAnchor.constraint(equalTo: leadingSidebarView.leadingAnchor, constant: newWidth)
          windowContentViewLeadingConstraint = contentView.leadingAnchor.constraint(equalTo: videoContainerView.leadingAnchor, constant: 0)
        }
        windowContentViewLeadingConstraint.isActive = true
        videoContainerLeadingToLeadingSidebarConstraint.isActive = true

        updateSpacingForTitleBarAccessories()
      case .trailingSidebar:
        contentView.removeConstraint(videoContainerTrailingToTrailingSidebarConstraint)
        contentView.removeConstraint(windowContentViewTrailingConstraint)

        let trailingSidebarPlacement: Preference.PanelPlacement = Preference.enum(for: .trailingSidebarPlacement)
        trailingSidebar.placement = trailingSidebarPlacement
        if show && trailingSidebarPlacement == .outsideVideo {
          videoContainerTrailingToTrailingSidebarConstraint = videoContainerView.trailingAnchor.constraint(equalTo: trailingSidebarView.leadingAnchor, constant: 0)
          windowContentViewTrailingConstraint = contentView.trailingAnchor.constraint(equalTo: trailingSidebarView.trailingAnchor, constant: 0)
        } else { // inside video, or hidden
          /// NOTE: `newWidth` has opposite sign here vs leading sidebar
          let newWidth = show ? 0 : -currentWidth
          videoContainerTrailingToTrailingSidebarConstraint = videoContainerView.trailingAnchor.constraint(equalTo: trailingSidebarView.trailingAnchor, constant: newWidth)
          windowContentViewTrailingConstraint = contentView.trailingAnchor.constraint(equalTo: videoContainerView.trailingAnchor, constant: 0)
        }

        windowContentViewTrailingConstraint.isActive = true
        videoContainerTrailingToTrailingSidebarConstraint.isActive = true

        updateSpacingForTitleBarAccessories()
      }

      contentView.layoutSubtreeIfNeeded()
    }

    blockChain.append{ _ in
      if show {
        sidebar.animationState = .shown
        sidebar.visibleTab = tab
      } else {  // hide
        sidebar.visibleTab = nil
        sidebarView.subviews.removeAll()
        sidebarView.isHidden = true
        sidebar.animationState = .hidden
      }
      Logger.log("Sidebar animation state is now: \(sidebar.animationState)")
      if let doAfter = doAfter {
        doAfter()
      }
    }

    UIAnimation.run(blockChain)
  }

  // This is so that sidebar controllers can notify when they changed tabs in their tab groups, so that
  // the tracking information here can be updated.
  func didChangeTab(to tabName: String) {
    guard let tab = SidebarTab(name: tabName) else {
      Logger.log("Could not find a matching sidebar tab for \(tabName.quoted)!", level: .error)
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
    Logger.log("No sidebar found for tab group \(tabGroup.rawValue.quoted)!", level: .error)
    return nil
  }

  // If location of tab group changed to another sidebar (in user prefs), check if it is showing, and if so, hide it & show it on the other side
  func moveTabGroup(_ tabGroup: SidebarTabGroup, toSidebarLocation newLocationID: Preference.SidebarLocation) {
    guard let currentLocationID = getConfiguredSidebar(forTabGroup: tabGroup)?.locationID else { return }
    guard currentLocationID != newLocationID else { return }

    if let prevSidebar = sidebarsByID[currentLocationID], prevSidebar.visibleTabGroup == tabGroup, let curentVisibleTab = prevSidebar.visibleTab {
      Logger.log("Moving visible tabGroup \(tabGroup.rawValue.quoted) from \(currentLocationID) to \(newLocationID)", level: .verbose)
      changeVisibility(forTab: curentVisibleTab, to: false, then: {
        self.updateSidebarLocation(newLocationID, forTabGroup: tabGroup)
        self.changeVisibility(forTab: curentVisibleTab, to: true)
      })
    } else {
      Logger.log("Moving hidden tabGroup \(tabGroup.rawValue.quoted) from \(currentLocationID) to \(newLocationID)", level: .verbose)
      self.updateSidebarLocation(newLocationID, forTabGroup: tabGroup)
    }
  }

  // MARK: - Mouse events

  func startResizingSidebar(with event: NSEvent) {
    if leadingSidebar.visibleTab == .playlist {
      let sf = leadingSidebarView.frame
      let dragRectCenterX: CGFloat
      switch leadingSidebar.placement {
      case .insideVideo:
        dragRectCenterX = sf.origin.x + sf.width
      case .outsideVideo:
        dragRectCenterX = sf.origin.x
      }

      let activationRect = NSMakeRect(dragRectCenterX - sidebarResizeActivationRadius, sf.origin.y, 2 * sidebarResizeActivationRadius, sf.height)
      if NSPointInRect(mousePosRelatedToWindow!, activationRect) {
        Logger.log("User started resize of leading sidebar", level: .verbose)
        leadingSidebar.isResizing = true
      }
    } else if trailingSidebar.visibleTab == .playlist {
      let sf = trailingSidebarView.frame
      let dragRectCenterX: CGFloat
      switch leadingSidebar.placement {
      case .insideVideo:
        dragRectCenterX = sf.origin.x
      case .outsideVideo:
        dragRectCenterX = sf.origin.x + sf.width
      }

      let activationRect = NSMakeRect(dragRectCenterX - sidebarResizeActivationRadius, sf.origin.y, 2 * sidebarResizeActivationRadius, sf.height)
      if NSPointInRect(mousePosRelatedToWindow!, activationRect) {
        Logger.log("User started resize of trailing sidebar", level: .verbose)
        trailingSidebar.isResizing = true
      }
    }
  }

  // Returns true if handled; false if not
  func resizeSidebar(with dragEvent: NSEvent) -> Bool {
    let currentLocation = dragEvent.locationInWindow
    let newWidth: CGFloat

    if leadingSidebar.isResizing {
      switch leadingSidebar.placement {
      case .insideVideo:
        newWidth = currentLocation.x + 2
      case .outsideVideo:
        newWidth = leadingSidebarView.frame.width + currentLocation.x + 2
      }
      let newPlaylistWidth = newWidth.clamped(to: PlaylistMinWidth...PlaylistMaxWidth)
      leadingSidebarWidthConstraint.constant = newPlaylistWidth
    } else if trailingSidebar.isResizing {
      switch trailingSidebar.placement {
      case .insideVideo:
        newWidth = window!.frame.width - currentLocation.x - 2
      case .outsideVideo:
        newWidth = window!.frame.width - currentLocation.x + trailingSidebarView.frame.width - 2
      }
      let newPlaylistWidth = newWidth.clamped(to: PlaylistMinWidth...PlaylistMaxWidth)
      trailingSidebarWidthConstraint.constant = newPlaylistWidth
    } else {
      return false
    }

    updateSpacingForTitleBarAccessories()
    return true
  }

  func finishResizingSidebar() -> Bool {
    if leadingSidebar.isResizing {
      // if it's a mouseup after resizing sidebar
      leadingSidebar.isResizing = false
      Logger.log("New width of left sidebar playlist is \(leadingSidebarWidthConstraint.constant)", level: .verbose)
      Preference.set(Int(leadingSidebarWidthConstraint.constant), for: .playlistWidth)
      return true
    } else if trailingSidebar.isResizing {
      // if it's a mouseup after resizing sidebar
      trailingSidebar.isResizing = false
      Logger.log("New width of right sidebar playlist is \(trailingSidebarWidthConstraint.constant)", level: .verbose)
      Preference.set(Int(trailingSidebarWidthConstraint.constant), for: .playlistWidth)
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
  func refreshVerticalConstraints()
}

extension SidebarTabGroupViewController {

  var customTabHeight: CGFloat? { return nil }

  /// Make sure this is called AFTER `mainWindow.setupTitleBarAndOSC()` has updated its variables
  func refreshVerticalConstraints() {
    let downshift: CGFloat
    var tabHeight: CGFloat
    if Preference.enum(for: .topPanelPlacement) == Preference.PanelPlacement.outsideVideo {
      downshift = defaultDownshift
      tabHeight = defaultTabHeight
      Logger.log("MainWindow top panel is outside video; using default downshift (\(downshift)) and tab height (\(tabHeight))", level: .verbose, subsystem: mainWindow.player.subsystem)
    } else {
      // Downshift: try to match title bar height
      if mainWindow.hasNoTitleBar() {
        downshift = defaultDownshift
      } else {
        // Need to adjust if has title bar, but it's style .minimal
        downshift = mainWindow.reducedTitleBarHeight
      }

      tabHeight = mainWindow.topOSCTargetHeight
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
