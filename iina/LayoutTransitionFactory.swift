//
//  PlayerWindowLayout.swift
//  iina
//
//  Created by Matt Svoboda on 8/20/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/// This file is not really a factory class due to limitations of the AppKit paradigm, but it contain
/// methods for creating/running `LayoutTransition`s to change between `LayoutState`s for the
/// given `PlayerWindowController`.
extension PlayerWindowController {

  // MARK: - Window Initial Layout

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

    let screen = bestScreen

    // - Build outputLayout

    let outputLayout = LayoutState.from(outputSpec)

    // - Build geometries

    // Build InputGeometry
    let inputGeometry: PlayerWindowGeometry
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
      inputGeometry = musicModeGeometry.constrainWithin(bestScreen.visibleFrame).toPlayerWindowGeometry()
    }
    log.verbose("[\(transitionName)] Built inputGeometry: \(inputGeometry)")

    // Build OutputGeometry
    let outputGeometry: PlayerWindowGeometry = buildOutputGeometry(inputGeometry: inputGeometry, outputLayout: outputLayout)

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

    // Extra animation for entering legacy full screen: cover camera housing with black bar
    let useExtraAnimationForEnteringLegacyFullScreen = transition.isEnteringLegacyFullScreen && screen.hasCameraHousing && !transition.isInitialLayout

    let openFinalPanelsDuration = useExtraAnimationForEnteringLegacyFullScreen ? (endingAnimationDuration * 0.8) : endingAnimationDuration

    let useExtraAnimationForExitingLegacyFullScreen = transition.isExitingLegacyFullScreen && screen.hasCameraHousing && !transition.isInitialLayout

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
    if useExtraAnimationForExitingLegacyFullScreen && !transition.outputLayout.spec.isLegacyStyle {
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
      let closeOldPanelsDuration = useExtraAnimationForExitingLegacyFullScreen ? (startingAnimationDuration * 0.8) : startingAnimationDuration
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

    // Extra animation for exiting legacy full screen to legacy windowed mode, if black space around camera housing
    if useExtraAnimationForExitingLegacyFullScreen && transition.outputLayout.spec.isLegacyStyle {
      transition.animationTasks.append(CocoaAnimation.Task(duration: endingAnimationDuration * 0.2, timing: .easeIn, { [self] in
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

    // If entering legacy full screen, will add an extra animation to hiding camera housing / menu bar / dock
    if useExtraAnimationForEnteringLegacyFullScreen {
      transition.animationTasks.append(CocoaAnimation.Task(duration: endingAnimationDuration * 0.2, timing: .easeIn, { [self] in
        let screen = bestScreen
        let topBlackBarHeight = Preference.bool(for: .allowVideoToOverlapCameraHousing) ? 0 : screen.cameraHousingHeight ?? 0
        let newGeo = transition.outputGeometry.clone(windowFrame: screen.frame, topMarginHeight: topBlackBarHeight)
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
  private func buildOutputGeometry(inputGeometry oldGeo: PlayerWindowGeometry, outputLayout: LayoutState) -> PlayerWindowGeometry {
    switch outputLayout.spec.mode {

    case .musicMode:
      /// `videoAspectRatio` may have gone stale while not in music mode. Update it (playlist height will be recalculated if needed):
      let musicModeGeometryCorrected = musicModeGeometry.clone(videoAspectRatio: videoAspectRatio).constrainWithin(bestScreen.visibleFrame)
      return musicModeGeometryCorrected.toPlayerWindowGeometry()

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
  func buildMiddleGeometry(forTransition transition: LayoutTransition) -> PlayerWindowGeometry {
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
      // TODO: store screenFrame in PlayerWindowGeometry
      return PlayerWindowGeometry(windowFrame: bestScreen.frame,
                                  topMarginHeight: transition.outputGeometry.topMarginHeight,
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
}
