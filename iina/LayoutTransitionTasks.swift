//
//  LayoutTransitionTasks.swift
//  iina
//
//  Created by Matt Svoboda on 10/4/23.
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

/// Fake title bar view. Manual reconstruction of title bar is needed when not using `titled` window style.
class FauxTitleBarView: NSStackView {
  var isMouseInside: Bool = false

  // Needed to get highlight working properly for traffic light buttons.
  // See: https://stackoverflow.com/a/30417372/1347529
  @objc func _mouseInGroup(_ button: NSButton) -> Bool {
    return isMouseInside
  }

  func markButtonsDirty() {
    for btn in views {
      btn.needsDisplay = true
    }
  }

  override func mouseEntered(with event: NSEvent) {
    isMouseInside = true
    markButtonsDirty()
  }

  override func mouseExited(with event: NSEvent) {
    isMouseInside = false
    markButtonsDirty()
  }

  @objc override var mouseDownCanMoveWindow: Bool {
    return true
  }
}


/// This file contains tasks to run in the animation queue, which form a `LayoutTransition`.
extension PlayerWindowController {

  func doPreTransitionWork(_ transition: LayoutTransition) {
    log.verbose("[\(transition.name)] DoPreTransitionWork")
    controlBarFloating.isDragging = false

    /// Some methods where reference `currentLayout` get called as a side effect of the transition animations.
    /// To avoid possible bugs as a result, let's update this at the very beginning.
    currentLayout = transition.outputLayout

    /// Set this here because we are setting `currentLayout`
    switch transition.outputLayout.mode {
    case .windowed:
      windowedModeGeometry = transition.outputGeometry
    case .musicMode:
      musicModeGeometry = musicModeGeometry.clone(windowFrame: transition.outputGeometry.windowFrame, videoAspectRatio: transition.outputGeometry.videoAspectRatio)
    case .fullScreen:
      // Not applicable when entering full screen
      break
    }

    guard let window = window else { return }

    if transition.isEnteringFullScreen {
      // Entering FullScreen
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

      if transition.isTogglingLegacyStyle {
        // Legacy fullscreen cannot handle transition while playing and will result in a black flash or jittering.
        // This will briefly freeze the video output, which is slightly better
        videoView.videoLayer.suspend()
      }

      if transition.outputLayout.isLegacyFullScreen {
        // stylemask
        log.verbose("Removing window styleMask.titled")
        if #available(macOS 10.16, *) {
          window.styleMask.remove(.titled)
          window.styleMask.insert(.borderless)
        } else {
          window.styleMask.insert(.fullScreen)
        }

        window.styleMask.remove(.resizable)

        // auto hide menubar and dock (this will freeze all other animations, so must do it last)
        NSApp.presentationOptions.insert(.autoHideMenuBar)
        NSApp.presentationOptions.insert(.autoHideDock)

        window.level = .iinaFloating
      }
      if !isClosing {
        player.mpv.setFlag(MPVOption.Window.fullscreen, true)
        // Let mpv decide the correct render region in full screen
        player.mpv.setFlag(MPVOption.Window.keepaspect, true)
      }

      resetViewsForFullScreenTransition()

    } else if transition.isExitingFullScreen {
      // Exiting FullScreen

      resetViewsForFullScreenTransition()

      apply(visibility: .hidden, to: additionalInfoView)

      if transition.isTogglingLegacyStyle {
        videoView.videoLayer.suspend()
      }
      // Hide traffic light buttons & title during the animation:
      hideBuiltInTitleBarItems()

      if !isClosing {
        player.mpv.setFlag(MPVOption.Window.fullscreen, false)
        player.mpv.setFlag(MPVOption.Window.keepaspect, false)
      }
    }
    if transition.isTogglingLegacyStyle {
      forceDraw()
    }
  }

  func fadeOutOldViews(_ transition: LayoutTransition) {
    let outputLayout = transition.outputLayout
    log.verbose("[\(transition.name)] FadeOutOldViews")

    // Title bar & title bar accessories:

    let needToHideTopBar = transition.isTopBarPlacementChanging || transition.isTogglingLegacyStyle

    // Hide all title bar items if top bar placement is changing
    if needToHideTopBar || outputLayout.titleIconAndText == .hidden {
      apply(visibility: .hidden, documentIconButton, titleTextField)
    }

    if needToHideTopBar || outputLayout.trafficLightButtons == .hidden {
      if let fakeLeadingTitleBarView = fakeLeadingTitleBarView {
        // legacy windowed mode
        fakeLeadingTitleBarView.alphaValue = 0
      } else {
        // native windowed or full screen
        for button in trafficLightButtons {
          button.alphaValue = 0
        }
      }
    }

    if needToHideTopBar, let fakeTrailingTitleBarView = fakeTrailingTitleBarView {
      fakeTrailingTitleBarView.alphaValue = 0
    }

    if needToHideTopBar || outputLayout.titlebarAccessoryViewControllers == .hidden {
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
      if outputLayout.leadingSidebarToggleButton == .hidden {
        leadingSidebarToggleButton.alphaValue = 0
        fadeableViewsTopBar.remove(leadingSidebarToggleButton)
      }
      if outputLayout.trailingSidebarToggleButton == .hidden {
        trailingSidebarToggleButton.alphaValue = 0
        fadeableViewsTopBar.remove(trailingSidebarToggleButton)
      }

      let pinToTopButtonVisibility = transition.outputLayout.computePinToTopButtonVisibility(isOnTop: isOntop)
      if pinToTopButtonVisibility == .hidden {
        pinToTopButton.alphaValue = 0
        fadeableViewsTopBar.remove(pinToTopButton)
      }
    }

    if transition.inputLayout.hasFloatingOSC && !outputLayout.hasFloatingOSC {
      // Hide floating OSC
      apply(visibility: outputLayout.controlBarFloating, to: controlBarFloating)
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

  func closeOldPanels(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let outputLayout = transition.outputLayout
    log.verbose("[\(transition.name)] CloseOldPanels: title_H=\(outputLayout.titleBarHeight), topOSC_H=\(outputLayout.topOSCHeight)")

    if transition.inputLayout.titleBarHeight > 0 && outputLayout.titleBarHeight == 0 {
      titleBarHeightConstraint.animateToConstant(0)
    }
    if transition.inputLayout.topOSCHeight > 0 && outputLayout.topOSCHeight == 0 {
      topOSCHeightConstraint.animateToConstant(0)
    }
    if transition.inputLayout.osdMinOffsetFromTop > 0 && outputLayout.osdMinOffsetFromTop == 0 {
      osdMinOffsetFromTopConstraint.animateToConstant(0)
    }

    // Update heights of top & bottom bars
    if let geo = transition.middleGeometry {
      let topBarHeight = transition.inputLayout.topBarPlacement == .insideViewport ? geo.insideTopBarHeight : geo.outsideTopBarHeight
      let cameraOffset: CGFloat
      if transition.isExitingLegacyFullScreen && transition.outputLayout.spec.isLegacyStyle {
        // Use prev offset for a smoother animation
        cameraOffset = transition.inputGeometry.topMarginHeight
      } else {
        cameraOffset = transition.outputGeometry.topMarginHeight
      }
      updateTopBarHeight(to: topBarHeight, topBarPlacement: transition.inputLayout.topBarPlacement, cameraHousingOffset: cameraOffset)

      if !transition.isExitingMusicMode {  // don't do this too soon when exiting Music Mode
        // Update sidebar vertical alignments to match top bar:
        let downshift = min(transition.inputLayout.sidebarDownshift, outputLayout.sidebarDownshift)
        let tabHeight = min(transition.inputLayout.sidebarTabHeight, outputLayout.sidebarTabHeight)
        updateSidebarVerticalConstraints(tabHeight: tabHeight, downshift: downshift)
      }

      let bottomBarHeight = transition.inputLayout.bottomBarPlacement == .insideViewport ? geo.insideBottomBarHeight : geo.outsideBottomBarHeight
      updateBottomBarHeight(to: bottomBarHeight, bottomBarPlacement: transition.inputLayout.bottomBarPlacement)

      // Update title bar item spacing to align with sidebars
      updateSpacingForTitleBarAccessories(transition.outputLayout, windowWidth: transition.outputGeometry.windowFrame.width)

      // Sidebars (if closing)
      animateShowOrHideSidebars(transition: transition, layout: transition.inputLayout,
                                setLeadingTo: transition.isHidingLeadingSidebar ? .hide : nil,
                                setTrailingTo: transition.isHidingTrailingSidebar ? .hide : nil)

      // Do not do this when first opening the window though, because it will cause the window location restore to be incorrect.
      // Also do not apply when toggling fullscreen because it is not relevant at this stage and will cause glitches in the animation.
      if !transition.isInitialLayout && !transition.isTogglingFullScreen {
        log.debug("Calling setFrame() from closeOldPanels with newWindowFrame \(geo.windowFrame)")
        player.window.setFrameImmediately(geo.windowFrame)
        videoView.updateSizeConstraints(geo.videoSize)
      }
    }

    if transition.isTogglingLegacyStyle {
      forceDraw()
    }
    window.contentView?.layoutSubtreeIfNeeded()
  }

  func updateHiddenViewsAndConstraints(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let outputLayout = transition.outputLayout
    log.verbose("[\(transition.name)] UpdateHiddenViewsAndConstraints")

    if transition.outputLayout.spec.isLegacyStyle {
      // Set legacy style
      setWindowStyleToLegacy()
      /// if `isTogglingLegacyStyle==true && isExitingFullScreen==true`, we are toggling out of legacy FS
      /// -> don't change `styleMask` to `.titled` here - it will look bad if screen has camera housing. Change at end of animation
    } else {
      // Not legacy style
      if !transition.isEnteringFullScreen {
        setWindowStyleToNative()
      }

      if transition.isExitingFullScreen {
        /// Setting `.titled` style will show buttons & title by default, but we don't want to show them until after panel open animation:
        hideBuiltInTitleBarViews()
      }
    }

    applyHiddenOnly(visibility: outputLayout.leadingSidebarToggleButton, to: leadingSidebarToggleButton)
    applyHiddenOnly(visibility: outputLayout.trailingSidebarToggleButton, to: trailingSidebarToggleButton)
    let pinToTopButtonVisibility = transition.outputLayout.computePinToTopButtonVisibility(isOnTop: isOntop)
    applyHiddenOnly(visibility: pinToTopButtonVisibility, to: pinToTopButton)

    if outputLayout.titleBar == .hidden || transition.isTopBarPlacementChanging {
      /// Note: MUST use `titleVisibility` to guarantee that `documentIcon` & `titleTextField` are shown/hidden consistently.
      /// Setting `isHidden=true` on `titleTextField` and `documentIcon` do not animate and do not always work.
      /// We can use `alphaValue=0` to fade out in `fadeOutOldViews()`, but `titleVisibility` is needed to remove them.
      hideBuiltInTitleBarViews()

      if let stackView = fakeLeadingTitleBarView {
        stackView.removeConstraints(stackView.constraints)
        stackView.removeFromSuperview()
      }

      if let stackView = fakeTrailingTitleBarView {
        stackView.removeConstraints(stackView.constraints)
        stackView.removeFromSuperview()
      }

    }

    /// These should all be either 0 height or unchanged from `transition.inputLayout`
    apply(visibility: outputLayout.bottomBarView, to: bottomBarView)
    if !transition.isEnteringFullScreen {
      apply(visibility: outputLayout.topBarView, to: topBarView)
    }

    if transition.isOSCChanging {
      // Remove subviews from OSC
      for view in [fragVolumeView, fragToolbarView, fragPlaybackControlButtonsView, fragPositionSliderView] {
        view?.removeFromSuperview()
      }
    }

    if transition.isTopBarPlacementChanging {
      updateTopBarPlacement(placement: outputLayout.topBarPlacement)
    }

    if transition.isBottomBarPlacementChanging {
      updateBottomBarPlacement(placement: outputLayout.bottomBarPlacement)
    }

    /// Show dividing line only for `.outsideViewport` bottom bar. Don't show in music mode as it doesn't look good
    let showBottomBarTopBorder = outputLayout.bottomBarPlacement == .outsideViewport && !outputLayout.isMusicMode
    bottomBarTopBorder.isHidden = !showBottomBarTopBorder

    if transition.isOSCChanging && outputLayout.enableOSC {
      switch outputLayout.oscPosition {
      case .top:
        log.verbose("Setting up control bar: \(outputLayout.oscPosition)")
        currentControlBar = controlBarTop
        addControlBarViews(to: oscTopMainView,
                           playBtnSize: oscBarPlaybackIconSize, playBtnSpacing: oscBarPlaybackIconSpacing)

      case .bottom:
        log.verbose("Setting up control bar: \(outputLayout.oscPosition)")
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
    if transition.isHidingLeadingSidebar, let visibleTab = transition.inputLayout.leadingSidebar.visibleTab {
      /// Remove `tabGroupView` from its parent (also removes constraints):
      let viewController = (visibleTab.group == .playlist) ? playlistView : quickSettingView
      viewController.view.removeFromSuperview()
    }
    if transition.isHidingTrailingSidebar, let visibleTab = transition.inputLayout.trailingSidebar.visibleTab {
      /// Remove `tabGroupView` from its parent (also removes constraints):
      let viewController = (visibleTab.group == .playlist) ? playlistView : quickSettingView
      viewController.view.removeFromSuperview()
    }

    // Music mode
    if transition.isEnteringMusicMode {
      oscBottomMainView.removeFromSuperview()
      bottomBarView.addSubview(miniPlayer.view, positioned: .below, relativeTo: bottomBarTopBorder)
      miniPlayer.view.addConstraintsToFillSuperview(top: 0, leading: 0, trailing: 0)

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
    if let tabToShow = transition.outputLayout.leadingSidebar.visibleTab {
      if transition.isShowingLeadingSidebar {
        prepareLayoutForOpening(leadingSidebar: transition.outputLayout.leadingSidebar)
      } else if transition.inputLayout.leadingSidebar.visibleTabGroup == transition.outputLayout.leadingSidebar.visibleTabGroup {
        // Tab group is already showing, but just need to switch tab
        switchToTabInTabGroup(tab: tabToShow)
      }
    }
    if let tabToShow = transition.outputLayout.trailingSidebar.visibleTab {
      if transition.isShowingTrailingSidebar {
        prepareLayoutForOpening(trailingSidebar: transition.outputLayout.trailingSidebar)
      } else if transition.inputLayout.trailingSidebar.visibleTabGroup == transition.outputLayout.trailingSidebar.visibleTabGroup {
        // Tab group is already showing, but just need to switch tab
        switchToTabInTabGroup(tab: tabToShow)
      }
    }

    if transition.outputLayout.isMusicMode {
      hideBuiltInTitleBarViews()
    }

    updateDepthOrderOfBars(topBar: outputLayout.topBarPlacement, bottomBar: outputLayout.bottomBarPlacement,
                           leadingSidebar: outputLayout.leadingSidebarPlacement, trailingSidebar: outputLayout.trailingSidebarPlacement)

    // So that panels toggling between "inside" and "outside" don't change until they need to (different strategy than fullscreen)
    if !transition.isTogglingFullScreen {
      updatePanelBlendingModes(to: outputLayout)
    }

    // Refresh volume & play time in UI
    updateVolumeUI()
    player.syncUITime()

    window.contentView?.layoutSubtreeIfNeeded()
    if transition.isTogglingLegacyStyle {
      forceDraw()
    }
  }

  func openNewPanelsAndFinalizeOffsets(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let outputLayout = transition.outputLayout
    log.verbose("[\(transition.name)] OpenNewPanelsAndFinalizeOffsets. TitleBar_H: \(outputLayout.titleBarHeight), TopOSC_H: \(outputLayout.topOSCHeight)")

    if transition.isEnteringMusicMode {
      miniPlayer.applyVideoViewVisibilityConstraints(isVideoVisible: musicModeGeometry.isVideoVisible)
    }

    // Update heights to their final values:
    topOSCHeightConstraint.animateToConstant(outputLayout.topOSCHeight)
    titleBarHeightConstraint.animateToConstant(outputLayout.titleBarHeight)
    osdMinOffsetFromTopConstraint.animateToConstant(outputLayout.osdMinOffsetFromTop)

    // Update heights of top & bottom bars:
    updateTopBarHeight(to: outputLayout.topBarHeight, topBarPlacement: transition.outputLayout.topBarPlacement, cameraHousingOffset: transition.outputGeometry.topMarginHeight)

    let bottomBarHeight = transition.outputLayout.bottomBarPlacement == .insideViewport ? transition.outputGeometry.insideBottomBarHeight : transition.outputGeometry.outsideBottomBarHeight
    updateBottomBarHeight(to: bottomBarHeight, bottomBarPlacement: transition.outputLayout.bottomBarPlacement)

    // Sidebars (if opening)
    let leadingSidebar = transition.outputLayout.leadingSidebar
    let trailingSidebar = transition.outputLayout.trailingSidebar
    animateShowOrHideSidebars(transition: transition,
                              layout: transition.outputLayout,
                              setLeadingTo: transition.isShowingLeadingSidebar ? leadingSidebar.visibility : nil,
                              setTrailingTo: transition.isShowingTrailingSidebar ? trailingSidebar.visibility : nil)
    updateSpacingForTitleBarAccessories(transition.outputLayout, windowWidth: transition.outputGeometry.windowFrame.width)
    // Update sidebar vertical alignments
    updateSidebarVerticalConstraints(tabHeight: outputLayout.sidebarTabHeight, downshift: outputLayout.sidebarDownshift)

    if !outputLayout.enableOSC {
      currentControlBar = nil
    } else if transition.isOSCChanging && outputLayout.hasFloatingOSC {
      // Set up floating OSC views here. Doing this in prev or next task while animating results in visibility bugs
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

    switch transition.outputLayout.mode {
    case .fullScreen:
      if transition.outputLayout.isNativeFullScreen {
        // Native Full Screen: set frame not including camera housing because it looks better with the native animation
        log.verbose("Calling setFrame() to animate into native full screen, to: \(transition.outputGeometry.windowFrame)")
        videoView.updateSizeConstraints(transition.outputGeometry.videoSize)
        player.window.setFrameImmediately(transition.outputGeometry.windowFrame)
      } else if transition.outputLayout.isLegacyFullScreen {
        let screen = NSScreen.getScreenOrDefault(screenID: transition.outputGeometry.screenID)
        let newGeo: PlayerWindowGeometry
        if transition.isEnteringLegacyFullScreen {
          // Deal with possible top margin needed to hide camera housing
          if transition.outputGeometry.hasTopPaddingForCameraHousing {
            /// Entering legacy FS on a screen with camera housing.
            /// Prevent an unwanted bouncing near the top by using this animation to expand to visibleFrame.
            /// (will expand window to cover `cameraHousingHeight` in next animation)
            newGeo = transition.outputGeometry.clone(windowFrame: screen.frameWithoutCameraHousing, topMarginHeight: 0)
          } else {
            /// Set window size to `visibleFrame` for now. This excludes menu bar which needs a separate animation to hide.
            /// Later, when menu bar is hidden, a `NSApplicationDidChangeScreenParametersNotification` will be sent, which will
            /// trigger the window to resize again and cover the whole screen.
            newGeo = transition.outputGeometry.clone(windowFrame: screen.visibleFrame, topMarginHeight: transition.outputGeometry.topMarginHeight)
          }
        } else {
          /// Either already in legacy FS, or entering legacy FS. Apply final geometry.
          newGeo = transition.outputGeometry
        }
        log.verbose("Calling setFrame() for legacy full screen in OpenNewPanelsAndFinalizeOffsets")
        setWindowFrameForLegacyFullScreen(using: newGeo)
      }
    case .musicMode:
      // Especially needed when applying initial layout:
      applyMusicModeGeometry(musicModeGeometry)
    case .windowed:
      let newWindowFrame = transition.outputGeometry.windowFrame
      log.verbose("Calling setFrame() from openNewPanelsAndFinalizeOffsets with newWindowFrame \(newWindowFrame)")
      videoView.updateSizeConstraints(transition.outputGeometry.videoSize)
      player.window.setFrameImmediately(newWindowFrame)
    }
    
    if transition.isTogglingLegacyStyle {
      forceDraw()
    }
  }

  func fadeInNewViews(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let outputLayout = transition.outputLayout
    log.verbose("[\(transition.name)] FadeInNewViews")

    if outputLayout.titleIconAndText.isShowable {
      window.titleVisibility = .visible
    }

    applyShowableOnly(visibility: outputLayout.controlBarFloating, to: controlBarFloating)

    if outputLayout.isFullScreen {
      if Preference.bool(for: .displayTimeAndBatteryInFullScreen) {
        apply(visibility: .showFadeableNonTopBar, to: additionalInfoView)
      }
    } else if !outputLayout.isMusicMode {
      /// Special case for `trafficLightButtons` due to quirks. Do not use `fadeableViews`. ALways set `alphaValue = 1`.
      for button in trafficLightButtons {
        button.alphaValue = 1
        button.isHidden = false
      }
      titleTextField?.isHidden = false
      titleTextField?.alphaValue = 1
      documentIconButton?.isHidden = false
      documentIconButton?.alphaValue = 1

      if let fakeLeadingTitleBarView = fakeLeadingTitleBarView {
        fakeLeadingTitleBarView.isHidden = false
        fakeLeadingTitleBarView.alphaValue = 1
      }

      if let fakeTrailingTitleBarView = fakeTrailingTitleBarView {
        fakeTrailingTitleBarView.isHidden = false
        fakeTrailingTitleBarView.alphaValue = 1
      }

      // TODO: figure out whether to finish replicating title bar, or just give up and leave it out
      if outputLayout.spec.isLegacyStyle && LayoutSpec.useFakeTitleForLegacyWindow && fakeLeadingTitleBarView == nil {
        // Add fake traffic light buttons:
        let btnTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let trafficLightButtons: [NSButton] = btnTypes.compactMap{ NSWindow.standardWindowButton($0, for: .titled) }

        let leadingBarImage = NSImage(imageLiteralResourceName: "sidebar.leading")
        let leadingSidebarToggleButton = NSButton(image: leadingBarImage, target: self, action: #selector(self.toggleLeadingSidebarVisibility(_:)))
        leadingSidebarToggleButton.setButtonType(.momentaryPushIn)
        leadingSidebarToggleButton.bezelStyle = .smallSquare
        leadingSidebarToggleButton.isBordered = false
        leadingSidebarToggleButton.imagePosition = .imageOnly
        leadingSidebarToggleButton.refusesFirstResponder = true
        leadingSidebarToggleButton.imageScaling = .scaleNone
        leadingSidebarToggleButton.font = NSFont.systemFont(ofSize: 17)
        leadingSidebarToggleButton.widthAnchor.constraint(equalTo: leadingSidebarToggleButton.heightAnchor, multiplier: 1).isActive = true

        let leadingStackView = FauxTitleBarView(views: trafficLightButtons + [leadingSidebarToggleButton])
        leadingStackView.wantsLayer = true
        leadingStackView.layer?.backgroundColor = .clear
        leadingStackView.orientation = .horizontal
        leadingStackView.detachesHiddenViews = false
        leadingStackView.spacing = 6  // matches spacing as of MacOS Sonoma (14.0)
        leadingStackView.alignment = .centerY
        leadingStackView.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        for btn in trafficLightButtons {
          btn.alphaValue = 1
          btn.isEnabled = true
          btn.isHidden = false
          btn.target = window
        }
        fakeLeadingTitleBarView = leadingStackView

        if leadingStackView.trackingAreas.count <= 1 && trafficLightButtons.count == 3 {
          for btn in trafficLightButtons {
            /// This solution works better than using `window` as owner, because with that the green button would get stuck with highlight
            /// when menu was shown.
            /// FIXME: unfortunately this solution grays out the context menu items for the green button
            /// FIXME: traffic light buttons are initially drawn as inactive until hovered over (usually - seems to be a race condition)
            btn.addTrackingArea(NSTrackingArea(rect: btn.bounds, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: leadingStackView, userInfo: ["obj": 2]))
          }
        }

        let trailingBarImage = NSImage(imageLiteralResourceName: "sidebar.trailing")
        let trailingSidebarToggleButton = NSButton(image: trailingBarImage, target: self, action: #selector(self.toggleTrailingSidebarVisibility(_:)))
        trailingSidebarToggleButton.setButtonType(.momentaryPushIn)
        trailingSidebarToggleButton.bezelStyle = .smallSquare
        trailingSidebarToggleButton.isBordered = false
        trailingSidebarToggleButton.imagePosition = .imageOnly
        trailingSidebarToggleButton.refusesFirstResponder = true
        trailingSidebarToggleButton.imageScaling = .scaleNone
        trailingSidebarToggleButton.font = NSFont.systemFont(ofSize: 17)
        trailingSidebarToggleButton.widthAnchor.constraint(equalTo: trailingSidebarToggleButton.heightAnchor, multiplier: 1).isActive = true

        let trailingStackView = NSStackView(views: [trailingSidebarToggleButton])
        trailingStackView.wantsLayer = true
        trailingStackView.layer?.backgroundColor = .clear
        trailingStackView.orientation = .horizontal
        trailingStackView.detachesHiddenViews = false
        trailingStackView.alignment = .centerY
        trailingStackView.spacing = 6  // matches spacing as of MacOS Sonoma (14.0)
        trailingStackView.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)

        fakeTrailingTitleBarView = trailingStackView
      }

      if let leadingStackView = fakeLeadingTitleBarView {
        if transition.outputLayout.topBarPlacement == .outsideViewport {
          titleBarView.addSubview(leadingStackView)
        } else {
          window.contentView?.addSubview(leadingStackView)
        }

        if leadingStackView.constraints.isEmpty {
          leadingStackView.leadingAnchor.constraint(equalTo: leadingStackView.superview!.leadingAnchor).isActive = true
          leadingStackView.topAnchor.constraint(equalTo: leadingStackView.superview!.topAnchor).isActive = true
          leadingStackView.heightAnchor.constraint(equalToConstant: PlayerWindowController.standardTitleBarHeight).isActive = true
        }
        leadingStackView.layout()
      }

      if let trailingStackView = fakeTrailingTitleBarView {
        if transition.outputLayout.topBarPlacement == .outsideViewport {
          titleBarView.addSubview(trailingStackView)
        } else {
          window.contentView?.addSubview(trailingStackView)
        }

        if trailingStackView.constraints.isEmpty {
          trailingStackView.topAnchor.constraint(equalTo: trailingStackView.superview!.topAnchor).isActive = true
          trailingStackView.trailingAnchor.constraint(equalTo: trailingStackView.superview!.trailingAnchor).isActive = true
          trailingStackView.heightAnchor.constraint(equalToConstant: PlayerWindowController.standardTitleBarHeight).isActive = true
        }
        trailingStackView.layout()
      }

      /// Title bar accessories get removed by legacy fullscreen or if window `styleMask` did not include `.titled`.
      /// Add them back:
      addTitleBarAccessoryViews()
    }

    applyShowableOnly(visibility: outputLayout.leadingSidebarToggleButton, to: leadingSidebarToggleButton)
    applyShowableOnly(visibility: outputLayout.trailingSidebarToggleButton, to: trailingSidebarToggleButton)
    updatePinToTopButton()

    // Add back title bar accessories (if needed):
    applyShowableOnly(visibility: outputLayout.titlebarAccessoryViewControllers, to: leadingTitleBarAccessoryView)
    applyShowableOnly(visibility: outputLayout.titlebarAccessoryViewControllers, to: trailingTitleBarAccessoryView)
  }

  func doPostTransitionWork(_ transition: LayoutTransition) {
    log.verbose("[\(transition.name)] DoPostTransitionWork")
    // Update blending mode:
    updatePanelBlendingModes(to: transition.outputLayout)
    /// This should go in `fadeInNewViews()`, but for some reason putting it here fixes a bug where the document icon won't fade out
    apply(visibility: transition.outputLayout.titleIconAndText, titleTextField, documentIconButton)

    fadeableViewsAnimationState = .shown
    fadeableTopBarAnimationState = .shown
    resetFadeTimer()

    guard let window = window else { return }

    if transition.isEnteringFullScreen {
      // Entered FullScreen

      if !transition.outputLayout.isLegacyFullScreen {
        /// Special case: need to wait until now to call `trafficLightButtons.isHidden = false` due to their quirks
        for button in trafficLightButtons {
          button.isHidden = false
        }
      }

      if transition.isTogglingLegacyStyle {
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

      if #available(macOS 10.16, *) {
        window.level = .normal
      } else {
        window.styleMask.remove(.fullScreen)
      }

      if transition.inputLayout.isLegacyFullScreen {
        window.styleMask.insert(.resizable)
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

      resetCollectionBehavior()
      updateWindowParametersForMPV()

      if transition.outputLayout.spec.isLegacyStyle {  // legacy windowed
        setWindowStyleToLegacy()
      } else {  // native windowed
        setWindowStyleToNative()
        if !transition.outputLayout.isMusicMode {
          window.titleVisibility = .visible
        }
      }

      if transition.isExitingLegacyFullScreen {
        restoreDockSettings()
      }

      if Preference.bool(for: .blackOutMonitor) {
        removeBlackWindows()
      }

      // restore ontop status
      if player.info.isPlaying {
        setWindowFloatingOnTop(isOntop, updateOnTopStatus: false)
      }

      if transition.isTogglingLegacyStyle {
        videoView.videoLayer.resume()
      }

      if Preference.bool(for: .pauseWhenLeavingFullScreen) && player.info.isPlaying {
        player.pause()
      }

      player.events.emit(.windowFullscreenChanged, data: false)
    }

    refreshHidesOnDeactivateStatus()

    // Need to make sure this executes after styleMask is .titled
    addTitleBarAccessoryViews()

    videoView.needsLayout = true
    videoView.layoutSubtreeIfNeeded()
    forceDraw()

    log.verbose("[\(transition.name)] Done with transition. IsFullScreen:\(transition.outputLayout.isFullScreen.yn), IsLegacy:\(transition.outputLayout.spec.isLegacyStyle), Mode:\(currentLayout.mode)")
    player.saveState()
  }

  // MARK: - Bars Layout

  // - Top bar

  /**
   This ONLY updates the constraints to toggle between `inside` and `outside` placement types.
   Whether it is actually shown is a concern for somewhere else.
   "Outside"
   *     ┌─────────────┐
   *     │  Title Bar  │   Top of    Top of
   *     ├─────────────┤    Video    Video
   *     │   Top OSC   │        │    │            "Inside"
   ┌─────┼─────────────┼─────┐◄─┘    └─►┌─────┬─────────────┬─────┐
   │     │            V│     │          │     │  Title Bar V│     │
   │ Left│            I│Right│          │ Left├────────────I│Right│
   │ Side│            D│Side │          │ Side│   Top OSC  D│Side │
   │  bar│            E│bar  │          │  bar├────────────E│bar  │
   │     │  VIDEO     O│     │          │     │  VIDEO     O│     │
   └─────┴─────────────┴─────┘          └─────┴─────────────┴─────┘
   */
  private func updateTopBarPlacement(placement: Preference.PanelPlacement) {
    log.verbose("Updating topBar placement to: \(placement)")
    guard let window = window, let contentView = window.contentView else { return }
    contentView.removeConstraint(topBarLeadingSpaceConstraint)
    contentView.removeConstraint(topBarTrailingSpaceConstraint)

    switch placement {
    case .insideViewport:
      // Align left & right sides with sidebars (top bar will squeeze to make space for sidebars)
      topBarLeadingSpaceConstraint = topBarView.leadingAnchor.constraint(equalTo: leadingSidebarView.trailingAnchor, constant: 0)
      topBarTrailingSpaceConstraint = topBarView.trailingAnchor.constraint(equalTo: trailingSidebarView.leadingAnchor, constant: 0)

    case .outsideViewport:
      // Align left & right sides with window (sidebars go below top bar)
      topBarLeadingSpaceConstraint = topBarView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0)
      topBarTrailingSpaceConstraint = topBarView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: 0)

    }
    topBarLeadingSpaceConstraint.isActive = true
    topBarTrailingSpaceConstraint.isActive = true
  }

  func updateTopBarHeight(to topBarHeight: CGFloat, topBarPlacement: Preference.PanelPlacement, cameraHousingOffset: CGFloat) {
    log.verbose("Updating topBar height: \(topBarHeight), placement: \(topBarPlacement), cameraOffset: \(cameraHousingOffset)")

    switch topBarPlacement {
    case .insideViewport:
      viewportTopOffsetFromTopBarBottomConstraint.animateToConstant(-topBarHeight)
      viewportTopOffsetFromTopBarTopConstraint.animateToConstant(0)
      viewportTopOffsetFromContentViewTopConstraint.animateToConstant(0 + cameraHousingOffset)
    case .outsideViewport:
      viewportTopOffsetFromTopBarBottomConstraint.animateToConstant(0)
      viewportTopOffsetFromTopBarTopConstraint.animateToConstant(topBarHeight)
      viewportTopOffsetFromContentViewTopConstraint.animateToConstant(topBarHeight + cameraHousingOffset)
    }
  }

  // - Bottom bar

  private func updateBottomBarPlacement(placement: Preference.PanelPlacement) {
    log.verbose("Updating bottomBar placement to: \(placement)")
    guard let window = window, let contentView = window.contentView else { return }
    contentView.removeConstraint(bottomBarLeadingSpaceConstraint)
    contentView.removeConstraint(bottomBarTrailingSpaceConstraint)

    switch placement {
    case .insideViewport:
      // Align left & right sides with sidebars (top bar will squeeze to make space for sidebars)
      bottomBarLeadingSpaceConstraint = bottomBarView.leadingAnchor.constraint(equalTo: leadingSidebarView.trailingAnchor, constant: 0)
      bottomBarTrailingSpaceConstraint = bottomBarView.trailingAnchor.constraint(equalTo: trailingSidebarView.leadingAnchor, constant: 0)
    case .outsideViewport:
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
    case .insideViewport:
      viewportBottomOffsetFromBottomBarTopConstraint.animateToConstant(bottomBarHeight)
      viewportBottomOffsetFromBottomBarBottomConstraint.animateToConstant(0)
      viewportBottomOffsetFromContentViewBottomConstraint.animateToConstant(0)
    case .outsideViewport:
      viewportBottomOffsetFromBottomBarTopConstraint.animateToConstant(0)
      viewportBottomOffsetFromBottomBarBottomConstraint.animateToConstant(-bottomBarHeight)
      viewportBottomOffsetFromContentViewBottomConstraint.animateToConstant(bottomBarHeight)
    }
  }

  /// After bars are shown or hidden, or their placement changes, this ensures that their shadows appear in the correct places.
  /// • Outside bars never cast shadows or have shadows cast on them.
  /// • Inside sidebars cast shadows over inside top bar & inside bottom bar, and over `viewportView`.
  /// • Inside top & inside bottom bars do not cast shadows over `viewportView`.
  private func updateDepthOrderOfBars(topBar: Preference.PanelPlacement, bottomBar: Preference.PanelPlacement,
                                      leadingSidebar: Preference.PanelPlacement, trailingSidebar: Preference.PanelPlacement) {
    guard let window = window, let contentView = window.contentView else { return }

    // If a sidebar is "outsideViewport", need to put it behind the video because:
    // (1) Don't want sidebar to cast a shadow on the video
    // (2) Animate sidebar open/close with "slide in" / "slide out" from behind the video
    if leadingSidebar == .outsideViewport {
      contentView.addSubview(leadingSidebarView, positioned: .below, relativeTo: viewportView)
    }
    if trailingSidebar == .outsideViewport {
      contentView.addSubview(trailingSidebarView, positioned: .below, relativeTo: viewportView)
    }

    contentView.addSubview(topBarView, positioned: .above, relativeTo: viewportView)
    contentView.addSubview(bottomBarView, positioned: .above, relativeTo: viewportView)

    if leadingSidebar == .insideViewport {
      contentView.addSubview(leadingSidebarView, positioned: .above, relativeTo: viewportView)

      if topBar == .insideViewport {
        contentView.addSubview(topBarView, positioned: .below, relativeTo: leadingSidebarView)
      }
      if bottomBar == .insideViewport {
        contentView.addSubview(bottomBarView, positioned: .below, relativeTo: leadingSidebarView)
      }
    }

    if trailingSidebar == .insideViewport {
      contentView.addSubview(trailingSidebarView, positioned: .above, relativeTo: viewportView)

      if topBar == .insideViewport {
        contentView.addSubview(topBarView, positioned: .below, relativeTo: trailingSidebarView)
      }
      if bottomBar == .insideViewport {
        contentView.addSubview(bottomBarView, positioned: .below, relativeTo: trailingSidebarView)
      }
    }
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
    let trailingSpace: CGFloat = layout.topBarPlacement == .outsideViewport ? 8 : max(8, layout.leadingSidebar.insideWidth - trafficLightButtonsWidth - sidebarButtonSpace)
    leadingTitleBarTrailingSpaceConstraint.animateToConstant(trailingSpace)

    leadingTitleBarAccessoryView.layoutSubtreeIfNeeded()
  }

  // Updates visibility of buttons on the right side of the title bar. Also when the right sidebar is visible,
  // sets the horizontal space needed to push the title bar left, so that it doesn't overlap onto the right sidebar.
  private func updateSpacingForTrailingTitleBarAccessory(_ layout: LayoutState, windowWidth: CGFloat) {
    var spaceForButtons: CGFloat = 0
    let isPinToTopButtonShowable = layout.computePinToTopButtonVisibility(isOnTop: isOntop).isShowable

    if layout.trailingSidebarToggleButton.isShowable {
      spaceForButtons += trailingSidebarToggleButton.frame.width
    }
    if isPinToTopButtonShowable {
      spaceForButtons += pinToTopButton.frame.width
    }

    let leadingSpaceNeeded: CGFloat = layout.topBarPlacement == .outsideViewport ? 0 : max(0, layout.trailingSidebar.currentWidth - spaceForButtons)
    // The title icon & text looks very bad if we try to push it too far to the left. Try to detect this and just remove the offset in this case
    let maxSpaceAllowed: CGFloat = max(0, windowWidth * 0.5 - 20)
    let leadingSpace = leadingSpaceNeeded > maxSpaceAllowed ? 0 : leadingSpaceNeeded
    trailingTitleBarLeadingSpaceConstraint.animateToConstant(leadingSpace)

    // Add padding to the side for buttons
    let isAnyButtonVisible = layout.trailingSidebarToggleButton.isShowable || isPinToTopButtonShowable
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

  // Either legacy FS or windowed
  private func setWindowStyleToLegacy() {
    guard let window = window else { return }
    log.verbose("Removing window styleMask.titled")
    window.styleMask.remove(.titled)
    window.styleMask.insert(.borderless)
    window.styleMask.insert(.closable)
    window.styleMask.insert(.miniaturizable)
  }

  // "Native" == "titled"
  private func setWindowStyleToNative() {
    guard let window = window else { return }
    log.verbose("Inserting window styleMask.titled")
    window.styleMask.insert(.titled)
    window.styleMask.remove(.borderless)

    // Remove fake traffic light buttons (if any)
    if let fakeLeadingTitleBarView = fakeLeadingTitleBarView {
      for subview in fakeLeadingTitleBarView.subviews {
        subview.removeFromSuperview()
      }
      fakeLeadingTitleBarView.removeFromSuperview()
      self.fakeLeadingTitleBarView = nil
    }

    if let fakeTrailingTitleBarView = fakeTrailingTitleBarView {
      for subview in fakeTrailingTitleBarView.subviews {
        subview.removeFromSuperview()
      }
      fakeTrailingTitleBarView.removeFromSuperview()
      self.fakeTrailingTitleBarView = nil
    }

  }

  private func hideBuiltInTitleBarViews() {
    guard let window = window else { return }
    window.titleVisibility = .hidden

    /// Workaround for Apple bug (as of MacOS 13.3.1) where setting `alphaValue=0` on the "minimize" button will
    /// cause `window.performMiniaturize()` to be ignored. So to hide these, use `isHidden=true` + `alphaValue=1` instead.
    for button in trafficLightButtons {
      button.isHidden = true
    }
  }

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

  private func updatePanelBlendingModes(to outputLayout: LayoutState) {
    // Full screen + "behindWindow" doesn't blend properly and looks ugly
    if outputLayout.topBarPlacement == .insideViewport || outputLayout.isFullScreen {
      topBarView.blendingMode = .withinWindow
    } else {
      topBarView.blendingMode = .behindWindow
    }

    // Full screen + "behindWindow" doesn't blend properly and looks ugly
    if outputLayout.bottomBarPlacement == .insideViewport || outputLayout.isFullScreen {
      bottomBarView.blendingMode = .withinWindow
    } else {
      bottomBarView.blendingMode = .behindWindow
    }

    updateSidebarBlendingMode(.leadingSidebar, layout: outputLayout)
    updateSidebarBlendingMode(.trailingSidebar, layout: outputLayout)
  }
}
