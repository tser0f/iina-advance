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

    switch size {
    case 0:  //  0: half
      setWindowScale(0.5)
    case 1:  //  1: normal
      setWindowScale(1)
    case 2:  //  2: double
      setWindowScale(2)
    case 3:  // fit screen
      resizeVideoContainer(desiredVideoContainerSize: bestScreen.visibleFrame.size, centerOnScreen: true)

    case 10:  // smaller size
      scaleVideoByIncrement(-AppData.scaleStep)
    case 11:  // bigger size
      scaleVideoByIncrement(AppData.scaleStep)
    default:
      return
    }
  }

  func scaleVideoByIncrement(_ widthStep: CGFloat) {
    let currentVideoContainerSize = videoContainerView.frame.size
    let heightStep = widthStep / currentVideoContainerSize.aspect
    let desiredVideoContainerSize = CGSize(width: currentVideoContainerSize.width + widthStep, height: currentVideoContainerSize.height + heightStep)
    log.verbose("Incrementing videoContainer width by \(widthStep), to desired size \(desiredVideoContainerSize)")
    resizeVideoContainer(desiredVideoContainerSize: desiredVideoContainerSize)
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

  @objc func menuSetDelogo(_ sender: NSMenuItem) {
    if sender.state == .on {
      if let filter = player.info.delogoFilter {
        let _ = player.removeVideoFilter(filter)
        player.info.delogoFilter = nil
      }
    } else {
      self.enterInteractiveMode(.freeSelecting)
    }
  }
}
