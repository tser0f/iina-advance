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
fileprivate let sidebarResizeActivationRadius = 10.0

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

    guard let destinationSidebar = getConfiguredSidebar(forTabGroup: tab.group) else { return }

    if destinationSidebar.visibleTab == tab && hideIfAlreadyShown {
      changeVisibility(forTab: tab, to: false)
      return
    }

    // This will change the sidebar to the displayed tab group if needed:
    changeVisibility(forTab: tab, to: true)
  }

  // Hides any visible sidebars
  func hideAllSidebars(animate: Bool = true, then doAfter: TaskFunc? = nil) {
    Logger.log("Hiding all sidebars", level: .verbose, subsystem: player.subsystem)

    changeVisibilityForSidebars(changeLeading: true, leadingVisible: false,
                                changeTrailing: true, trailingVisibile: false,
                                then: doAfter)
  }

  func hideSidebarThenShowAgain(_ sidebarID: Preference.SidebarLocation) {
    guard let sidebar = sidebarsByID[sidebarID], let tab = sidebar.visibleTab else { return }
    changeVisibility(forTab: tab, to: false, then: {
      self.changeVisibility(forTab: tab, to: true)
    })
  }

  private func changeVisibility(forTab tab: SidebarTab, to show: Bool, then doAfter: TaskFunc? = nil) {
    guard !isInInteractiveMode else { return }
    Logger.log("Changing visibility of sidebar for tab \(tab.name.quoted) to: \(show ? "SHOW" : "HIDE")",
               level: .verbose, subsystem: player.subsystem)

    let group = tab.group
    guard let sidebar = getConfiguredSidebar(forTabGroup: group) else { return }

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

    if nothingToDo {
      return
    }

    let tabGroup = tab.group
    if leadingSidebar.tabGroups.contains(tabGroup) {
      changeVisibilityForSidebars(changeLeading: true, leadingVisible: show, setLeadingTab: tab, then: doAfter)
    } else if trailingSidebar.tabGroups.contains(tabGroup) {
      changeVisibilityForSidebars(changeTrailing: true, trailingVisibile: show, setTrailingTab: tab, then: doAfter)
    } else {
      // Should never happen
      Logger.log("Cannot change sidebar tab visibility: could not find tab for tabGroup: \(tabGroup.rawValue)", level: .error, subsystem: player.subsystem)
    }
  }

  /**
   In one case it is desired to closed both sidebars simultaneously. To do this safely, we need to add logic for both sidebars
   to each animation block.
   */
  private func changeVisibilityForSidebars(changeLeading: Bool = false, leadingVisible: Bool = false, setLeadingTab: SidebarTab? = nil,
                                           changeTrailing: Bool = false, trailingVisibile: Bool = false, setTrailingTab: SidebarTab? = nil,
                                           then doAfter: TaskFunc? = nil) {
    var animationTasks: [UIAnimation.Task] = []

    let leadingTab = setLeadingTab ?? leadingSidebar.defaultTabToShow
    assert(!changeLeading || !leadingVisible || leadingTab != nil, "changeVisibilityForSidebars: invalid config for leading sidebar!")
    let trailingTab = setTrailingTab ?? trailingSidebar.defaultTabToShow
    assert(!changeTrailing || !trailingVisibile || trailingTab != nil, "changeVisibilityForSidebars: invalid config for trailing sidebar!")
    Logger.log("Changing visible state of sidebars. Leading:(change=\(changeLeading),visible=\(leadingVisible),tab=\(leadingTab != nil)), Trailing:(change=\(changeTrailing),visible=\(trailingVisibile),tab=\(trailingTab != nil)", level: .verbose, subsystem: player.subsystem)

    // Task 1: Needs to be in an animation task to make sure precedence rules are followed. But there is no visible animation.
    animationTasks.append(UIAnimation.zeroDurationTask { [self] in
      if let leadingTab = leadingTab, changeLeading {
        executeChangeVisibilityTask1(forSidebar: leadingSidebar, tab: leadingTab, targetVisibility: leadingVisible)
      }
      if let trailingTab = trailingTab, changeTrailing {
        executeChangeVisibilityTask1(forSidebar: trailingSidebar, tab: trailingTab, targetVisibility: trailingVisibile)
      }
    })

    // Task 2: Animate the showing/hiding:
    animationTasks.append(UIAnimation.Task(duration: UIAnimation.DefaultDuration, timingFunction: CAMediaTimingFunction(name: .easeIn),
                                           { [self] in

      guard let window = window else { return }

      var ΔLeft: CGFloat = 0
      if let leadingTab = leadingTab, changeLeading {
        let currentWidth = leadingTab.group.width()
        updateLeadingSidebarWidth(to: currentWidth, show: leadingVisible, placement: leadingSidebar.placement)
        if leadingSidebar.placement == .outsideVideo {
          ΔLeft = leadingVisible ? currentWidth : -currentWidth
        }
        /// Must set this for `updateSpacingForTitleBarAccessories()` to work properly
        leadingSidebar.animationState = leadingVisible ? .willShow : .willHide
      }

      var ΔRight: CGFloat = 0
      if let trailingTab = trailingTab, changeTrailing {
        let currentWidth = trailingTab.group.width()
        updateTrailingSidebarWidth(to: currentWidth, show: trailingVisibile, placement: trailingSidebar.placement)
        if trailingSidebar.placement == .outsideVideo {
          ΔRight = trailingVisibile ? currentWidth : -currentWidth
        }
        /// Must set this for `updateSpacingForTitleBarAccessories()` to work properly
        trailingSidebar.animationState = trailingVisibile ? .willShow : .willHide
      }

      if ΔLeft != 0 || ΔRight != 0 {
        // Try to ensure that outside panels open or close outwards (as long as there is horizontal space on the screen)
        // so that ideally the video doesn't move or get resized. When opening, (1) use all available space in that direction.
        // and (2) if more space is still needed, expand the window in that direction, maintaining video size; and (3) if completely
        // out of screen width, shrink the video until it fits, while preserving its aspect ratio.
        let oldScaleFrame = buildScalableFrame()
        let newScaleFrame = oldScaleFrame.resizeOutsidePanels(newRightWidth: oldScaleFrame.rightPanelWidth + ΔRight,
                                                              newLeftWidth: oldScaleFrame.leftPanelWidth + ΔLeft)
        let newWindowFrame = newScaleFrame.constrainWithin(bestScreen.visibleFrame).windowFrame

        window.setFrame(newWindowFrame, display: true, animate: true)
      }
      updateSpacingForTitleBarAccessories()
      window.contentView?.layoutSubtreeIfNeeded()
    }))

    // Task 3: Finish up state changes:
    animationTasks.append(UIAnimation.zeroDurationTask { [self] in
      if let leadingTab = leadingTab, changeLeading {
        executeChangeVisibilityTask3(forSidebar: leadingSidebar, sidebarView: leadingSidebarView, tab: leadingTab, targetVisibility: leadingVisible)
      }
      if let trailingTab = trailingTab, changeTrailing {
        executeChangeVisibilityTask3(forSidebar: trailingSidebar, sidebarView: trailingSidebarView, tab: trailingTab, targetVisibility: trailingVisibile)
      }
    })

    if let doAfter = doAfter {
      animationTasks.append(UIAnimation.zeroDurationTask {
        doAfter()
      })
    }
    animationQueue.run(animationTasks)
  }

  // Task 1: pre-animation
  private func executeChangeVisibilityTask1(forSidebar sidebar: Sidebar, tab: SidebarTab, targetVisibility show: Bool) {
    if show {

      // Update blending mode instantaneously. It doesn't animate well
      updateSidebarBlendingMode(sidebar.locationID, layout: self.currentLayout)

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

      let sidebarView: NSView
      switch sidebar.locationID {
      case .leadingSidebar:
        leadingSidebar.placement = Preference.enum(for: .leadingSidebarPlacement)
        sidebarView = leadingSidebarView
      case .trailingSidebar:
        trailingSidebar.placement = Preference.enum(for: .trailingSidebarPlacement)
        sidebarView = trailingSidebarView
      }

      sidebarView.isHidden = false

      // add view and constraints
      let viewController = (tab.group == .playlist) ? playlistView : quickSettingView
      let tabGroupView = viewController.view
      sidebarView.addSubview(tabGroupView)
      tabGroupView.heightAnchor.constraint(equalTo: sidebarView.heightAnchor).isActive = true
      tabGroupView.widthAnchor.constraint(equalTo: sidebarView.widthAnchor).isActive = true
    }
    
    Logger.log("Pre-animation: intent is to \(show ? "show " : "hide ") \(sidebar.locationID)", level: .verbose, subsystem: player.subsystem)
  }

  /// Task 3: post-animation
  /// `sidebarView` should correspond to same side as `sidebar`
  private func executeChangeVisibilityTask3(forSidebar sidebar: Sidebar, sidebarView: NSView, tab: SidebarTab, targetVisibility show: Bool) {
    if show {
      sidebar.animationState = .shown
      sidebar.visibleTab = tab
    } else {  // hide
      sidebar.visibleTab = nil
      sidebarView.subviews.removeAll()
      sidebarView.isHidden = true
      sidebar.animationState = .hidden
    }
    Logger.log("Animation done: changed animationState of \(sidebar.locationID) to: \(sidebar.animationState)", level: .verbose, subsystem: player.subsystem)
  }

  func updateSidebarBlendingMode(_ sidebarID: Preference.SidebarLocation, layout: LayoutPlan) {
    switch sidebarID {
    case .leadingSidebar:
      // Fullscreen + "behindWindow" doesn't blend properly and looks ugly
      if Preference.enum(for: .leadingSidebarPlacement) == Preference.PanelPlacement.insideVideo || layout.isFullScreen {
        leadingSidebarView.blendingMode = .withinWindow
      } else {
        leadingSidebarView.blendingMode = .behindWindow
      }
    case .trailingSidebar:
      if Preference.enum(for: .trailingSidebarPlacement) == Preference.PanelPlacement.insideVideo || layout.isFullScreen {
        trailingSidebarView.blendingMode = .withinWindow
      } else {
        trailingSidebarView.blendingMode = .behindWindow
      }
    }
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
      // FIXME: add superview for sidebars
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

  func isMousePosWithinLeadingSidebarResizeRect(mousePositionInWindow: NSPoint) -> Bool {
    if leadingSidebar.visibleTab == .playlist {
      let sf = leadingSidebarView.frame
      let dragRectCenterX: CGFloat = sf.origin.x + sf.width

      // FIXME: need to find way to resize from inside of sidebar
      let activationRect = NSMakeRect(dragRectCenterX, sf.origin.y, sidebarResizeActivationRadius, sf.height)
      if NSPointInRect(mousePositionInWindow, activationRect) {
        return true
      }
    }
    return false
  }

  func isMousePosWithinTrailingSidebarResizeRect(mousePositionInWindow: NSPoint) -> Bool {
    if trailingSidebar.visibleTab == .playlist {
      let sf = trailingSidebarView.frame
      let dragRectCenterX: CGFloat = sf.origin.x

      // FIXME: need to find way to resize from inside of sidebar
      let activationRect = NSMakeRect(dragRectCenterX - sidebarResizeActivationRadius, sf.origin.y, sidebarResizeActivationRadius, sf.height)
      if NSPointInRect(mousePositionInWindow, activationRect) {
        return true
      }
    }
    return false
  }

  func startResizingSidebar(with event: NSEvent) {
    if isMousePosWithinLeadingSidebarResizeRect(mousePositionInWindow: mousePosRelatedToWindow!) {
      Logger.log("User started resize of leading sidebar", level: .verbose, subsystem: player.subsystem)
      leadingSidebar.isResizing = true
    } else if isMousePosWithinTrailingSidebarResizeRect(mousePositionInWindow: mousePosRelatedToWindow!) {
      Logger.log("User started resize of trailing sidebar", level: .verbose, subsystem: player.subsystem)
      trailingSidebar.isResizing = true
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

protocol SidebarTabGroupViewController {
  var mainWindow: MainWindowController! { get }
  var customTabHeight: CGFloat? { get }

  // Implementing classes need to define this
  func setVerticalConstraints(downshift: CGFloat, tabHeight: CGFloat)
}

extension SidebarTabGroupViewController {

  var customTabHeight: CGFloat? { return nil }
}
