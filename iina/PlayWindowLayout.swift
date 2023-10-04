//
//  PlayWindowLayout.swift
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

extension PlayWindowController {

  // MARK: - Initial Layout

  func setInitialWindowLayout() {
    let initialLayoutSpec: LayoutSpec
    let isRestoringFromPrevLaunch: Bool
    var needsNativeFullScreen = false

    if let priorState = player.info.priorState, let priorLayoutSpec = priorState.layoutSpec {
      log.verbose("Transitioning to initial layout from prior window state")
      isRestoringFromPrevLaunch = true

      // Restore saved geometries
      if let priorWindowedModeGeometry = priorState.windowedModeGeometry {
        windowedModeGeometry = priorWindowedModeGeometry
        // Restore primary videoAspectRatio
        if priorLayoutSpec.mode != .musicMode {
          videoAspectRatio = windowedModeGeometry.videoAspectRatio
        }
      } else {
        log.error("Failed to get player window geometry from prefs")
      }

      if let priorMusicModeGeometry = priorState.musicModeGeometry {
        musicModeGeometry = priorMusicModeGeometry
        // Restore primary videoAspectRatio
        if priorLayoutSpec.mode == .musicMode {
          videoAspectRatio = musicModeGeometry.videoAspectRatio
        }
      } else {
        log.error("Failed to get player window layout and/or geometry from prefs")
      }

      if priorLayoutSpec.mode == .musicMode {
        player.overrideAutoMusicMode = true
      }

      if priorLayoutSpec.isNativeFullScreen && !currentLayout.isFullScreen {
        // Special handling for native fullscreen. Rely on mpv to put us in FS when it is ready
        initialLayoutSpec = priorLayoutSpec.clone(mode: .windowed)
        needsNativeFullScreen = true
      } else {
        initialLayoutSpec = priorLayoutSpec
      }

    } else {
      log.verbose("Transitioning to initial layout from app prefs")
      isRestoringFromPrevLaunch = false
      initialLayoutSpec = LayoutSpec.fromPreferences(fillingInFrom: currentLayout.spec)
    }

    let name = "\(isRestoringFromPrevLaunch ? "Restore" : "Set")InitialLayout"
    let transition = buildLayoutTransition(named: name, from: currentLayout, to: initialLayoutSpec, isInitialLayout: true)

    // For initial layout (when window is first shown), to reduce jitteriness when drawing,
    // do all the layout in a single animation block
    CocoaAnimation.disableAnimation{
      for task in transition.animationTasks {
        task.runFunc()
      }
      log.verbose("Done with transition to initial layout")
    }

    if Preference.bool(for: .alwaysFloatOnTop) {
      log.verbose("Setting window to OnTop per app preference")
      setWindowFloatingOnTop(true)
    }

    if needsNativeFullScreen {
      animationQueue.runZeroDuration({ [self] in
        enterFullScreen()
      })
      return
    }

    guard isRestoringFromPrevLaunch else { return }

    /// Stored window state may not be consistent with global IINA prefs.
    /// To check this, build another `LayoutSpec` from the global prefs, then compare it to the player's.
    let prefsSpec = LayoutSpec.fromPreferences(fillingInFrom: currentLayout.spec)
    if initialLayoutSpec.hasSamePrefsValues(as: prefsSpec) {
      log.verbose("Saved layout is consistent with IINA global prefs")
    } else {
      // Not consistent. But we already have the correct spec, so just build a layout from it and transition to correct layout
      log.warn("Player's saved layout does not match IINA app prefs. Will build and apply a corrected layout")
      buildLayoutTransition(named: "FixInvalidInitialLayout", from: transition.outputLayout, to: prefsSpec, thenRun: true)
    }
  }

  // MARK: - Building LayoutTransition

  /// First builds a new `LayoutState` based on the given `LayoutSpec`, then builds & returns a `LayoutTransition`,
  /// which contains all the information needed to animate the UI changes from the current `LayoutState` to the new one.
  @discardableResult
  func buildLayoutTransition(named transitionName: String,
                             from inputLayout: LayoutState,
                             to outputSpec: LayoutSpec,
                             isInitialLayout: Bool = false,
                             totalStartingDuration: CGFloat? = nil,
                             totalEndingDuration: CGFloat? = nil,
                             thenRun: Bool = false) -> LayoutTransition {

    // - Build outputLayout

    let outputLayout = LayoutState.from(outputSpec)

    // - Build geometries

    // Build InputGeometry
    let inputGeometry: PlayWindowGeometry
    // Restore window size & position
    switch inputLayout.spec.mode {
    case .fullScreen, .windowed:
      if inputLayout.isLegacyFullScreen {
        inputGeometry = buildLegacyFullScreenGeometry(from: inputLayout)
      } else {
        inputGeometry = windowedModeGeometry
      }
    case .musicMode:
      /// `musicModeGeometry` should have already been deserialized and set.
      /// But make sure we correct any size problems
      inputGeometry = musicModeGeometry.constrainWithin(bestScreen.visibleFrame).toPlayWindowGeometry()
    }
    log.verbose("[\(transitionName)] Built inputGeometry: \(inputGeometry)")

    // Build OutputGeometry
    let outputGeometry: PlayWindowGeometry = buildOutputGeometry(inputGeometry: inputGeometry, outputLayout: outputLayout)

    let transition = LayoutTransition(name: transitionName,
                                      from: inputLayout, from: inputGeometry,
                                      to: outputLayout, to: outputGeometry,
                                      isInitialLayout: isInitialLayout)

    if !isInitialLayout {
      // Build MiddleGeometry (after closed panels step)
      transition.middleGeometry = buildMiddleGeometry(forTransition: transition)
      log.verbose("[\(transitionName)] Built middleGeometry: \(transition.middleGeometry!)")
    }

    let panelTimingName: CAMediaTimingFunctionName?
    if transition.isTogglingFullScreen {
      panelTimingName = nil
    } else if transition.isTogglingVisibilityOfAnySidebar {
      panelTimingName = .easeIn
    } else {
      panelTimingName = .linear
    }

    // - Determine durations

    var startingAnimationDuration = CocoaAnimation.DefaultDuration
    if transition.isTogglingFullScreen {
      startingAnimationDuration = 0
    } else if transition.isEnteringMusicMode {
      startingAnimationDuration = CocoaAnimation.DefaultDuration * 0.3
    } else if let totalStartingDuration = totalStartingDuration {
      startingAnimationDuration = totalStartingDuration * 0.3
    }

    var showFadeableViewsDuration: CGFloat = startingAnimationDuration
    var fadeOutOldViewsDuration: CGFloat = startingAnimationDuration
    if transition.isExitingMusicMode {
      showFadeableViewsDuration = 0
      fadeOutOldViewsDuration = 0
    }

    let endingAnimationDuration: CGFloat = totalEndingDuration ?? CocoaAnimation.DefaultDuration

    // If entering legacy full screen, will add an extra animation to hiding camera housing / menu bar / dock
    let openFinalPanelsDuration = transition.isTogglingLegacyFullScreen ? (endingAnimationDuration * 0.8) : endingAnimationDuration

    log.verbose("[\(transitionName)] Building transition animations. EachStartDuration: \(startingAnimationDuration), EachEndDuration: \(endingAnimationDuration), InputGeo: \(transition.inputGeometry), OuputGeo: \(transition.outputGeometry)")

    // - Starting animations:

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

    // Extra animation for exiting legacy full screen (to Native Windowed Mode)
    if transition.isExitingLegacyFullScreen && !transition.outputLayout.spec.isLegacyStyle {
      transition.animationTasks.append(CocoaAnimation.Task(duration: endingAnimationDuration * 0.2, timing: .easeIn, { [self] in
        let screen = bestScreen
        let newGeo = transition.inputGeometry.clone(windowFrame: screen.frameWithoutCameraHousing, topMarginHeight: 0)
        log.verbose("Updating legacy full screen window to show camera housing prior to entering native windowed mode")
        setWindowFrameForLegacyFullScreen(using: newGeo)
      }))
    }

    // StartingAnimation 3: Close/Minimize panels which are no longer needed. Not used for fullScreen transitions.
    // Applies middleGeometry if it exists.
    if transition.needsCloseOldPanels {
      let closeOldPanelsDuration = transition.isExitingLegacyFullScreen ? (startingAnimationDuration * 0.8) : startingAnimationDuration
      transition.animationTasks.append(CocoaAnimation.Task(duration: closeOldPanelsDuration, timing: panelTimingName, { [self] in
        closeOldPanels(transition)
      }))
    }

    // - Middle animations:

    // 0: Middle point: update style & constraints. Should have minimal visual changes
    transition.animationTasks.append(CocoaAnimation.zeroDurationTask{ [self] in
      // This also can change window styleMask
      updateHiddenViewsAndConstraints(transition)
    })

    // Extra task when toggling music mode: move & resize window
    if transition.isTogglingMusicMode && !transition.isInitialLayout && !transition.isTogglingFullScreen {
      transition.animationTasks.append(CocoaAnimation.Task(duration: CocoaAnimation.DefaultDuration, timing: .easeInEaseOut, { [self] in
        // FIXME: develop a nice sliding animation if possible

        if transition.isEnteringMusicMode {
          if musicModeGeometry.isVideoVisible {
            // Entering music mode when album art is visible
            videoView.updateSizeConstraints(transition.outputGeometry.videoSize)
          } else {
            // Entering music mode when album art is hidden
            let heightConstraint = videoContainerView.heightAnchor.constraint(equalToConstant: 0)
            heightConstraint.isActive = true
            videoContainerViewHeightContraint = heightConstraint
          }
        } else if transition.isExitingMusicMode {
          // Exiting music mode
          videoView.updateSizeConstraints(transition.outputGeometry.videoSize)

          // Set videoView to visible
          miniPlayer.applyVideoViewVisibilityConstraints(isVideoVisible: true)
        }

        player.window.setFrameImmediately(transition.outputGeometry.videoContainerFrameInScreenCoords)
      }))
    }

    // - Ending animations:

    // Extra animation for exiting legacy full screen  (to Legacy Windowed Mode)
    if transition.isExitingLegacyFullScreen && transition.outputLayout.spec.isLegacyStyle && !transition.isInitialLayout {
      transition.animationTasks.append(CocoaAnimation.Task(duration: endingAnimationDuration * 0.2, timing: .easeIn, { [self] in
        let screen = bestScreen
        let newGeo = transition.inputGeometry.clone(windowFrame: screen.frameWithoutCameraHousing, topMarginHeight: 0)
        log.verbose("Updating legacy full screen window to show camera housing prior to entering legacy windowed mode")
        setWindowFrameForLegacyFullScreen(using: newGeo)
      }))
    }

    // EndingAnimation: Open new panels and fade in new views
    transition.animationTasks.append(CocoaAnimation.Task(duration: openFinalPanelsDuration, timing: .linear, { [self] in
      // If toggling fullscreen, this also changes the window frame:
      openNewPanelsAndFinalizeOffsets(transition)

      if transition.isTogglingFullScreen {
        // Fullscreen animations don't have much time. Combine fadeIn step in same animation:
        fadeInNewViews(transition)
      }
    }))

    // EndingAnimation: Fade in new views
    if !transition.isTogglingFullScreen && transition.needsFadeInNewViews {
      transition.animationTasks.append(CocoaAnimation.Task(duration: endingAnimationDuration, timing: panelTimingName, { [self] in
        fadeInNewViews(transition)
      }))
    }

    // Extra animation for entering legacy full screen
    if transition.isEnteringLegacyFullScreen && !transition.isInitialLayout {
      transition.animationTasks.append(CocoaAnimation.Task(duration: endingAnimationDuration * 0.2, timing: .easeIn, { [self] in
        let screen = bestScreen
        let newGeo = transition.outputGeometry.clone(windowFrame: screen.frame, topMarginHeight: screen.cameraHousingHeight ?? 0)
        log.verbose("Updating legacy full screen window to cover camera housing / menu bar / dock")
        setWindowFrameForLegacyFullScreen(using: newGeo)
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

  /// Note that the result should not necessarily overrite `windowedModeGeometry`. It is used by the transition animations.
  private func buildOutputGeometry(inputGeometry oldGeo: PlayWindowGeometry, outputLayout: LayoutState) -> PlayWindowGeometry {
    switch outputLayout.spec.mode {

    case .musicMode:
      /// `videoAspectRatio` may have gone stale while not in music mode. Update it (playlist height will be recalculated if needed):
      let musicModeGeometryCorrected = musicModeGeometry.clone(videoAspectRatio: videoAspectRatio).constrainWithin(bestScreen.visibleFrame)
      return musicModeGeometryCorrected.toPlayWindowGeometry()

    case .fullScreen:
      if outputLayout.spec.isLegacyStyle {
        return buildLegacyFullScreenGeometry(from: outputLayout)
      } else {
        // This will be ignored anyway, so just save the processing cycles
        return windowedModeGeometry
      }
    case .windowed:
      break  // see below
    }

    let bottomBarHeight: CGFloat
    if outputLayout.enableOSC && outputLayout.oscPosition == .bottom {
      bottomBarHeight = OSCToolbarButton.oscBarHeight
    } else {
      bottomBarHeight = 0
    }

    let insideTopBarHeight = outputLayout.topBarPlacement == .insideVideo ? outputLayout.topBarHeight : 0
    let insideBottomBarHeight = outputLayout.bottomBarPlacement == .insideVideo ? bottomBarHeight : 0
    let outsideBottomBarHeight = outputLayout.bottomBarPlacement == .outsideVideo ? bottomBarHeight : 0

    let newGeo = windowedModeGeometry.withResizedBars(outsideTopBarHeight: outputLayout.outsideTopBarHeight,
                                                      outsideTrailingBarWidth: outputLayout.outsideTrailingBarWidth,
                                                      outsideBottomBarHeight: outsideBottomBarHeight,
                                                      outsideLeadingBarWidth: outputLayout.outsideLeadingBarWidth,
                                                      insideTopBarHeight: insideTopBarHeight,
                                                      insideTrailingBarWidth: outputLayout.insideTrailingBarWidth,
                                                      insideBottomBarHeight: insideBottomBarHeight,
                                                      insideLeadingBarWidth: outputLayout.insideLeadingBarWidth,
                                                      videoAspectRatio: oldGeo.videoAspectRatio,
                                                      constrainedWithin: bestScreen.visibleFrame)

    // FIXME: this doesn't synchronize properly during animations when this is false. Remove this guard when fixed
    guard Preference.bool(for: .allowEmptySpaceAroundVideo) else {
      return newGeo
    }

    let outsideWidthIncrease = newGeo.outsideSidebarsTotalWidth - oldGeo.outsideSidebarsTotalWidth

    if outsideWidthIncrease < 0 {   // Shrinking window width
      // If opening the sidebar causes the video to be shrunk to fit everything on screen, we want to be able to restore
      // its previous size when the sidebar is closed again, instead of leaving the window in a smaller size.
      let prevVideoContainerSize = player.info.getUserPreferredVideoContainerSize(forAspectRatio: oldGeo.videoAspectRatio)
      log.verbose("Before opening outer sidebar(s): restoring previous userPreferredVideoContainerSize")

      return newGeo.scaleVideoContainer(desiredSize: prevVideoContainerSize ?? newGeo.videoContainerSize, constrainedWithin: bestScreen.visibleFrame)
    }
    return newGeo
  }

  // Currently there are 4 bars. Each can be either inside or outside, exclusively.
  func buildMiddleGeometry(forTransition transition: LayoutTransition) -> PlayWindowGeometry {
    if transition.isEnteringMusicMode {
      return transition.inputGeometry.withResizedBars(outsideTopBarHeight: 0,
                                                      outsideTrailingBarWidth: 0,
                                                      outsideBottomBarHeight: 0,
                                                      outsideLeadingBarWidth: 0,
                                                      insideTopBarHeight: 0,
                                                      insideTrailingBarWidth: 0,
                                                      insideBottomBarHeight: 0,
                                                      insideLeadingBarWidth: 0,
                                                      constrainedWithin: bestScreen.visibleFrame)
    } else if transition.isExitingMusicMode {
      // Only bottom bar needs to be closed. No need to constrain in screen
      return transition.inputGeometry.withResizedOutsideBars(newOutsideBottomBarHeight: 0)
    }
    // TOP
    let topBarHeight: CGFloat
    if !transition.isInitialLayout && transition.isTopBarPlacementChanging {
      topBarHeight = 0  // close completely. will animate reopening if needed later
    } else if transition.outputLayout.topBarHeight < transition.inputLayout.topBarHeight {
      topBarHeight = transition.outputLayout.topBarHeight
    } else {
      topBarHeight = transition.inputLayout.topBarHeight  // leave the same
    }
    let insideTopBarHeight = transition.outputLayout.topBarPlacement == .insideVideo ? topBarHeight : 0
    let outsideTopBarHeight = transition.outputLayout.topBarPlacement == .outsideVideo ? topBarHeight : 0

    // BOTTOM
    let insideBottomBarHeight: CGFloat
    let outsideBottomBarHeight: CGFloat
    if !transition.isInitialLayout && transition.isBottomBarPlacementChanging || transition.isTogglingMusicMode {
      // close completely. will animate reopening if needed later
      insideBottomBarHeight = 0
      outsideBottomBarHeight = 0
    } else if transition.outputGeometry.outsideBottomBarHeight < transition.inputGeometry.outsideBottomBarHeight {
      insideBottomBarHeight = 0
      outsideBottomBarHeight = transition.outputGeometry.outsideBottomBarHeight
    } else if transition.outputGeometry.insideBottomBarHeight < transition.inputGeometry.insideBottomBarHeight {
      insideBottomBarHeight = transition.outputGeometry.insideBottomBarHeight
      outsideBottomBarHeight = 0
    } else {
      insideBottomBarHeight = transition.inputGeometry.insideBottomBarHeight
      outsideBottomBarHeight = transition.inputGeometry.outsideBottomBarHeight
    }

    // LEADING
    let insideLeadingBarWidth: CGFloat
    let outsideLeadingBarWidth: CGFloat
    if transition.isHidingLeadingSidebar {
      insideLeadingBarWidth = 0
      outsideLeadingBarWidth = 0
    } else {
      insideLeadingBarWidth = transition.inputGeometry.insideLeadingBarWidth
      outsideLeadingBarWidth = transition.inputGeometry.outsideLeadingBarWidth
    }

    // TRAILING
    let insideTrailingBarWidth: CGFloat
    let outsideTrailingBarWidth: CGFloat
    if transition.isHidingTrailingSidebar {
      insideTrailingBarWidth = 0
      outsideTrailingBarWidth = 0
    } else {
      insideTrailingBarWidth = transition.inputGeometry.insideTrailingBarWidth
      outsideTrailingBarWidth = transition.inputGeometry.outsideTrailingBarWidth
    }

    if transition.outputLayout.isLegacyFullScreen {
      // TODO: store screenFrame in PlayWindowGeometry
      return PlayWindowGeometry(windowFrame: bestScreen.frame,
                                  topMarginHeight: bestScreen.cameraHousingHeight ?? 0,
                                  outsideTopBarHeight: outsideTopBarHeight,
                                  outsideTrailingBarWidth: outsideTrailingBarWidth,
                                  outsideBottomBarHeight: outsideBottomBarHeight,
                                  outsideLeadingBarWidth: outsideLeadingBarWidth,
                                  insideTopBarHeight: insideTopBarHeight,
                                  insideTrailingBarWidth: insideTrailingBarWidth,
                                  insideBottomBarHeight: insideBottomBarHeight,
                                  insideLeadingBarWidth: insideLeadingBarWidth,
                                  videoAspectRatio: videoAspectRatio)
    }

    return transition.outputGeometry.withResizedBars(outsideTopBarHeight: outsideTopBarHeight,
                                                     outsideTrailingBarWidth: outsideTrailingBarWidth,
                                                     outsideBottomBarHeight: outsideBottomBarHeight,
                                                     outsideLeadingBarWidth: outsideLeadingBarWidth,
                                                     insideTopBarHeight: insideTopBarHeight,
                                                     insideTrailingBarWidth: insideTrailingBarWidth,
                                                     insideBottomBarHeight: insideBottomBarHeight,
                                                     insideLeadingBarWidth: insideLeadingBarWidth,
                                                     constrainedWithin: bestScreen.visibleFrame)
  }

  // MARK: - Transition Tasks

  private func doPreTransitionWork(_ transition: LayoutTransition) {
    log.verbose("[\(transition.name)] DoPreTransitionWork")
    controlBarFloating.isDragging = false

    /// Some methods where reference `currentLayout` get called as a side effect of the transition animations.
    /// To avoid possible bugs as a result, let's update this at the very beginning.
    currentLayout = transition.outputLayout

    /// Set this here because we are setting `currentLayout`
    switch transition.outputLayout.spec.mode {
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

        /// Set to `.iinaFloating` instead of `.floating` so that Settings & other windows can be displayed
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
  }

  private func fadeOutOldViews(_ transition: LayoutTransition) {
    let outputLayout = transition.outputLayout
    log.verbose("[\(transition.name)] FadeOutOldViews")

    // Title bar & title bar accessories:

    let needToHideTopBar = transition.isTopBarPlacementChanging || transition.isTogglingLegacyStyle

    // Hide all title bar items if top bar placement is changing
    if needToHideTopBar || outputLayout.titleIconAndText == .hidden {
      apply(visibility: .hidden, documentIconButton, titleTextField)
    }

    if needToHideTopBar || outputLayout.trafficLightButtons == .hidden {
      /// Workaround for Apple bug (as of MacOS 13.3.1) where setting `alphaValue=0` on the "minimize" button will
      /// cause `window.performMiniaturize()` to be ignored. So to hide these, use `isHidden=true` + `alphaValue=1` instead.
      for button in trafficLightButtons {
        button.isHidden = true
      }
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

  private func closeOldPanels(_ transition: LayoutTransition) {
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
      let topBarHeight = transition.inputLayout.topBarPlacement == .insideVideo ? geo.insideTopBarHeight : geo.outsideTopBarHeight
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
        updateSidebarVerticalConstraints(layout: outputLayout)
      }

      let bottomBarHeight = transition.inputLayout.bottomBarPlacement == .insideVideo ? geo.insideBottomBarHeight : geo.outsideBottomBarHeight
      updateBottomBarHeight(to: bottomBarHeight, bottomBarPlacement: transition.inputLayout.bottomBarPlacement)

      // Update title bar item spacing to align with sidebars
      updateSpacingForTitleBarAccessories(transition.outputLayout, windowWidth: transition.outputGeometry.windowFrame.width)

      // Sidebars (if closing)
      animateShowOrHideSidebars(transition: transition, layout: transition.inputLayout,
                                setLeadingTo: transition.isHidingLeadingSidebar ? .hide : nil,
                                setTrailingTo: transition.isHidingTrailingSidebar ? .hide : nil)

      // Do not do this when first opening the window though, because it will cause the window location restore to be incorrect.
      // Also do not apply when toggling fullscreen because it is not relevant at this stage and will cause glitches in the animation.
      if !transition.isInitialLayout && !transition.isExitingFullScreen && !outputLayout.spec.isNativeFullScreen {
        log.debug("Calling setFrame() from closeOldPanels with newWindowFrame \(geo.windowFrame)")
        player.window.setFrameImmediately(geo.windowFrame)
        videoView.updateSizeConstraints(geo.videoSize)
      }
    }

    window.contentView?.layoutSubtreeIfNeeded()
  }

  private func updateHiddenViewsAndConstraints(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let outputLayout = transition.outputLayout
    log.verbose("[\(transition.name)] UpdateHiddenViewsAndConstraints")

    if transition.outputLayout.spec.isLegacyStyle {
      if window.styleMask.contains(.titled) {
        log.verbose("Removing window styleMask.titled")
        window.styleMask.remove(.titled)
        window.styleMask.insert(.borderless)
        window.styleMask.insert(.resizable)
        window.styleMask.insert(.closable)
        window.styleMask.insert(.miniaturizable)
      }
      /// if `isTogglingLegacyStyle==true && isExitingFullScreen==true`, we are toggling out of legacy FS
      /// -> don't change `styleMask` to `.titled` here - it will look bad if screen has camera housing. Change at end of animation
    } else if !transition.outputLayout.spec.isLegacyStyle && !transition.isEnteringFullScreen {
      if !window.styleMask.contains(.titled) {
        log.verbose("Inserting window styleMask.titled")
        window.styleMask.insert(.titled)
        window.styleMask.remove(.borderless)
      }

      // Remove fake traffic light buttons (if any)
      if let fakeLeadingTitleBarView = fakeLeadingTitleBarView {
        for subview in fakeLeadingTitleBarView.subviews {
          subview.removeFromSuperview()
        }
        fakeLeadingTitleBarView.removeFromSuperview()
        self.fakeLeadingTitleBarView = nil
      }

      if transition.isExitingFullScreen {
        /// Setting `.titled` style will show buttons & title by default, but we don't want to show them until after panel open animation:
        for button in trafficLightButtons {
          button.isHidden = true
        }
        window.titleVisibility = .hidden
      }
    }

    applyHiddenOnly(visibility: outputLayout.leadingSidebarToggleButton, to: leadingSidebarToggleButton)
    applyHiddenOnly(visibility: outputLayout.trailingSidebarToggleButton, to: trailingSidebarToggleButton)
    let pinToTopButtonVisibility = transition.outputLayout.computePinToTopButtonVisibility(isOnTop: isOntop)
    applyHiddenOnly(visibility: pinToTopButtonVisibility, to: pinToTopButton)

    if outputLayout.titleIconAndText == .hidden || transition.isTopBarPlacementChanging {
      /// Note: MUST use `titleVisibility` to guarantee that `documentIcon` & `titleTextField` are shown/hidden consistently.
      /// Setting `isHidden=true` on `titleTextField` and `documentIcon` do not animate and do not always work.
      /// We can use `alphaValue=0` to fade out in `fadeOutOldViews()`, but `titleVisibility` is needed to remove them.
      window.titleVisibility = .hidden
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

    /// Show dividing line only for `.outsideVideo` bottom bar. Don't show in music mode as it doesn't look good
    let showBottomBarTopBorder = outputLayout.bottomBarPlacement == .outsideVideo && !outputLayout.isMusicMode
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
  }

  private func openNewPanelsAndFinalizeOffsets(_ transition: LayoutTransition) {
    guard let window = window else { return }
    let outputLayout = transition.outputLayout
    log.verbose("[\(transition.name)] OpenNewPanelsAndFinalizeOffsets. TitleBar_H: \(outputLayout.titleBarHeight), TopOSC_H: \(outputLayout.topOSCHeight)")

    if transition.isEnteringMusicMode {
      miniPlayer.applyVideoViewVisibilityConstraints(isVideoVisible: musicModeGeometry.isVideoVisible)
    }

    if transition.isEnteringNativeFullScreen {
      let videoSize = PlayWindowGeometry.computeVideoSize(withAspectRatio: transition.outputGeometry.videoAspectRatio, toFillIn: bestScreen.visibleFrame.size)
      videoView.updateSizeConstraints(videoSize)
    }

    // Update heights to their final values:
    topOSCHeightConstraint.animateToConstant(outputLayout.topOSCHeight)
    titleBarHeightConstraint.animateToConstant(outputLayout.titleBarHeight)
    osdMinOffsetFromTopConstraint.animateToConstant(outputLayout.osdMinOffsetFromTop)

    // Update heights of top & bottom bars:
    updateTopBarHeight(to: outputLayout.topBarHeight, topBarPlacement: transition.outputLayout.topBarPlacement, cameraHousingOffset: transition.outputGeometry.topMarginHeight)

    let bottomBarHeight = transition.outputLayout.bottomBarPlacement == .insideVideo ? transition.outputGeometry.insideBottomBarHeight : transition.outputGeometry.outsideBottomBarHeight
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
    updateSidebarVerticalConstraints(layout: outputLayout)

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

    if transition.isEnteringNativeFullScreen {
      // Native FullScreen: set frame not including camera housing because it looks better with the native animation
      let newWindowFrame = bestScreen.frameWithoutCameraHousing
      log.verbose("Calling setFrame() to animate into native full screen, to: \(newWindowFrame)")
      player.window.setFrameImmediately(newWindowFrame)
    } else if transition.outputLayout.isLegacyFullScreen {
      let screen = bestScreen
      let newGeo: PlayWindowGeometry
      if transition.isEnteringLegacyFullScreen {
        if (screen.cameraHousingHeight ?? 0) > 0 {
          /// Entering legacy FS on a screen with camera housing.
          /// Prevent an unwanted bouncing near the top by using this animation to expand to visibleFrame.
          /// (will expand window to cover `cameraHousingHeight` in next animation)
          newGeo = transition.outputGeometry.clone(windowFrame: screen.frameWithoutCameraHousing, topMarginHeight: 0)
        } else {
          /// Set window size to `visibleFrame` for now. This excludes menu bar, which takes a while to hide.
          /// Later, when menu bar is hidden, a `NSApplicationDidChangeScreenParametersNotification` will be sent, which will
          /// trigger the window to resize again and cover the whole screen.
          newGeo = transition.outputGeometry.clone(windowFrame: screen.visibleFrame, topMarginHeight: screen.cameraHousingHeight ?? 0)
        }
      } else {
        /// Either already in FS, or entering FS. Set window size to `visibleFrame` for now.
        /// Later, when menu bar is hidden, a `NSApplicationDidChangeScreenParametersNotification` will be sent, which will
        /// trigger the window to resize again and cover the whole screen.
        newGeo = transition.outputGeometry.clone(windowFrame: screen.frame, topMarginHeight: screen.cameraHousingHeight ?? 0)
      }
      log.verbose("Calling setFrame() for legacy full screen in OpenNewPanelsAndFinalizeOffsets")
      setWindowFrameForLegacyFullScreen(using: newGeo)
    } else if outputLayout.isMusicMode {
      // Especially needed when applying initial layout:
      applyMusicModeGeometry(musicModeGeometry)
    } else if !outputLayout.isFullScreen {
      let newWindowFrame = transition.outputGeometry.windowFrame
      log.verbose("Calling setFrame() from openNewPanelsAndFinalizeOffsets with newWindowFrame \(newWindowFrame)")
      videoView.updateSizeConstraints(transition.outputGeometry.videoSize)
      player.window.setFrameImmediately(newWindowFrame)
    }
  }

  private func fadeInNewViews(_ transition: LayoutTransition) {
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
    } else {
      /// Special case for `trafficLightButtons` due to quirks. Do not use `fadeableViews`. ALways set `alphaValue = 1`.
      for button in trafficLightButtons {
        button.alphaValue = 1
      }
      titleTextField?.alphaValue = 1
      documentIconButton?.alphaValue = 1

      if outputLayout.trafficLightButtons != .hidden {

        // TODO: figure out whether to try to replicate title bar, or just leave it out
        if false && outputLayout.spec.isLegacyStyle && fakeLeadingTitleBarView == nil {
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
          leadingStackView.heightAnchor.constraint(equalToConstant: PlayWindowController.standardTitleBarHeight).isActive = true
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

    applyShowableOnly(visibility: outputLayout.leadingSidebarToggleButton, to: leadingSidebarToggleButton)
    applyShowableOnly(visibility: outputLayout.trailingSidebarToggleButton, to: trailingSidebarToggleButton)
    updatePinToTopButton()

    // Add back title bar accessories (if needed):
    applyShowableOnly(visibility: outputLayout.titlebarAccessoryViewControllers, to: leadingTitleBarAccessoryView)
    applyShowableOnly(visibility: outputLayout.titlebarAccessoryViewControllers, to: trailingTitleBarAccessoryView)
  }

  private func doPostTransitionWork(_ transition: LayoutTransition) {
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

      // Make sure legacy FS styling is removed always
      window.styleMask.insert(.resizable)
      if #available(macOS 10.16, *) {
        window.level = .normal
      } else {
        window.styleMask.remove(.fullScreen)
      }

      if transition.isExitingLegacyFullScreen {
        restoreDockSettings()
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

      if transition.outputLayout.spec.isLegacyStyle {
        log.verbose("Removing window styleMask.titled")
        window.styleMask.remove(.titled)
        window.styleMask.insert(.borderless)

        window.titleVisibility = .hidden
      } else {
        // Go back to titled style
        if #available(macOS 10.16, *) {
          log.verbose("Inserting window styleMask.titled")
          window.styleMask.insert(.titled)
          window.styleMask.remove(.borderless)
        }

        // Workaround for AppKit quirk : do this here to ensure document icon & title don't get stuck in "visible" or "hidden" states
        apply(visibility: transition.outputLayout.titleIconAndText, documentIconButton, titleTextField)
        for button in trafficLightButtons {
          /// Special case for fullscreen transition due to quirks of `trafficLightButtons`.
          /// In most cases it's best to avoid setting `alphaValue = 0` for these because doing so will disable their menu items,
          /// but should be ok for brief animations
          button.alphaValue = 1
          button.isHidden = false
        }
        window.titleVisibility = .visible
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

      resetCollectionBehavior()
      updateWindowParametersForMPV()

      player.events.emit(.windowFullscreenChanged, data: false)
    }
    
    videoView.needsLayout = true
    videoView.layoutSubtreeIfNeeded()
    forceDraw()
    // Need to make sure this executes after styleMask is .titled
    addTitleBarAccessoryViews()
    log.verbose("[\(transition.name)] Done with transition. IsFullScreen:\(transition.outputLayout.isFullScreen.yn), IsLegacy:\(transition.outputLayout.spec.isLegacyStyle), Mode:\(currentLayout.spec.mode)")
    player.saveState()
  }

  // MARK: - Bars Layout

  // - Top bar

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
    log.verbose("Updating topBar placement to: \(placement)")
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

  func updateTopBarHeight(to topBarHeight: CGFloat, topBarPlacement: Preference.PanelPlacement, cameraHousingOffset: CGFloat) {
    log.verbose("Updating topBar height: \(topBarHeight), placement: \(topBarPlacement), cameraOffset: \(cameraHousingOffset)")

    switch topBarPlacement {
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

  // - Bottom bar

  private func updateBottomBarPlacement(placement: Preference.PanelPlacement) {
    log.verbose("Updating bottomBar placement to: \(placement)")
    guard let window = window, let contentView = window.contentView else { return }
    contentView.removeConstraint(bottomBarLeadingSpaceConstraint)
    contentView.removeConstraint(bottomBarTrailingSpaceConstraint)

    switch placement {
    case .insideVideo:
      // Align left & right sides with sidebars (top bar will squeeze to make space for sidebars)
      bottomBarLeadingSpaceConstraint = bottomBarView.leadingAnchor.constraint(equalTo: leadingSidebarView.trailingAnchor, constant: 0)
      bottomBarTrailingSpaceConstraint = bottomBarView.trailingAnchor.constraint(equalTo: trailingSidebarView.leadingAnchor, constant: 0)
    case .outsideVideo:
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

  /// After bars are shown or hidden, or their placement changes, this ensures that their shadows appear in the correct places.
  /// • Outside bars never cast shadows or have shadows cast on them.
  /// • Inside sidebars cast shadows over inside top bar & inside bottom bar, and over `videoContainerView`.
  /// • Inside top & inside bottom bars do not cast shadows over `videoContainerView`.
  private func updateDepthOrderOfBars(topBar: Preference.PanelPlacement, bottomBar: Preference.PanelPlacement,
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

  // MARK: - Title bar items

  func addTitleBarAccessoryViews() {
    guard let window = window else { return }
    if leadingTitlebarAccesoryViewController == nil {
      let controller = NSTitlebarAccessoryViewController()
      leadingTitlebarAccesoryViewController = controller
      controller.view = leadingTitleBarAccessoryView
      controller.layoutAttribute = .leading

      leadingTitleBarAccessoryView.heightAnchor.constraint(equalToConstant: PlayWindowController.standardTitleBarHeight).isActive = true
    }
    if trailingTitlebarAccesoryViewController == nil {
      let controller = NSTitlebarAccessoryViewController()
      trailingTitlebarAccesoryViewController = controller
      controller.view = trailingTitleBarAccessoryView
      controller.layoutAttribute = .trailing

      trailingTitleBarAccessoryView.heightAnchor.constraint(equalToConstant: PlayWindowController.standardTitleBarHeight).isActive = true
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
    let isPinToTopButtonShowable = layout.computePinToTopButtonVisibility(isOnTop: isOntop).isShowable

    if layout.trailingSidebarToggleButton.isShowable {
      spaceForButtons += trailingSidebarToggleButton.frame.width
    }
    if isPinToTopButtonShowable {
      spaceForButtons += pinToTopButton.frame.width
    }

    let leadingSpaceNeeded: CGFloat = layout.topBarPlacement == .outsideVideo ? 0 : max(0, layout.trailingSidebar.currentWidth - spaceForButtons)
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
    // Fullscreen + "behindWindow" doesn't blend properly and looks ugly
    if outputLayout.topBarPlacement == .insideVideo || outputLayout.isFullScreen {
      topBarView.blendingMode = .withinWindow
    } else {
      topBarView.blendingMode = .behindWindow
    }

    // Fullscreen + "behindWindow" doesn't blend properly and looks ugly
    if outputLayout.bottomBarPlacement == .insideVideo || outputLayout.isFullScreen {
      bottomBarView.blendingMode = .withinWindow
    } else {
      bottomBarView.blendingMode = .behindWindow
    }

    updateSidebarBlendingMode(.leadingSidebar, layout: outputLayout)
    updateSidebarBlendingMode(.trailingSidebar, layout: outputLayout)
  }

}
