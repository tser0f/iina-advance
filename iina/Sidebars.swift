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

  /** Type of the view embedded in sidebar. */
  enum SidebarTabGroup: String {
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

    /// The currently visible tab, if sidebar is open/visible. Is `nil` if sidebar is closed/hidden.
    /// Use `lastVisibleTab` if the last shown tab needs to be known.
    var visibleTab: SidebarTab? {
      get {
        return isVisible ? lastVisibleTab : nil
      }
      set {
        if let tab = newValue {
          lastVisibleTab = tab
        }
      }
    }

    /// Tab group of `visibleTab`
    var visibleTabGroup: SidebarTabGroup? {
      return visibleTab?.group
    }

    var isVisible: Bool {
      return animationState == .shown
    }

    /// Returns `0` if sidebar is hidden.
    var currentWidth: CGFloat {
      guard isVisible else { return 0 }
      return visibleTabGroup?.width() ?? 0
    }

    /// Returns `0` if sidebar is hidden.
    var currentOutsideWidth: CGFloat {
      return placement == .outsideVideo ? currentWidth : 0
    }

    var lastVisibleTab: SidebarTab? = nil

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
      Logger.log("No tab groups found for \(locationID), returning nil for defaultTab", level: .verbose)
      return nil
    }
  }

  // MARK: - Changing visibility

  private enum VisibilityGoal {
    case show(tabToShow: SidebarTab)
    case hide
  }

  @IBAction func toggleLeadingSidebarVisibility(_ sender: NSButton) {
    toggleVisibility(of: leadingSidebar)
  }

  @IBAction func toggleTrailingSidebarVisibility(_ sender: NSButton) {
    toggleVisibility(of: trailingSidebar)
  }

  func toggleVisibility(of sidebar: Sidebar) {
    Logger.log("Toggling visibility of sidebar: \(sidebar.locationID) (animationState: \(sidebar.animationState), isVisible: \(sidebar.isVisible))",
               level: .verbose, subsystem: player.subsystem)
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

  // Hides any visible sidebars
  func hideAllSidebars(animate: Bool = true, then doAfter: TaskFunc? = nil) {
    Logger.log("Hiding all sidebars", level: .verbose, subsystem: player.subsystem)

    changeVisibilityForSidebars(setLeadingTo: .hide, setTrailingTo: .hide, then: doAfter)
  }

  // Updates placements (inside or outside) of both sidebars in the UI so they match the prefs.
  // If placement of one/both sidebars change while open, closes & reopens the affected sidebars with the new placement.
  func updateSidebarPlacements() {
    let leadingPlacementNew: Preference.PanelPlacement = Preference.enum(for: .leadingSidebarPlacement)
    let needLeadingReopen = leadingSidebar.isVisible && leadingSidebar.placement != leadingPlacementNew
    let leadingVisibleTab: SidebarTab? = leadingSidebar.visibleTab

    let trailingPlacementNew: Preference.PanelPlacement = Preference.enum(for: .trailingSidebarPlacement)
    let needTrailingReopen = trailingSidebar.isVisible && trailingSidebar.placement != trailingPlacementNew
    let trailingVisibleTab: SidebarTab? = trailingSidebar.visibleTab

    changeVisibilityForSidebars(setLeadingTo: needLeadingReopen ? .hide : nil,
                                setTrailingTo: needTrailingReopen ? .hide : nil, then: { [self] in
      leadingSidebar.placement = leadingPlacementNew
      trailingSidebar.placement = trailingPlacementNew

      if needLeadingReopen || needTrailingReopen {
        let leadingGoal = needLeadingReopen && leadingVisibleTab == nil ? nil : VisibilityGoal.show(tabToShow: leadingVisibleTab!)
        let trailingGoal = needTrailingReopen && trailingVisibleTab == nil ? nil : VisibilityGoal.show(tabToShow: trailingVisibleTab!)
        changeVisibilityForSidebars(setLeadingTo: leadingGoal, setTrailingTo: trailingGoal)
      }
    })
  }

  private func changeVisibility(forTab tab: SidebarTab, to shouldShow: Bool, then doAfter: TaskFunc? = nil) {
    guard !isInInteractiveMode else { return }
    Logger.log("Changing visibility of sidebar for tab \(tab.name.quoted) to: \(shouldShow ? "SHOW" : "HIDE")",
               level: .verbose, subsystem: player.subsystem)

    let group = tab.group
    guard let sidebar = getConfiguredSidebar(forTabGroup: group) else { return }

    var nothingToDo = false
    if shouldShow && sidebar.isVisible {
      guard let visibleTab = sidebar.visibleTab else {
        Logger.log("Internal error setting tab group for sidebar \(sidebar.locationID)",
                   level: .error, subsystem: player.subsystem)
        return
      }
      if visibleTab.group != group {
        // If tab is showing but with wrong tab group, hide it, then change it, then show again
        Logger.log("Need to change tab group for \(sidebar.locationID): will hide & re-show sidebar",
                   level: .verbose, subsystem: player.subsystem)
        changeVisibility(forTab: visibleTab, to: false, then: {
          self.changeVisibility(forTab: tab, to: true, then: doAfter)
        })
        return
      } else if visibleTab == tab {
        Logger.log("Nothing to do; \(sidebar.locationID) is already showing tab \(visibleTab.name.quoted)",
                   level: .verbose, subsystem: player.subsystem)
        nothingToDo = true
      }
    } else if !shouldShow && !sidebar.isVisible {
      // Just need to change tab in tab group. Fall through
      Logger.log("Nothing to do; \(sidebar.locationID) (which contains tab \(tab.name.quoted)) is already hidden",
                 level: .verbose, subsystem: player.subsystem)
      nothingToDo = true
    }

    if nothingToDo {
      if let doAfter = doAfter {
        animationQueue.run(UIAnimation.zeroDurationTask {
          doAfter()
        })
      }
      return
    }

    let visibilityGoal: VisibilityGoal = shouldShow ? .show(tabToShow: tab) : .hide

    let tabGroup = tab.group
    if leadingSidebar.tabGroups.contains(tabGroup) {
      changeVisibilityForSidebars(setLeadingTo: visibilityGoal, then: doAfter)
    } else if trailingSidebar.tabGroups.contains(tabGroup) {
      changeVisibilityForSidebars(setTrailingTo: visibilityGoal, then: doAfter)
    } else {
      // Should never happen
      Logger.log("Cannot change sidebar tab visibility: could not find tab for tabGroup: \(tabGroup.rawValue)", level: .error, subsystem: player.subsystem)
    }
  }

  /**
   In one case it is desired to closed both sidebars simultaneously. To do this safely, we need to add logic for both sidebars
   to each animation block.
   */
  private func changeVisibilityForSidebars(setLeadingTo: VisibilityGoal? = nil,
                                           setTrailingTo: VisibilityGoal? = nil,
                                           then doAfter: TaskFunc? = nil) {
    guard let window = window else { return }

    var leadingGoal = setLeadingTo
    var trailingGoal = setTrailingTo
    Logger.log("Changing visibility of sidebars: \(leadingGoal == nil ? "" : "Leading:[\(leadingGoal!), \(leadingSidebar.placement)]" ) \(trailingGoal == nil ? "" : "Trailing:[\(trailingGoal!), \(trailingSidebar.placement)]")", level: .verbose, subsystem: player.subsystem)

    var animationTasks: [UIAnimation.Task] = []

    // Task 1: No visible animation, but if opening the sidebar, need to modify layout
    // (will be very different for "insideVideo" vs "outsideVideo" placement)
    animationTasks.append(UIAnimation.zeroDurationTask { [self] in
      // Leading
      if let goal = leadingGoal {
        switch goal {
        case .show(let tabToShow):
          if let visibleTab = leadingSidebar.visibleTab {
            if tabToShow == visibleTab {
              Logger.log("Skipping \(goal) leadingSidebar: it is in state \(leadingSidebar.animationState)", level: .debug, subsystem: player.subsystem)
              leadingGoal = nil
            } else if tabToShow.group == visibleTab.group {
              // Tab group is already showing, but just need to switch tab
              switchToTabInTabGroup(tab: tabToShow)
              // no further work needed
              leadingGoal = nil
            }
          }
          if leadingGoal != nil {
            prepareLayoutForOpeningLeadingSidebar(toTab: tabToShow)
            leadingSidebar.animationState = .willShow
          }
        case .hide:
          if leadingSidebar.animationState == .shown {
            leadingSidebar.animationState = .willHide
          } else {
            leadingGoal = nil
            Logger.log("Skipping \(goal) leadingSidebar: it is in state \(leadingSidebar.animationState)", level: .debug, subsystem: player.subsystem)
          }
        }
      }

      // Trailing
      if let goal = trailingGoal {
        switch goal {
        case .show(let tabToShow):
          if let visibleTab = trailingSidebar.visibleTab {
            if tabToShow == visibleTab {
              Logger.log("Skipping \(goal) trailingSidebar; it is in state \(trailingSidebar.animationState)", level: .debug, subsystem: player.subsystem)
              trailingGoal = nil
            } else if tabToShow.group == visibleTab.group {
              // Tab group is already showing, but just need to switch tab
              switchToTabInTabGroup(tab: tabToShow)
              // no further work needed
              trailingGoal = nil
            }
          }
          if trailingGoal != nil {
            prepareLayoutForOpeningTrailingSidebar(toTab: tabToShow)
            trailingSidebar.animationState = .willShow
          }
        case .hide:
          if trailingSidebar.animationState == .shown {
            trailingSidebar.animationState = .willHide
          } else {
            trailingGoal = nil
            Logger.log("Skipping \(goal) trailingSidebar: it is in state \(leadingSidebar.animationState)", level: .debug, subsystem: player.subsystem)
          }
        }
      }
    })

    // Task 2: Animate the showing/hiding:
    animationTasks.append(UIAnimation.Task(duration: UIAnimation.DefaultDuration, timing: .easeIn, { [self] in

      var ΔLeft: CGFloat = 0
      if let goal = leadingGoal {
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
        let newGeometry = oldGeometry.resizeOutsideBars(newTrailingWidth: oldGeometry.rightBarWidth + ΔRight,
                                                          newLeadingWidth: oldGeometry.leftBarWidth + ΔLeft)
        let newWindowFrame = newGeometry.constrainWithin(bestScreen.visibleFrame).windowFrame

        Logger.log("Calling setFrame() from changeVisibilityForSidebars. ΔLeft: \(ΔLeft), ΔRight: \(ΔRight)",
                   level: .debug, subsystem: player.subsystem)
        (window as! MainWindow).setFrameImmediately(newWindowFrame)
      }
      updateSpacingForTitleBarAccessories()
      updateSidebarVerticalConstraints()
      window.contentView?.layoutSubtreeIfNeeded()
    }))

    // Task 3: Finish up state changes:
    animationTasks.append(UIAnimation.zeroDurationTask { [self] in

      if let goal = leadingGoal {
        changeVisibilityPostAnimation(forSidebar: leadingSidebar, sidebarView: leadingSidebarView, goal: goal)
      }
      if let goal = trailingGoal {
        changeVisibilityPostAnimation(forSidebar: trailingSidebar, sidebarView: trailingSidebarView, goal: goal)
      }
    })

    if let doAfter = doAfter {
      animationTasks.append(UIAnimation.zeroDurationTask {
        doAfter()
      })
    }
    animationQueue.run(animationTasks)
  }

  private func switchToTabInTabGroup(tab: SidebarTab) {
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

  /// Execute this prior to opening `leadingSidebar` to the given tab.
  private func prepareLayoutForOpeningLeadingSidebar(toTab leadingTabToShow: SidebarTab) {
    guard let window = window else { return }

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
    let sidebarWidth = leadingTabToShow.group.width()
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

    prepareLayoutForOpening(sidebar: leadingSidebar, sidebarView: leadingSidebarView, tabContainerView: tabContainerView, tab: leadingTabToShow)
  }

  /// Execute this prior to opening `trailingSidebar` to the given tab.
  private func prepareLayoutForOpeningTrailingSidebar(toTab trailingTabToShow: SidebarTab) {
    guard let window = window else { return }

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
    let sidebarWidth = trailingTabToShow.group.width()
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

    prepareLayoutForOpening(sidebar: trailingSidebar, sidebarView: trailingSidebarView, tabContainerView: tabContainerView, tab: trailingTabToShow)
  }

  /// Works for either `Sidebar`. Execute this prior to opening the given `Sidebar` with corresponding `sidebarView`
  private func prepareLayoutForOpening(sidebar: Sidebar, sidebarView: NSView, tabContainerView: NSView, tab: SidebarTab) {
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

    updateDepthOrderOfPanels(topBar: currentLayout.topBarPlacement, bottomBar: currentLayout.bottomBarPlacement,
                             leadingSidebar: leadingSidebar.placement, trailingSidebar: trailingSidebar.placement)

    // Update blending mode instantaneously. It doesn't animate well
    updateSidebarBlendingMode(sidebar.locationID, layout: self.currentLayout)

    // Make it the active tab in its parent tab group (can do this whether or not it's shown):
    switchToTabInTabGroup(tab: tab)

    window?.layoutIfNeeded()
  }

  /// Task 3: post-animation
  /// `sidebarView` should correspond to same side as `sidebar`
  private func changeVisibilityPostAnimation(forSidebar sidebar: Sidebar, sidebarView: NSView, goal: VisibilityGoal) {
    Logger.log("ChangeVisibility post-animation: finishing setting \(sidebar.locationID) to: \(goal)", level: .verbose, subsystem: player.subsystem)
    switch goal {
    case .show(let tabToShow):
      sidebar.animationState = .shown
      sidebar.visibleTab = tabToShow
    case .hide:
      if let visibleTab = sidebar.visibleTab {
        /// Remove `tabGroupView` from its parent (also removes constraints):
        let viewController = (visibleTab.group == .playlist) ? playlistView : quickSettingView
        viewController.view.removeFromSuperview()
      }
      sidebar.visibleTab = nil
      sidebarView.isHidden = true
      sidebar.animationState = .hidden
    }
  }

  func updateSidebarBlendingMode(_ sidebarID: Preference.SidebarLocation, layout: LayoutPlan) {
    switch sidebarID {
    case .leadingSidebar:
      // Fullscreen + "behindWindow" doesn't blend properly and looks ugly
      if leadingSidebar.placement == .insideVideo || layout.isFullScreen {
        leadingSidebarView.blendingMode = .withinWindow
      } else {
        leadingSidebarView.blendingMode = .behindWindow
      }
    case .trailingSidebar:
      if trailingSidebar.placement == .insideVideo || layout.isFullScreen {
        trailingSidebarView.blendingMode = .withinWindow
      } else {
        trailingSidebarView.blendingMode = .behindWindow
      }
    }
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

  // For JavascriptAPICore:
  func isShowingSettingsSidebar() -> Bool {
    return leadingSidebar.visibleTabGroup == .settings || trailingSidebar.visibleTabGroup == .settings
  }

  func isShowing(sidebarTab tab: SidebarTab) -> Bool {
    return leadingSidebar.visibleTab == tab || trailingSidebar.visibleTab == tab
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

      let reopenFunc: TaskFunc = {
        self.updateSidebarLocation(newLocationID, forTabGroup: tabGroup)
        self.changeVisibility(forTab: curentVisibleTab, to: true)
      }

      // Also close sidebar at new location if it is in the way.
      let closeBothSidebars = sidebarsByID[newLocationID]?.isVisible ?? false

      if closeBothSidebars {
        // Close both at the same time:
        changeVisibilityForSidebars(setLeadingTo: .hide, setTrailingTo: .hide, then: reopenFunc)
      } else {
        // Close sidebar at old location. Then reopen tab group at its new location:
        changeVisibility(forTab: curentVisibleTab, to: false, then: reopenFunc)
      }

    } else {
      Logger.log("Moving hidden tabGroup \(tabGroup.rawValue.quoted) from \(currentLocationID) to \(newLocationID)",
                 level: .verbose, subsystem: player.subsystem)
      self.updateSidebarLocation(newLocationID, forTabGroup: tabGroup)
    }
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

    // Sidebar buttons may have changed visibility:
    updateTitleBarAndOSC()
  }

  // MARK: - Mouse events

  func isMousePosWithinLeadingSidebarResizeRect(mousePositionInWindow: NSPoint) -> Bool {
    if leadingSidebar.visibleTab == .playlist {
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
    if trailingSidebar.visibleTab == .playlist {
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
      newPlaylistWidth = clampPlaylistWidth(newWidth)
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
      newPlaylistWidth = clampPlaylistWidth(newWidth)
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
    let hideLeading = leadingSidebar.isVisible && Preference.bool(for: .hideLeadingSidebarOnClick)
    let hideTrailing = trailingSidebar.isVisible && Preference.bool(for: .hideTrailingSidebarOnClick)

    if hideLeading || hideTrailing {
      changeVisibilityForSidebars(setLeadingTo: hideLeading ? .hide : nil,
                                  setTrailingTo: hideTrailing ? .hide : nil)
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
