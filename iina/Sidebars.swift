//
//  Sidebars.swift
//  iina
//
//  Created by Matt Svoboda on 2023-03-26.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

private func clampPlaylistWidth(_ width: CGFloat) -> CGFloat {
  return width.clamped(to: Constants.Sidebar.minPlaylistWidth...Constants.Sidebar.maxPlaylistWidth).rounded()
}

/** Enapsulates code relating to leading & trailing sidebars in MainWindow. */
extension MainWindowController {

  struct Sidebar {
    enum Visibility {
      case show(tabToShow: Sidebar.Tab)
      case hide

      var visibleTab: Sidebar.Tab? {
        switch self {
        case .show(let tab):
          return tab
        case .hide:
          return nil
        }
      }
    }

    /** Type of the view embedded in sidebar. */
    enum TabGroup: String {
      case settings
      case playlist

      func width() -> CGFloat {
        switch self {
        case .settings:
          return Constants.Sidebar.settingsWidth
        case .playlist:
          return clampPlaylistWidth(CGFloat(Preference.integer(for: .playlistWidth)))
        }
      }
    }

    enum Tab: Equatable {
      case playlist
      case chapters

      case video
      case audio
      case sub
      case plugin(id: String)

      var group: Sidebar.TabGroup {
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

    init(_ locationID: Preference.SidebarLocation, tabGroups: Set<TabGroup>, placement: Preference.PanelPlacement,
         visibility: Sidebar.Visibility, lastVisibleTab: Sidebar.Tab? = nil) {
      self.locationID = locationID
      self.placement = placement
      self.visibility = visibility

      self.tabGroups = tabGroups

      /// some validation before setting `lastVisibleTab`
      if let tab = lastVisibleTab, tabGroups.contains(tab.group) {
        self.lastVisibleTab = lastVisibleTab
      } else if let visibleTab = visibility.visibleTab {
        self.lastVisibleTab = visibleTab
      } else {
        self.lastVisibleTab = nil
      }
    }

    func clone(tabGroups: Set<TabGroup>? = nil, placement: Preference.PanelPlacement? = nil,
               visibility: Sidebar.Visibility? = nil) -> Sidebar {
      let newTabGroups = tabGroups ?? self.tabGroups
      var newVisibility = visibility ?? self.visibility
      if let newVisibleTab = newVisibility.visibleTab, !newTabGroups.contains(newVisibleTab.group) {
        Logger.log("Can no longer show visible tab \(newVisibleTab.name) in \(self.locationID). The sidebar will close.", level: .verbose)
        newVisibility = .hide
      }
      let newLastVisibleTab: Tab?
      if let newVisibleTab = newVisibility.visibleTab, self.visibleTab != nil && newVisibleTab != self.visibleTab {
        /// Save current tab, if present, as `lastVisibleTab`:
        newLastVisibleTab = self.visibleTab ?? self.lastVisibleTab
      } else {
        /// No change to visibility: do not change `lastVisibleTab`
        newLastVisibleTab = self.lastVisibleTab
      }

      return Sidebar(self.locationID,
                     tabGroups: newTabGroups,
                     placement: placement ?? self.placement,
                     visibility: newVisibility,
                     lastVisibleTab: newLastVisibleTab)
    }

    let locationID: Preference.SidebarLocation

    // State:

    let placement: Preference.PanelPlacement

    let visibility: Visibility

    // user configured:
    let tabGroups: Set<Sidebar.TabGroup>

    /// The currently visible tab, if sidebar is open/visible. Is `nil` if sidebar is closed/hidden.
    /// Use `lastVisibleTab` if the last shown tab needs to be known.
    var visibleTab: Sidebar.Tab? {
      return visibility.visibleTab
    }

    let lastVisibleTab: Sidebar.Tab?

    /// Tab group of `visibleTab`
    var visibleTabGroup: Sidebar.TabGroup? {
      return visibleTab?.group
    }

    var isVisible: Bool {
      return visibleTab != nil
    }

    /// Returns `0` if sidebar is hidden.
    var currentWidth: CGFloat {
      return visibleTabGroup?.width() ?? 0
    }

    var defaultTabToShow: Sidebar.Tab? {
      // Use last visible tab if still valid:
      if let lastVisibleTab = lastVisibleTab, tabGroups.contains(lastVisibleTab.group) {
        Logger.log("Returning last visible tab for \(locationID): \(lastVisibleTab.name.quoted)", level: .verbose)
        return lastVisibleTab
      }

      // Fall back to default for whatever tab group found:
      if let group = tabGroups.first {
        switch group {
        case .playlist:
          return Sidebar.Tab.playlist
        case .settings:
          return Sidebar.Tab.video
        }
      }

      // If sidebar has no tab groups, can't show anything:
      Logger.log("No tab groups found for \(locationID), returning nil for defaultTab", level: .verbose)
      return nil
    }
  }

  // MARK: - Showing/Hiding sidebars

  @IBAction func toggleLeadingSidebarVisibility(_ sender: NSButton) {
    toggleVisibility(of: .leadingSidebar)
  }

  @IBAction func toggleTrailingSidebarVisibility(_ sender: NSButton) {
    toggleVisibility(of: .trailingSidebar)
  }

  /// Toggles visibility of given `sidebar`
  func toggleVisibility(of sidebarID: Preference.SidebarLocation) {
    let sidebar = currentLayout.sidebar(withID: sidebarID)
    log.verbose("Toggling visibility of sidebar: \(sidebarID) (isVisible: \(sidebar.isVisible))")
    // Do nothing if sidebar has no configured tabs
    guard let tab = sidebar.defaultTabToShow else { return }

    if sidebar.isVisible {
      changeVisibility(forTab: tab, to: false)
    } else {
      changeVisibility(forTab: tab, to: true)
    }
  }

  /// Shows or toggles visibility of given `tabGroup`
  func showSidebar(forTabGroup tabGroup: Sidebar.TabGroup, force: Bool = false, hideIfAlreadyShown: Bool = true) {
    Logger.log("ShowSidebar for tabGroup: \(tabGroup.rawValue.quoted), force: \(force), hideIfAlreadyShown: \(hideIfAlreadyShown)",
               level: .verbose, subsystem: player.subsystem)
    switch tabGroup {
    case .playlist:
      if let tab = Sidebar.Tab(name: playlistView.currentTab.rawValue) {
        showSidebar(tab: tab, force: force, hideIfAlreadyShown: hideIfAlreadyShown)
      }
    case .settings:
      if let tab = Sidebar.Tab(name: quickSettingView.currentTab.name) {
        showSidebar(tab: tab, force: force, hideIfAlreadyShown: hideIfAlreadyShown)
      }
    }
  }

  /// Shows or toggles visibility of given `tab`
  func showSidebar(tab: Sidebar.Tab, force: Bool = false, hideIfAlreadyShown: Bool = true) {
    Logger.log("ShowSidebar for tab: \(tab.name.quoted), force: \(force), hideIfAlreadyShown: \(hideIfAlreadyShown)",
               level: .verbose, subsystem: player.subsystem)

    animationQueue.run(UIAnimation.zeroDurationTask { [self] in
      guard let destinationSidebar = getConfiguredSidebar(forTabGroup: tab.group) else { return }

      if destinationSidebar.visibleTab == tab {
        if hideIfAlreadyShown {
          changeVisibility(forTab: tab, to: false)
        }
      } else {
        // This will first change the sidebar to the displayed tab group if needed:
        changeVisibility(forTab: tab, to: true)
      }
    })
  }

  // Updates placements (inside or outside) of both sidebars in the UI so they match the prefs.
  // If placement of one/both affected sidebars is open, closes then reopens the affected bar(s) with the new placement.
  func updateSidebarPlacements() {
    let leadingSidebar = currentLayout.leadingSidebar.clone(placement: Preference.enum(for: .leadingSidebarPlacement))
    let trailingSidebar = currentLayout.trailingSidebar.clone(placement: Preference.enum(for: .trailingSidebarPlacement))

    guard currentLayout.leadingSidebarPlacement != leadingSidebar.placement ||
            currentLayout.trailingSidebarPlacement != trailingSidebar.placement else {
      return
    }

    let newLayoutSpec = currentLayout.spec.clone(leadingSidebar: leadingSidebar, trailingSidebar: trailingSidebar)
    let transition = buildLayoutTransition(to: newLayoutSpec)
    animationQueue.run(transition.animationTasks)
  }

  /// Hides all visible sidebars
  func hideAllSidebars(animate: Bool = true) {
    Logger.log("Hiding all sidebars", level: .verbose, subsystem: player.subsystem)

    let layout = currentLayout
    let newLayoutSpec = layout.spec.clone(leadingSidebar: layout.leadingSidebar.clone(visibility: .hide),
                                          trailingSidebar: layout.trailingSidebar.clone(visibility: .hide))
    let transition = buildLayoutTransition(to: newLayoutSpec)
    
    if animate {
      animationQueue.run(transition.animationTasks)
    } else {
      UIAnimation.disableAnimation{
        animationQueue.run(transition.animationTasks)
      }
    }
  }

  /// Shows or hides visibility of given `tab`. If the affected sidebar is showing the wrong `tabGroup`, it will be first be
  /// hidden/closed and then shown again the the correct `tabGroup` & `tab`. Will do nothing if already showing the given `tab`.
  private func changeVisibility(forTab tab: Sidebar.Tab, to shouldShow: Bool, then doAfter: TaskFunc? = nil) {
    guard !isInInteractiveMode else { return }
    Logger.log("Changing visibility of sidebar for tab \(tab.name.quoted) to: \(shouldShow ? "SHOW" : "HIDE")",
               level: .verbose, subsystem: player.subsystem)

    let newVisibilty: Sidebar.Visibility = shouldShow ? .show(tabToShow: tab) : .hide
    let currentLayout = currentLayout

    var leadingSidebar: Sidebar = currentLayout.leadingSidebar
    var trailingSidebar: Sidebar = currentLayout.trailingSidebar
    if leadingSidebar.tabGroups.contains(tab.group) {
      leadingSidebar = leadingSidebar.clone(visibility: newVisibilty)
      trailingSidebar = currentLayout.trailingSidebar
    } else if trailingSidebar.tabGroups.contains(tab.group) {
      leadingSidebar = currentLayout.leadingSidebar
      trailingSidebar = trailingSidebar.clone(visibility: newVisibilty)
    }

    let newLayoutSpec = currentLayout.spec.clone(leadingSidebar: leadingSidebar, trailingSidebar: trailingSidebar)
    let transition = buildLayoutTransition(to: newLayoutSpec)
    animationQueue.run(transition.animationTasks)
  }

  func animateShowOrHideSidebars(layout: LayoutPlan,
                                 setLeadingTo leadingGoal: Sidebar.Visibility? = nil,
                                 setTrailingTo trailingGoal: Sidebar.Visibility? = nil) {
    guard leadingGoal != nil || trailingGoal != nil else { return }
    let leadingSidebar = layout.leadingSidebar
    let trailingSidebar = layout.trailingSidebar

    var ΔLeft: CGFloat = 0
    if let goal = leadingGoal {
      log.verbose("Setting leadingSidebar visibility to \(goal)")
      var shouldShow = false
      let sidebarWidth: CGFloat
      switch goal {
      case .show(let tabToShow):
        sidebarWidth = tabToShow.group.width()
        shouldShow = true
      case .hide:
        if let lastVisibleTab = leadingSidebar.lastVisibleTab {
          sidebarWidth = lastVisibleTab.group.width()
        } else {
          Logger.log("Failed to find lastVisibleTab for leadingSidebar", level: .error, subsystem: player.subsystem)
          sidebarWidth = 0
        }
      }
      updateLeadingSidebarWidth(to: sidebarWidth, show: shouldShow, placement: leadingSidebar.placement)
      if leadingSidebar.placement == .outsideVideo {
        leadingSidebarTrailingBorder.isHidden = !shouldShow
        ΔLeft = shouldShow ? sidebarWidth : -sidebarWidth
      }
    }

    var ΔRight: CGFloat = 0
    if let goal = trailingGoal {
      log.verbose("Setting trailingSidebar visibility to \(goal)")
      var shouldShow = false
      let sidebarWidth: CGFloat
      switch goal {
      case .show(let tabToShow):
        sidebarWidth = tabToShow.group.width()
        shouldShow = true
      case .hide:
        if let lastVisibleTab = trailingSidebar.lastVisibleTab {
          sidebarWidth = lastVisibleTab.group.width()
        } else {
          Logger.log("Failed to find lastVisibleTab for trailingSidebar", level: .error, subsystem: player.subsystem)
          sidebarWidth = 0
        }
      }
      updateTrailingSidebarWidth(to: sidebarWidth, show: shouldShow, placement: trailingSidebar.placement)
      if trailingSidebar.placement == .outsideVideo {
        trailingSidebarLeadingBorder.isHidden = !shouldShow
        ΔRight = shouldShow ? sidebarWidth : -sidebarWidth
      }
    }

    if !currentLayout.isFullScreen && (ΔLeft != 0 || ΔRight != 0) {
      let oldGeometry = buildGeometryFromCurrentLayout()
      // Try to ensure that outside panels open or close outwards (as long as there is horizontal space on the screen)
      // so that ideally the video doesn't move or get resized. When opening, (1) use all available space in that direction.
      // and (2) if more space is still needed, expand the window in that direction, maintaining video size; and (3) if completely
      // out of screen width, shrink the video until it fits, while preserving its aspect ratio.
      let newGeometry = oldGeometry.resizeOutsideBars(newTrailingWidth: oldGeometry.trailingBarWidth + ΔRight,
                                                      newLeadingWidth: oldGeometry.leadingBarWidth + ΔLeft)
      let newWindowFrame = newGeometry.constrainWithin(bestScreen.visibleFrame).windowFrame

      Logger.log("Calling setFrame() from animateShowOrHideSidebars. ΔLeft: \(ΔLeft), ΔRight: \(ΔRight)",
                 level: .debug, subsystem: player.subsystem)
      (window as! MainWindow).setFrameImmediately(newWindowFrame)
    }
    updateSpacingForTitleBarAccessories(layout)
    updateSidebarVerticalConstraints(layout: layout)
    window?.contentView?.layoutSubtreeIfNeeded()
  }

  /// Execute this prior to opening `leadingSidebar` to the given tab.
  func prepareLayoutForOpening(leadingSidebar: Sidebar) {
    guard let window = window else { return }
    let tabToShow: Sidebar.Tab = leadingSidebar.visibleTab!

    // - Remove old:
    for constraint in [videoContainerLeadingOffsetFromLeadingSidebarTrailingConstraint,
                       videoContainerLeadingOffsetFromLeadingSidebarLeadingConstraint,
                       videoContainerLeadingToLeadingSidebarCropTrailingConstraint] {
      if let constraint = constraint {
        window.contentView?.removeConstraint(constraint)
      }
    }

    for subview in leadingSidebarView.subviews {
      // remove cropView without keeping a reference to it
      if subview != leadingSidebarTrailingBorder {
        subview.removeFromSuperview()
      }
    }

    // - Add new:
    let sidebarWidth = tabToShow.group.width()
    let tabContainerView: NSView

    if leadingSidebar.placement == .insideVideo {
      tabContainerView = leadingSidebarView
    } else {
      assert(leadingSidebar.placement == .outsideVideo)
      let cropView = NSView()
      cropView.identifier = NSUserInterfaceItemIdentifier(rawValue: "leadingSidebarCropView")
      leadingSidebarView.addSubview(cropView, positioned: .below, relativeTo: leadingSidebarTrailingBorder)
      cropView.translatesAutoresizingMaskIntoConstraints = false
      // Cling to superview for all sides but trailing:
      cropView.leadingAnchor.constraint(equalTo: leadingSidebarView.leadingAnchor).isActive = true
      cropView.topAnchor.constraint(equalTo: leadingSidebarView.topAnchor).isActive = true
      cropView.bottomAnchor.constraint(equalTo: leadingSidebarView.bottomAnchor).isActive = true
      tabContainerView = cropView

      // extra constraint for cropView:
      videoContainerLeadingToLeadingSidebarCropTrailingConstraint = videoContainerView.leadingAnchor.constraint(
        equalTo: leadingSidebarView.trailingAnchor, constant: 0)
      videoContainerLeadingToLeadingSidebarCropTrailingConstraint.isActive = true
    }

    let coefficients = getLeadingSidebarWidthCoefficients(show: false, placement: leadingSidebar.placement)

    videoContainerLeadingOffsetFromLeadingSidebarLeadingConstraint = videoContainerView.leadingAnchor.constraint(
      equalTo: tabContainerView.leadingAnchor, constant: coefficients.0 * sidebarWidth)
    videoContainerLeadingOffsetFromLeadingSidebarLeadingConstraint.isActive = true

    videoContainerLeadingOffsetFromLeadingSidebarTrailingConstraint = videoContainerView.leadingAnchor.constraint(
      equalTo: tabContainerView.trailingAnchor, constant: coefficients.1 * sidebarWidth)
    videoContainerLeadingOffsetFromLeadingSidebarTrailingConstraint.isActive = true

    prepareRemainingLayoutForOpening(sidebar: leadingSidebar, sidebarView: leadingSidebarView, tabContainerView: tabContainerView, tab: tabToShow)
  }

  /// Execute this prior to opening `trailingSidebar` to the given tab.
  func prepareLayoutForOpening(trailingSidebar: Sidebar) {
    guard let window = window else { return }
    let tabToShow: Sidebar.Tab = trailingSidebar.visibleTab!

    // - Remove old:
    for constraint in [videoContainerTrailingOffsetFromTrailingSidebarLeadingConstraint,
                       videoContainerTrailingOffsetFromTrailingSidebarTrailingConstraint,
                       videoContainerTrailingToTrailingSidebarCropLeadingConstraint] {
      if let constraint = constraint {
        window.contentView?.removeConstraint(constraint)
      }
    }

    for subview in trailingSidebarView.subviews {
      // remove cropView without keeping a reference to it
      if subview != trailingSidebarLeadingBorder {
        subview.removeFromSuperview()
      }
    }

    // - Add new:
    let sidebarWidth = tabToShow.group.width()
    let tabContainerView: NSView

    if trailingSidebar.placement == .insideVideo {
      tabContainerView = trailingSidebarView
    } else {
      assert(trailingSidebar.placement == .outsideVideo)
      let cropView = NSView()
      cropView.identifier = NSUserInterfaceItemIdentifier(rawValue: "trailingSidebarCropView")
      trailingSidebarView.addSubview(cropView, positioned: .below, relativeTo: trailingSidebarLeadingBorder)
      cropView.translatesAutoresizingMaskIntoConstraints = false
      // Cling to superview for all sides but leading:
      cropView.trailingAnchor.constraint(equalTo: trailingSidebarView.trailingAnchor).isActive = true
      cropView.topAnchor.constraint(equalTo: trailingSidebarView.topAnchor).isActive = true
      cropView.bottomAnchor.constraint(equalTo: trailingSidebarView.bottomAnchor).isActive = true
      tabContainerView = cropView

      // extra constraint for cropView:
      videoContainerTrailingToTrailingSidebarCropLeadingConstraint = videoContainerView.trailingAnchor.constraint(
        equalTo: trailingSidebarView.leadingAnchor, constant: 0)
      videoContainerTrailingToTrailingSidebarCropLeadingConstraint.isActive = true
    }

    let coefficients = getTrailingSidebarWidthCoefficients(show: false, placement: trailingSidebar.placement)

    videoContainerTrailingOffsetFromTrailingSidebarLeadingConstraint = videoContainerView.trailingAnchor.constraint(
      equalTo: tabContainerView.leadingAnchor, constant: coefficients.0 * sidebarWidth)
    videoContainerTrailingOffsetFromTrailingSidebarLeadingConstraint.isActive = true

    videoContainerTrailingOffsetFromTrailingSidebarTrailingConstraint = videoContainerView.trailingAnchor.constraint(
      equalTo: tabContainerView.trailingAnchor, constant: coefficients.1 * sidebarWidth)
    videoContainerTrailingOffsetFromTrailingSidebarTrailingConstraint.isActive = true

    prepareRemainingLayoutForOpening(sidebar: trailingSidebar, sidebarView: trailingSidebarView, tabContainerView: tabContainerView, tab: tabToShow)
  }

  /// Prepares those layout components which are generic for either `Sidebar`.
  /// Execute this prior to opening the given `Sidebar` with corresponding `sidebarView`
  private func prepareRemainingLayoutForOpening(sidebar: Sidebar, sidebarView: NSView, tabContainerView: NSView, tab: Sidebar.Tab) {
    Logger.log("ChangeVisibility pre-animation, show \(sidebar.locationID), \(tab.name.quoted) tab",
               level: .error, subsystem: player.subsystem)


    let viewController = (tab.group == .playlist) ? playlistView : quickSettingView
    let tabGroupView = viewController.view

    tabContainerView.addSubview(tabGroupView)
    tabGroupView.leadingAnchor.constraint(equalTo: tabContainerView.leadingAnchor).isActive = true
    tabGroupView.trailingAnchor.constraint(equalTo: tabContainerView.trailingAnchor).isActive = true
    tabGroupView.topAnchor.constraint(equalTo: tabContainerView.topAnchor).isActive = true
    tabGroupView.bottomAnchor.constraint(equalTo: tabContainerView.bottomAnchor).isActive = true

    sidebarView.isHidden = false

    // Update blending mode instantaneously. It doesn't animate well
    updateSidebarBlendingMode(sidebar.locationID, layout: self.currentLayout)

    // Make it the active tab in its parent tab group (can do this whether or not it's shown):
    switchToTabInTabGroup(tab: tab)

    window?.layoutIfNeeded()
  }

  /**
   For opening/closing `leadingSidebar` via constraints, multiply each times the sidebar width
   Correesponding to:
   (`videoContainerLeadingOffsetFromLeadingSidebarLeadingConstraint`,
   `videoContainerLeadingOffsetFromLeadingSidebarTrailingConstraint`,
   `videoContainerLeadingOffsetFromContentViewLeadingConstraint`)
   */
  private func getLeadingSidebarWidthCoefficients(show: Bool, placement: Preference.PanelPlacement) -> (CGFloat, CGFloat, CGFloat) {
    switch placement {
    case .insideVideo:
      if show {
        return (0, -1, 0)
      } else {
        return (1, 0, 0)
      }
    case .outsideVideo:
      if show {
        return (1, 0, 1)
      } else {
        if currentLayout.isFullScreen {
          return (1, 0, 0)
        } else {
          return (0, -1, 0)
        }
      }
    }
  }

  private func updateLeadingSidebarWidth(to newWidth: CGFloat, show: Bool, placement: Preference.PanelPlacement) {
    Logger.log("\(show ? "Showing" : "Hiding") leadingSidebar, width=\(newWidth) placement=\(placement)", level: .verbose, subsystem: player.subsystem)

    let coefficients = getLeadingSidebarWidthCoefficients(show: show, placement: placement)
    videoContainerLeadingOffsetFromLeadingSidebarLeadingConstraint.animateToConstant(coefficients.0 * newWidth)
    videoContainerLeadingOffsetFromLeadingSidebarTrailingConstraint.animateToConstant(coefficients.1 * newWidth)
    videoContainerLeadingOffsetFromContentViewLeadingConstraint.animateToConstant(coefficients.2 * newWidth)
  }

  /**
   For opening/closing `trailingSidebar` via constraints, multiply each times the sidebar width
   Correesponding to:
   (`videoContainerTrailingOffsetFromTrailingSidebarLeadingConstraint`,
   `videoContainerTrailingOffsetFromTrailingSidebarTrailingConstraint`,
   `videoContainerTrailingOffsetFromContentViewTrailingConstraint`)
   */
  private func getTrailingSidebarWidthCoefficients(show: Bool, placement: Preference.PanelPlacement) -> (CGFloat, CGFloat, CGFloat) {
    switch placement {
    case .insideVideo:
      if show {
        return (1, 0, 0)
      } else {
        return (0, -1, 0)
      }
    case .outsideVideo:
      if show {
        return (0, -1, -1)
      } else {
        if currentLayout.isFullScreen {
          return (0, -1, 0)
        } else {
          return (1, 0, 0)
        }
      }
    }
  }

  private func updateTrailingSidebarWidth(to newWidth: CGFloat, show: Bool, placement: Preference.PanelPlacement) {
    Logger.log("\(show ? "Showing" : "Hiding") trailingSidebar, width=\(newWidth) placement=\(placement)", level: .verbose, subsystem: player.subsystem)
    let coefficients = getTrailingSidebarWidthCoefficients(show: show, placement: placement)
    videoContainerTrailingOffsetFromTrailingSidebarLeadingConstraint.animateToConstant(coefficients.0 * newWidth)
    videoContainerTrailingOffsetFromTrailingSidebarTrailingConstraint.animateToConstant(coefficients.1 * newWidth)
    videoContainerTrailingOffsetFromContentViewTrailingConstraint.animateToConstant(coefficients.2 * newWidth)
  }

  // MARK: - Various functions

  func updateSidebarBlendingMode(_ sidebarID: Preference.SidebarLocation, layout: LayoutPlan) {
    switch sidebarID {
    case .leadingSidebar:
      // Fullscreen + "behindWindow" doesn't blend properly and looks ugly
      if layout.leadingSidebarPlacement == .insideVideo || layout.isFullScreen {
        leadingSidebarView.blendingMode = .withinWindow
      } else {
        leadingSidebarView.blendingMode = .behindWindow
      }
    case .trailingSidebar:
      if layout.trailingSidebarPlacement == .insideVideo || layout.isFullScreen {
        trailingSidebarView.blendingMode = .withinWindow
      } else {
        trailingSidebarView.blendingMode = .behindWindow
      }
    }
  }

  /// Make sure this is called AFTER `mainWindow.setupTitleBarAndOSC()` has updated its variables
  func updateSidebarVerticalConstraints(layout futureLayout: LayoutPlan? = nil) {
    let layout = futureLayout ?? currentLayout
    let downshift: CGFloat
    var tabHeight: CGFloat
    if player.isInMiniPlayer || (!layout.isFullScreen && layout.topBarPlacement == Preference.PanelPlacement.outsideVideo) {
      downshift = Constants.Sidebar.defaultDownshift
      tabHeight = Constants.Sidebar.defaultTabHeight
      log.verbose("MainWindow: using default downshift (\(downshift)) and tab height (\(tabHeight))")
    } else {
      // Downshift: try to match title bar height
      if layout.isFullScreen || layout.topBarPlacement == Preference.PanelPlacement.outsideVideo {
        downshift = Constants.Sidebar.defaultDownshift
      } else {
        // Need to adjust if has title bar
        downshift = MainWindowController.reducedTitleBarHeight
      }

      tabHeight = layout.topOSCHeight
      // Put some safeguards in place:
      if tabHeight <= Constants.Sidebar.minTabHeight || tabHeight > Constants.Sidebar.maxTabHeight {
        tabHeight = Constants.Sidebar.defaultTabHeight
      }
    }

    log.verbose("Sidebars downshift: \(downshift), tabHeight: \(tabHeight), fullScreen: \(layout.isFullScreen), topBar: \(layout.topBarPlacement)")
    quickSettingView.setVerticalConstraints(downshift: downshift, tabHeight: tabHeight)
    playlistView.setVerticalConstraints(downshift: downshift, tabHeight: tabHeight)
  }

  // For JavascriptAPICore:
  func isShowingSettingsSidebar() -> Bool {
    let layout = currentLayout
    return layout.leadingSidebar.visibleTabGroup == .settings || layout.trailingSidebar.visibleTabGroup == .settings
  }

  func isShowing(sidebarTab tab: Sidebar.Tab) -> Bool {
    let layout = currentLayout
    return layout.leadingSidebar.visibleTab == tab || layout.trailingSidebar.visibleTab == tab
  }

  func switchToTabInTabGroup(tab: Sidebar.Tab) {
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
  }

  // This is so that sidebar controllers can notify when they changed tabs in their tab groups, so that
  // the tracking information here can be updated.
  func didChangeTab(to tabName: String) {
    guard let tab = Sidebar.Tab(name: tabName) else {
      Logger.log("Could not find a matching sidebar tab for \(tabName.quoted)!", level: .error, subsystem: player.subsystem)
      return
    }

    let newVisibility = Sidebar.Visibility.show(tabToShow: tab)
    let layout = currentLayout
    var leadingSidebar: Sidebar? = nil
    var trailingSidebar: Sidebar? = nil
    if layout.leadingSidebar.tabGroups.contains(tab.group) {
      leadingSidebar = layout.leadingSidebar.clone(visibility: newVisibility)
    } else if layout.trailingSidebar.tabGroups.contains(tab.group) {
      trailingSidebar = layout.trailingSidebar.clone(visibility: newVisibility)
    }
    let newLayoutSpec = layout.spec.clone(leadingSidebar: leadingSidebar, trailingSidebar: trailingSidebar)
    let futureLayout = buildFutureLayoutPlan(from: newLayoutSpec)
    currentLayout = futureLayout
  }

  private func getConfiguredSidebar(forTabGroup tabGroup: Sidebar.TabGroup) -> Sidebar? {
    for sidebar in [currentLayout.leadingSidebar, currentLayout.trailingSidebar] {
      if sidebar.tabGroups.contains(tabGroup) {
        return sidebar
      }
    }
    Logger.log("No sidebar found for tab group \(tabGroup.rawValue.quoted)!", level: .error, subsystem: player.subsystem)
    return nil
  }

  // If location of tab group changed to another sidebar (in user prefs), check if it is showing, and if so, hide it & show it on the other side
  func moveTabGroup(_ tabGroup: Sidebar.TabGroup, toSidebarLocation newLocationID: Preference.SidebarLocation) {
    guard let currentLocationID = getConfiguredSidebar(forTabGroup: tabGroup)?.locationID else { return }
    guard currentLocationID != newLocationID else { return }

    let layout = currentLayout
    let leadingSidebar = layout.leadingSidebar
    var newLeadingTabGroups = leadingSidebar.tabGroups
    var newLeadingSidebarVisibility: Sidebar.Visibility = leadingSidebar.visibility
    let trailingSidebar = layout.trailingSidebar
    var newTrailingTabGroups = trailingSidebar.tabGroups
    var newTraillingSidebarVisibility: Sidebar.Visibility = trailingSidebar.visibility

    if newLocationID == .leadingSidebar {
      newLeadingTabGroups.insert(tabGroup)
      newTrailingTabGroups.remove(tabGroup)
      if trailingSidebar.visibleTabGroup == tabGroup && !leadingSidebar.isVisible {
        newTraillingSidebarVisibility = .hide
        newLeadingSidebarVisibility = trailingSidebar.visibility
      }
    }

    if newLocationID == .trailingSidebar {
      newTrailingTabGroups.insert(tabGroup)
      newLeadingTabGroups.remove(tabGroup)
      if leadingSidebar.visibleTabGroup == tabGroup && !trailingSidebar.isVisible {
        newLeadingSidebarVisibility = .hide
        newTraillingSidebarVisibility = leadingSidebar.visibility
      }
    }

    let newLayoutSpec = layout.spec.clone(
      leadingSidebar: leadingSidebar.clone(tabGroups: newLeadingTabGroups, visibility: newLeadingSidebarVisibility),
      trailingSidebar: trailingSidebar.clone(tabGroups: newTrailingTabGroups, visibility: newTraillingSidebarVisibility))
    let transition = buildLayoutTransition(to: newLayoutSpec)
    animationQueue.run(transition.animationTasks)
  }

  // MARK: - Mouse events

  func isMousePosWithinLeadingSidebarResizeRect(mousePositionInWindow: NSPoint) -> Bool {
    if currentLayout.leadingSidebar.visibleTabGroup == .playlist {
      let sf = leadingSidebarView.frame
      let dragRectCenterX: CGFloat = sf.origin.x + sf.width

      // FIXME: need to find way to resize from inside of sidebar
      let activationRect = NSRect(x: dragRectCenterX,
                                  y: sf.origin.y,
                                  width: Constants.Sidebar.resizeActivationRadius,
                                  height: sf.height)
      if NSPointInRect(mousePositionInWindow, activationRect) {
        return true
      }
    }
    return false
  }

  func isMousePosWithinTrailingSidebarResizeRect(mousePositionInWindow: NSPoint) -> Bool {
    if currentLayout.trailingSidebar.visibleTabGroup == .playlist {
      let sf = trailingSidebarView.frame
      let dragRectCenterX: CGFloat = sf.origin.x

      // FIXME: need to find way to resize from inside of sidebar
      let activationRect = NSRect(x: dragRectCenterX - Constants.Sidebar.resizeActivationRadius,
                                  y: sf.origin.y,
                                  width: Constants.Sidebar.resizeActivationRadius,
                                  height: sf.height)
      if NSPointInRect(mousePositionInWindow, activationRect) {
        return true
      }
    }
    return false
  }

  func startResizingSidebar(with event: NSEvent) -> Bool {
    if isMousePosWithinLeadingSidebarResizeRect(mousePositionInWindow: mousePosRelatedToWindow!) {
      Logger.log("User started resize of leading sidebar", level: .verbose, subsystem: player.subsystem)
      leadingSidebarIsResizing = true
      return true
    } else if isMousePosWithinTrailingSidebarResizeRect(mousePositionInWindow: mousePosRelatedToWindow!) {
      Logger.log("User started resize of trailing sidebar", level: .verbose, subsystem: player.subsystem)
      trailingSidebarIsResizing = true
      return true
    }
    return false
  }

  // Returns true if handled; false if not
  func resizeSidebar(with dragEvent: NSEvent) -> Bool {
    let currentLocation = dragEvent.locationInWindow
    let newWidth: CGFloat
    let newPlaylistWidth: CGFloat
    let layout = currentLayout

    if leadingSidebarIsResizing {
      switch layout.leadingSidebarPlacement {
      case .insideVideo:
        newWidth = currentLocation.x + 2
      case .outsideVideo:
        newWidth = currentLocation.x + 2
      }
      newPlaylistWidth = clampPlaylistWidth(newWidth)
      UIAnimation.disableAnimation {
        updateLeadingSidebarWidth(to: newPlaylistWidth, show: true, placement: layout.leadingSidebarPlacement)
      }
    } else if trailingSidebarIsResizing {
      switch layout.trailingSidebarPlacement {
      case .insideVideo:
        newWidth = window!.frame.width - currentLocation.x - 2
      case .outsideVideo:
        newWidth = window!.frame.width - currentLocation.x - 2
      }
      newPlaylistWidth = clampPlaylistWidth(newWidth)
      UIAnimation.disableAnimation {
        updateTrailingSidebarWidth(to: newPlaylistWidth, show: true, placement: layout.trailingSidebarPlacement)
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
    if leadingSidebarIsResizing {
      // if it's a mouseup after resizing sidebar
      leadingSidebarIsResizing = false
      log.verbose("New width of left sidebar playlist is \(currentLayout.leadingSidebar.currentWidth)")
      return true
    } else if trailingSidebarIsResizing {
      // if it's a mouseup after resizing sidebar
      trailingSidebarIsResizing = false
      log.verbose("New width of right sidebar playlist is \(currentLayout.trailingSidebar.currentWidth)")
      return true
    }
    return false
  }

  func hideSidebarsOnClick() -> Bool {
    let layout = currentLayout
    let hideLeading = layout.leadingSidebar.isVisible && Preference.bool(for: .hideLeadingSidebarOnClick)
    let hideTrailing = layout.trailingSidebar.isVisible && Preference.bool(for: .hideTrailingSidebarOnClick)

    if hideLeading || hideTrailing {
      let newLayoutSpec = layout.spec.clone(leadingSidebar: hideLeading ? layout.leadingSidebar.clone(visibility: .hide) : nil,
                                            trailingSidebar: hideTrailing ? layout.trailingSidebar.clone(visibility: .hide) : nil)
      let transition = buildLayoutTransition(to: newLayoutSpec)
      animationQueue.run(transition.animationTasks)
      return true
    }
    return false
  }
}

// MARK: - SidebarTabGroupViewController

protocol SidebarTabGroupViewController {
  var mainWindow: MainWindowController! { get }
  var customTabHeight: CGFloat? { get }

  // Implementing classes need to define this
  func setVerticalConstraints(downshift: CGFloat, tabHeight: CGFloat)
}

extension SidebarTabGroupViewController {
  var customTabHeight: CGFloat? { return nil }
}
