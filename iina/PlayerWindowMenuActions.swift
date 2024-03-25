//
//  PlayerWindowMenuActions.swift
//  iina
//
//  Created by lhc on 25/12/2016.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

extension PlayerWindowController {

  @objc func menuShowInspector(_ sender: AnyObject) {
    AppDelegate.shared.showInspectorWindow()
  }

  @objc func menuSavePlaylist(_ sender: NSMenuItem) {
    Utility.quickSavePanel(title: "Save to playlist", types: ["m3u8"], sheetWindow: player.window) { [self] (url) in
      if url.isFileURL {
        let playlistItems = player.info.playlist
        var playlist = ""
        for item in playlistItems {
          playlist.append((item.filename + "\n"))
        }

        do {
          try playlist.write(to: url, atomically: true, encoding: String.Encoding.utf8)
        } catch let error as NSError {
          Utility.showAlert("error_saving_file", arguments: ["subtitle",
                                                            error.localizedDescription])
        }
      }
    }
  }

  @objc func menuDeleteCurrentFile(_ sender: NSMenuItem) {
    guard let url = player.info.currentURL else { return }
    do {
      let index = player.mpv.getInt(MPVProperty.playlistPos)
      player.playlistRemove(index)
      try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    } catch let error {
      Utility.showAlert("playlist.error_deleting", arguments: [error.localizedDescription])
    }
  }

  // currently only being used for key command
  @objc func menuDeleteCurrentFileHard(_ sender: NSMenuItem) {
    guard let url = player.info.currentURL else { return }
    do {
      let index = player.mpv.getInt(MPVProperty.playlistPos)
      player.playlistRemove(index)
      try FileManager.default.removeItem(at: url)
    } catch let error {
      Utility.showAlert("playlist.error_deleting", arguments: [error.localizedDescription])
    }
  }

  // MARK: - Control

  @objc func menuTogglePause(_ sender: NSMenuItem) {
    player.togglePause()
  }

  @objc func menuStop(_ sender: NSMenuItem) {
    player.stop()
  }

  @objc func menuStep(_ sender: NSMenuItem) {
    if let args = sender.representedObject as? (Double, Preference.SeekOption) {
      player.seek(relativeSecond: args.0, option: args.1)
    } else if let args = sender.representedObject as? Double {
      player.seek(relativeSecond: args, option: Preference.SeekOption.defaultValue)
    }
    else {
      player.seek(relativeSecond: 5, option: Preference.SeekOption.defaultValue)
    }
  }

  @objc func menuStepPrevFrame(_ sender: NSMenuItem) {
    if player.info.isPlaying {
      player.pause()
    }
    player.frameStep(backwards: true)
  }

  @objc func menuStepNextFrame(_ sender: NSMenuItem) {
    if player.info.isPlaying {
      player.pause()
    }
    player.frameStep(backwards: false)
  }

  @objc func menuChangeSpeed(_ sender: NSMenuItem) {
    if sender.tag == 5 {
      player.setSpeed(1)
      return
    }
    if let multiplier = sender.representedObject as? Double {
      player.setSpeed(player.info.playSpeed * multiplier)
    }
  }

  @objc func menuJumpToBegin(_ sender: NSMenuItem) {
    player.seek(absoluteSecond: 0)
  }

  @objc func menuJumpTo(_ sender: NSMenuItem) {
    Utility.quickPromptPanel("jump_to", inputValue: self.player.info.videoPosition?.stringRepresentationWithPrecision(3)) { input in
      if let vt = VideoTime(input) {
        self.player.seek(absoluteSecond: Double(vt.second))
      }
    }
  }

  @objc func menuSnapshot(_ sender: NSMenuItem) {
    player.screenshot()
  }

  @objc func menuABLoop(_ sender: NSMenuItem) {
    player.windowController.abLoop()
  }

  @objc func menuFileLoop(_ sender: NSMenuItem) {
    player.toggleFileLoop()
  }

  @objc func menuPlaylistLoop(_ sender: NSMenuItem) {
    player.togglePlaylistLoop()
  }

  @objc func menuPlaylistItem(_ sender: NSMenuItem) {
    let index = sender.tag
    player.playFileInPlaylist(index)
  }

  @objc func menuChapterSwitch(_ sender: NSMenuItem) {
    let index = sender.tag
    guard let chapter = player.playChapter(index) else {
      Logger.log("Cannot switch to chapter \(index) because it was not found! Will ignore request and reload chapters instead",
                 level: .error, subsystem: player.subsystem)
      player.reloadChapters()
      return
    }
    player.sendOSD(.chapter(chapter.title))
  }

  @objc func menuChangeTrack(_ sender: NSMenuItem) {
    if let trackObj = sender.representedObject as? (MPVTrack, MPVTrack.TrackType) {
      player.setTrack(trackObj.0.id, forType: trackObj.1)
    } else if let trackObj = sender.representedObject as? MPVTrack {
      player.setTrack(trackObj.id, forType: trackObj.type)
    }
  }

  @objc func menuNextMedia(_ sender: NSMenuItem) {
    player.navigateInPlaylist(nextMedia: true)
  }

  @objc func menuPreviousMedia(_ sender: NSMenuItem) {
    player.navigateInPlaylist(nextMedia: false)
  }

  @objc func menuNextChapter(_ sender: NSMenuItem) {
    player.mpv.queue.async { [self] in
      player.mpv.command(.add, args: ["chapter", "1"], checkError: false)
    }
  }

  @objc func menuPreviousChapter(_ sender: NSMenuItem) {
    player.mpv.queue.async { [self] in
      player.mpv.command(.add, args: ["chapter", "-1"], checkError: false)
    }
  }

// MARK: - Video

  @objc func menuChangeAspect(_ sender: NSMenuItem) {
    if let aspectStr = sender.representedObject as? String {
      player.log.verbose("Setting aspect ratio from menu item: \(aspectStr)")
      player.setVideoAspectOverride(aspectStr)
    } else {
      player.log.error("Unknown aspect in menuChangeAspect(): \(sender.representedObject.debugDescription)")
    }
  }

  @objc func menuChangeCrop(_ sender: NSMenuItem) {
    if let cropStr = sender.representedObject as? String {
      if cropStr == AppData.customCropIdentifier {
        player.windowController.enterInteractiveMode(.crop)
        return
      }
      player.setCrop(fromAspectString: cropStr)
    } else {
      Logger.log("sender.representedObject is not a string in menuChangeCrop()", level: .error)
    }
  }

  @objc func menuChangeRotation(_ sender: NSMenuItem) {
    if let rotationInt = sender.representedObject as? Int {
      player.setVideoRotate(rotationInt)
    }
  }

  @objc func menuToggleFlip(_ sender: NSMenuItem) {
    if player.info.flipFilter == nil {
      player.setFlip(true)
    } else {
      player.setFlip(false)
    }
  }

  @objc func menuToggleMirror(_ sender: NSMenuItem) {
    if player.info.mirrorFilter == nil {
      player.setMirror(true)
    } else {
      player.setMirror(false)
    }
  }

  @objc func menuToggleDeinterlace(_ sender: NSMenuItem) {
    player.toggleDeinterlace(sender.state != .on)
  }

  @objc
  func menuToggleVideoFilterString(_ sender: NSMenuItem) {
    if let string = (sender.representedObject as? String) {
      menuToggleFilterString(string, forType: MPVProperty.vf)
    }
  }

  private func menuToggleFilterString(_ string: String, forType type: String) {
    let isVideo = type == MPVProperty.vf
    if let filter = MPVFilter(rawString: string) {
      // Removing a filter based on its position within the filter list is the preferred way to do
      // it as per discussion with the mpv project. Search the list of filters and find the index
      // of the specified filter (if present).
      if let index = player.mpv.getFilters(type).firstIndex(of: filter) {
        // remove
        if isVideo {
          _ = player.removeVideoFilter(filter, index)
        } else {
          _ = player.removeAudioFilter(filter, index)
        }
      } else {
        // add
        if isVideo {
          if !player.addVideoFilter(filter) {
            Utility.showAlert("filter.incorrect")
          }
        } else {
          if !player.addAudioFilter(filter) {
            Utility.showAlert("filter.incorrect")
          }
        }
      }
    }
    let vfWindow = AppDelegate.shared.vfWindow
    if vfWindow.isWindowLoaded {
      vfWindow.reloadTable()
    }
  }

  // MARK: - Audio

  @objc func menuChangeVolume(_ sender: NSMenuItem) {
    if let volumeDelta = sender.representedObject as? Int {
      let newVolume = Double(volumeDelta) + player.info.volume
      player.setVolume(newVolume)
    } else {
      Logger.log("sender.representedObject is not int in menuChangeVolume()", level: .error)
    }
  }

  @objc func menuToggleMute(_ sender: NSMenuItem) {
    player.toggleMute()
  }

  @objc func menuChangeAudioDelay(_ sender: NSMenuItem) {
    if let delayDelta = sender.representedObject as? Double {
      let newDelay = player.info.audioDelay + delayDelta
      player.setAudioDelay(newDelay)
    } else {
      Logger.log("sender.representedObject is not Double in menuChangeAudioDelay()", level: .error)
    }
  }

  @objc func menuResetAudioDelay(_ sender: NSMenuItem) {
    player.setAudioDelay(0)
  }

  @objc
  func menuToggleAudioFilterString(_ sender: NSMenuItem) {
    if let string = (sender.representedObject as? String) {
      menuToggleFilterString(string, forType: MPVProperty.af)
    }
  }

  // MARK: - Sub

  @objc func menuLoadExternalSub(_ sender: NSMenuItem) {
    let currentDir = player.info.currentURL?.deletingLastPathComponent()
    Utility.quickOpenPanel(title: "Load external subtitle file", chooseDir: false, dir: currentDir,
                           sheetWindow: player.window) { url in
      self.player.loadExternalSubFile(url, delay: true)
    }
  }

  @objc func menuToggleSubVisibility(_ sender: NSMenuItem) {
    player.toggleSubVisibility()
  }

  @objc func menuToggleSecondSubVisibility(_ sender: NSMenuItem) {
    player.toggleSecondSubVisibility()
  }

  @objc func menuChangeSubDelay(_ sender: NSMenuItem) {
    if let delayDelta = sender.representedObject as? Double {
      let newDelay = player.info.subDelay + delayDelta
      player.setSubDelay(newDelay)
    } else {
      Logger.log("sender.representedObject is not Double in menuChangeSubDelay()", level: .error)
    }
  }

  @objc func menuChangeSubScale(_ sender: NSMenuItem) {
    if sender.tag == 0 {
      player.setSubScale(1)
      return
    }
    // FIXME: better refactor this part
    let amount = sender.tag > 0 ? 0.1 : -0.1
    let currentScale = player.mpv.getDouble(MPVOption.Subtitles.subScale)
    let displayValue = currentScale >= 1 ? currentScale : -1/currentScale
    let truncated = round(displayValue * 100) / 100
    var newTruncated = truncated + amount
    // range for this value should be (~, -1), (1, ~)
    if newTruncated > 0 && newTruncated < 1 || newTruncated > -1 && newTruncated < 0 {
      newTruncated = -truncated + amount
    }
    player.setSubScale(abs(newTruncated > 0 ? newTruncated : 1 / newTruncated))
  }

  @objc func menuResetSubDelay(_ sender: NSMenuItem) {
    player.setSubDelay(0)
  }

  @objc func menuSetSubEncoding(_ sender: NSMenuItem) {
    player.setSubEncoding((sender.representedObject as? String) ?? "auto")
    player.reloadAllSubs()
  }

  @objc func menuSubFont(_ sender: NSMenuItem) {
    Utility.quickFontPickerWindow() {
      self.player.setSubFont($0 ?? "")
    }
  }

  @objc func menuFindOnlineSub(_ sender: NSMenuItem) {
    // return if last search is not finished
    guard let url = player.info.currentURL, !player.isSearchingOnlineSubtitle else { return }

    player.isSearchingOnlineSubtitle = true
    log.debug("Finding online subtitles")
    OnlineSubtitle.search(forFile: url, player: player, providerID: sender.representedObject as? String) { [self] urls in
      if urls.isEmpty {
        player.sendOSD(.foundSub(0))
      } else {
        for url in urls {
          Logger.log("Saved subtitle to \(url.path.pii.quoted)")
          player.loadExternalSubFile(url)
        }
        player.sendOSD(.downloadedSub(
          urls.map({ $0.lastPathComponent }).joined(separator: "\n")
        ))
        player.info.haveDownloadedSub = true
      }
      player.isSearchingOnlineSubtitle = false
    }
  }

  @objc func saveDownloadedSub(_ sender: NSMenuItem) {
    let selected = player.info.subTracks.filter { $0.id == player.info.sid }
    guard selected.count > 0 else {
      Utility.showAlert("sub.no_selected")

      return
    }
    let sub = selected[0]
    // make sure it's a downloaded sub
    guard let path = sub.externalFilename, path.contains("/var/") else {
      Utility.showAlert("sub.no_selected")
      return
    }
    let subURL = URL(fileURLWithPath: path)
    let subFileName = subURL.lastPathComponent
    let windowTitle = NSLocalizedString("alert.sub.save_downloaded.title", comment: "Save Downloaded Subtitle")
    Utility.quickSavePanel(title: windowTitle, filename: subFileName, sheetWindow: self.window) { (destURL) in
      do {
        // The Save panel checks to see if a file already exists and if so asks if it should be
        // replaced. The quickSavePanel would not have called this code if the user canceled, so if
        // the destination file already exists move it to the trash.
        do {
          try FileManager.default.trashItem(at: destURL, resultingItemURL: nil)
            Logger.log("Trashed existing subtitle file \(destURL)")
          } catch CocoaError.fileNoSuchFile {
            // Expected, ignore error. The Apple Secure Coding Guide in the section Race Conditions
            // and Secure File Operations recommends attempting an operation and handling errors
            // gracefully instead of trying to figure out ahead of time whether the operation will
            // succeed.
          }
          try FileManager.default.copyItem(at: subURL, to: destURL)
          Logger.log("Saved downloaded subtitle to \(destURL.path)")
          self.player.sendOSD(.savedSub)
      } catch let error as NSError {
        Utility.showAlert("error_saving_file", arguments: ["subtitle", error.localizedDescription])
      }
    }
  }

  @objc func menuCycleTrack(_ sender: NSMenuItem) {
    player.mpv.queue.async { [self] in
      switch sender.tag {
      case 0: player.mpv.command(.cycle, args: ["video"])
      case 1: player.mpv.command(.cycle, args: ["audio"])
      case 2: player.mpv.command(.cycle, args: ["sub"])
      default: break
      }
    }
  }

  @objc func menuShowPlaylistPanel(_ sender: NSMenuItem) {
    showSidebar(tab: .playlist)
  }

  @objc func menuShowChaptersPanel(_ sender: NSMenuItem) {
    showSidebar(tab: .chapters)
  }

  @objc func menuToggleUI(_ sender: NSMenuItem) {
    
    player.disableUI = !player.disableUI
    if player.disableUI {
      player.windowController.hideFadeableViewsAndCursor()
    }
    
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

    log.verbose("ChangeWindowSize requested from menu, option: \(size)")
    switch size {
    case 0:  //  0: half
      setVideoScale(0.5)
    case 1:  //  1: normal
      setVideoScale(1)
    case 2:  //  2: double
      setVideoScale(2)
    case 3:  // fit screen
      resizeViewport(to: bestScreen.visibleFrame.size, centerOnScreen: true)

    case 10:  // smaller size
      scaleVideoByIncrement(-AppData.scaleStep)
    case 11:  // bigger size
      scaleVideoByIncrement(AppData.scaleStep)
    default:
      return
    }
  }

  @objc func menuAlwaysOnTop(_ sender: AnyObject) {
    self.toggleOnTop(sender)
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
