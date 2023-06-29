//
//  MainWindowMenuActions.swift
//  iina
//
//  Created by lhc on 13/8/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

extension MainWindowController {

  @objc func menuShowPlaylistPanel(_ sender: NSMenuItem) {
    showSidebar(tab: .playlist)
  }

  @objc func menuShowChaptersPanel(_ sender: NSMenuItem) {
    showSidebar(tab: .chapters)
  }

  @objc func menuShowVideoQuickSettings(_ sender: NSMenuItem) {
    showSidebar(tab: .video)
  }

  @objc func menuShowAudioQuickSettings(_ sender: NSMenuItem) {
    showSidebar(tab: .audio)
  }

  @objc func menuShowSubQuickSettings(_ sender: NSMenuItem) {
    showSidebar(tab: .sub)
  }

  @objc func menuChangeWindowSize(_ sender: NSMenuItem) {
    let size = sender.tag
    guard let window = window, !fsState.isFullscreen else { return }

    switch size {
    case 0:  //  0: half
      setWindowScale(0.5)
    case 1:  //  1: normal
      setWindowScale(1)
    case 2:  //  2: double
      setWindowScale(2)
    case 3:  // fit screen
      window.center()  // FIXME: this should be animated
      let (videoWidth, videoHeight) = player.videoSizeForDisplay
      let desiredVideoSize = CGSize(width: CGFloat(videoWidth), height: CGFloat(videoHeight)).satisfyMinSizeWithSameAspectRatio(bestScreen.visibleFrame.size)
      Logger.log("Scaling video to fit screen (calculated size: \(desiredVideoSize))", level: .verbose, subsystem: player.subsystem)
      resizeVideo(toVideoSize: desiredVideoSize)
    case 10:  // smaller size
      scaleVideoByIncrement(-AppData.scaleStep)
    case 11:  // bigger size
      scaleVideoByIncrement(AppData.scaleStep)
    default:
      return
    }
  }

  func scaleVideoByIncrement(_ step: CGFloat) {
    let currentVideoSize = videoView.frame.size
    let newWidth = currentVideoSize.width + step
    let newHeight = newWidth / currentVideoSize.aspect
    let desiredVideoSize = CGSize(width: currentVideoSize.width + step, height: newHeight)
    Logger.log("Incrementing video width by \(step), to desired size \(desiredVideoSize)", level: .verbose, subsystem: player.subsystem)
    resizeVideo(toVideoSize: desiredVideoSize)
  }

  @objc func menuAlwaysOnTop(_ sender: AnyObject) {
    setWindowFloatingOnTop(!isOntop)
  }

  @available(macOS 10.12, *)
  @objc func menuTogglePIP(_ sender: NSMenuItem) {
    switch pipStatus {
    case .notInPIP:
      enterPIP()
    case .inPIP:
      exitPIP()
    default:
      return
    }
  }

  @objc func menuToggleFullScreen(_ sender: NSMenuItem) {
    toggleWindowFullScreen()
  }

  @objc func menuSwitchToMiniPlayer(_ sender: NSMenuItem) {
    player.switchToMiniPlayer()
  }

  @objc func menuSetDelogo(_ sender: NSMenuItem) {
    if sender.state == .on {
      if let filter = player.info.delogoFilter {
        let _ = player.removeVideoFilter(filter)
        player.info.delogoFilter = nil
      }
    } else {
      self.hideAllSidebars {
        self.enterInteractiveMode(.freeSelecting)
      }
    }
  }
}
