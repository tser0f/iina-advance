//
//  PlayerSaveState.swift
//  iina
//
//  Created by Matt Svoboda on 8/6/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

// Data structure for saving to prefs / restoring from prefs the UI state of a single player window
struct PlayerSaveState {
  enum PropName: String {
    case launchID = "launchID"

    case playlistPaths = "playlistPaths"

    case userPreferredVideoContainerSizeWide = "userVidConSize_Wide"
    case userPreferredVideoContainerSizeTall = "userVidConSize_Tall"
    case windowGeometry = "windowGeometry"
    case layoutSpec = "layoutSpec"
    case isMinimized = "minimized"
    case isMusicMode = "musicMode"
    case isOnTop = "onTop"

    case url = "url"
    case progress = "progress"        /// `MPVOption.PlaybackControl.start`
    case paused = "paused"            /// `MPVOption.PlaybackControl.pause`

    case vid = "vid"                  /// `MPVOption.TrackSelection.vid`
    case aid = "aid"                  /// `MPVOption.TrackSelection.aid`
    case sid = "sid"                  /// `MPVOption.TrackSelection.sid`
    case sid2 = "sid2"                /// `MPVOption.Subtitles.secondarySid`

    case hwdec = "hwdec"              /// `MPVOption.Video.hwdec`
    case deinterlace = "deinterlace"  /// `MPVOption.Video.deinterlace`
    case hdrEnabled = "hdrEnabled"    /// IINA setting

    case brightness = "brightness"    /// `MPVOption.Equalizer.brightness`
    case contrast = "contrast"        /// `MPVOption.Equalizer.contrast`
    case saturation = "saturation"    /// `MPVOption.Equalizer.saturation`
    case gamma = "gamma"              /// `MPVOption.Equalizer.gamma`
    case hue = "hue"                  /// `MPVOption.Equalizer.hue`

    case videoFilters = "vf"          /// `MPVProperty.vf`
    case audioFilters = "af"          /// `MPVProperty.af`

    case playSpeed = "playSpeed"      /// `MPVOption.PlaybackControl.speed`
    case volume = "volume"            /// `MPVOption.Audio.volume`
    case isMuted = "muted"            /// `MPVOption.Audio.mute`
    case maxVolume = "maxVolume"      /// `MPVOption.Audio.volumeMax`
    case audioDelay = "audioDelay"    /// `MPVOption.Audio.audioDelay`
    case subDelay = "subDelay"        /// `MPVOption.Subtitles.subDelay`
    case abLoopA = "abLoopA"          /// `MPVOption.PlaybackControl.abLoopA`
    case abLoopB = "abLoopB"          /// `MPVOption.PlaybackControl.abLoopB`
    case videoRotation = "videoRotate"/// `MPVOption.Video.videoRotate`

    case isSubVisible = "subVisible"  /// `MPVOption.Subtitles.subVisibility`
    case isSub2Visible = "sub2Visible"/// `MPVOption.Subtitles.secondarySubVisibility`
    case subScale = "subScale"        /// `MPVOption.Subtitles.subScale`
    case subPos = "subPos"            /// `MPVOption.Subtitles.subPos`
    case loopPlaylist = "loopPlaylist"/// `MPVOption.PlaybackControl.loopPlaylist`
    case loopFile = "loopFile"        /// `MPVOption.PlaybackControl.loopFile`
  }

  static private let specPrefStringVersion = "1"
  static private let specErrPre = "Failed to parse LayoutSpec from string:"
  static private let geoErrPre = "Failed to parse WindowGeometry from string:"
  static private let geoPrefStringVersion = "1"

  let properties: [String: Any]

  /// Cached values parsed from `properties`

  /// Describes the current layout configuration of the player window
  let layoutSpec: MainWindowController.LayoutSpec?
  /// If in fullscreen, this is actually the `priorWindowedGeometry`
  let windowGeometry: MainWindowGeometry?

  init(_ props: [String: Any]) {
    self.properties = props

    self.layoutSpec = PlayerSaveState.deserializeLayoutSpec(from: props)
    self.windowGeometry = PlayerSaveState.deserializeWindowGeometry(from: props)
  }

  // MARK: - Save State / Serialize to prefs strings

  /// `MainWindowGeometry` -> String
  private static func toCSV(_ geo: MainWindowGeometry) -> String {
    return [geoPrefStringVersion,
            geo.videoAspectRatio.string6f,
            geo.topBarHeight.string2f,
            geo.trailingBarWidth.string2f,
            geo.bottomBarHeight.string2f,
            geo.leadingBarWidth.string2f,
            geo.insideBarLeadingWidth.string2f,
            geo.insideBarTrailingWidth.string2f,
            geo.windowFrame.origin.x.string2f,
            geo.windowFrame.origin.y.string2f,
            geo.windowFrame.width.string2f,
            geo.windowFrame.height.string2f].joined(separator: ",")
  }

  /// `LayoutSpec` -> String
  private static func toCSV(_ spec: MainWindowController.LayoutSpec) -> String {
    let leadingSidebarTab: String = spec.leadingSidebar.visibleTab?.name ?? "nil"
    let trailingSidebarTab: String = spec.trailingSidebar.visibleTab?.name ?? "nil"
    return [specPrefStringVersion,
            leadingSidebarTab,
            trailingSidebarTab,
            String(spec.mode.rawValue),
            spec.isLegacyStyle.yn,
            String(spec.topBarPlacement.rawValue),
            String(spec.trailingSidebarPlacement.rawValue),
            String(spec.bottomBarPlacement.rawValue),
            String(spec.leadingSidebarPlacement.rawValue),
            spec.enableOSC.yn,
            String(spec.oscPosition.rawValue)
    ].joined(separator: ",")
  }

  /// Generates a Dictionary of properties for storage into a Preference entry
  static private func generatePropDict(from player: PlayerCore) -> [String: Any] {
    var props: [String: Any] = [:]
    let info = player.info
    let layout = player.mainWindow.currentLayout

    props[PropName.launchID.rawValue] = AppDelegate.launchID

    // - Window Layout & Geometry

    /// `layoutSpec`
    props[PropName.layoutSpec.rawValue] = toCSV(layout.spec)

    /// `windowGeometry`
    let geometry = player.mainWindow.getCurrentWindowGeometry()
    props[PropName.windowGeometry.rawValue] = toCSV(geometry)

    if let size = info.userPreferredVideoContainerSizeWide {
      let sizeString = [size.width.string2f, size.height.string2f].joined(separator: ",")
      props[PropName.userPreferredVideoContainerSizeWide.rawValue] = sizeString
    }

    if let size = info.userPreferredVideoContainerSizeTall {
      let sizeString = [size.width.string2f, size.height.string2f].joined(separator: ",")
      props[PropName.userPreferredVideoContainerSizeTall.rawValue] = sizeString
    }

    if player.mainWindow.isOntop {
      props[PropName.isOnTop.rawValue] = true.yn
    }
    if player.isInMiniPlayer {
      props[PropName.isMusicMode.rawValue] = true.yn
    }
    /// TODO: `isMinimized`

    // - Playback State

    if let urlString = info.currentURL?.absoluteString ?? nil {
      props[PropName.url.rawValue] = urlString
    }

    let playlistPaths: [String] = info.playlist.compactMap{ $0.filename }
    if playlistPaths.count > 1 {
      props[PropName.playlistPaths.rawValue] = playlistPaths
    }

    if let videoPosition = info.videoPosition?.second {
      props[PropName.progress.rawValue] = videoPosition.string6f
    }
    props[PropName.paused.rawValue] = info.isPaused.yn

    // - Video, Audio, Subtitles Settings

    props[PropName.deinterlace.rawValue] = info.deinterlace.yn
    props[PropName.hwdec.rawValue] = info.hwdec
    props[PropName.hdrEnabled.rawValue] = info.hdrEnabled.yn

    if let intVal = info.vid {
      props[PropName.vid.rawValue] = String(intVal)
    }
    if let intVal = info.aid {
      props[PropName.aid.rawValue] = String(intVal)
    }
    if let intVal = info.sid {
      props[PropName.sid.rawValue] = String(intVal)
    }
    if let intVal = info.secondSid {
      props[PropName.sid2.rawValue] = String(intVal)
    }
    props[PropName.brightness.rawValue] = String(info.brightness)
    props[PropName.contrast.rawValue] = String(info.contrast)
    props[PropName.saturation.rawValue] = String(info.saturation)
    props[PropName.gamma.rawValue] = String(info.gamma)
    props[PropName.hue.rawValue] = String(info.hue)

    props[PropName.playSpeed.rawValue] = info.playSpeed.string6f
    props[PropName.volume.rawValue] = info.volume.string6f
    props[PropName.isMuted.rawValue] = info.isMuted.yn
    props[PropName.audioDelay.rawValue] = info.audioDelay.string6f
    props[PropName.subDelay.rawValue] = info.subDelay.string6f

    props[PropName.isSubVisible.rawValue] = info.isSubVisible.yn
    props[PropName.isSub2Visible.rawValue] = info.isSecondSubVisible.yn

    let abLoopA: Double = player.abLoopA
    if abLoopA != 0 {
      props[PropName.abLoopA.rawValue] = abLoopA.string6f
    }
    let abLoopB: Double = player.abLoopB
    if abLoopB != 0 {
      props[PropName.abLoopB.rawValue] = abLoopB.string6f
    }

    props[PropName.videoRotation.rawValue] = String(info.userRotation)

    let maxVolume = player.mpv.getInt(MPVOption.Audio.volumeMax)
    if maxVolume != 100 {
      props[PropName.maxVolume.rawValue] = String(maxVolume)
    }

    props[PropName.videoFilters.rawValue] = player.mpv.getString(MPVProperty.vf)
    props[PropName.audioFilters.rawValue] = player.mpv.getString(MPVProperty.af)

    props[PropName.subScale.rawValue] = player.mpv.getDouble(MPVOption.Subtitles.subScale).string2f
    props[PropName.subPos.rawValue] = String(player.mpv.getInt(MPVOption.Subtitles.subPos))

    props[PropName.loopPlaylist.rawValue] = player.mpv.getString(MPVOption.PlaybackControl.loopPlaylist)
    props[PropName.loopFile.rawValue] = player.mpv.getString(MPVOption.PlaybackControl.loopFile)
    return props
  }

  static func save(_ player: PlayerCore) {
    guard Preference.UIState.isSaveEnabled else { return }
    guard player.mainWindow.loaded else {
      player.log.debug("Skipping player state save: player window is not loaded")
      return
    }
    guard !player.info.isRestoring else {
//      player.log.verbose("Skipping player state save: still restoring previous state")
      return
    }
    guard !player.isShuttingDown else {
      player.log.warn("Skipping player state save: is shutting down")
      return
    }
    DispatchQueue.main.async {
      let properties = generatePropDict(from: player)
      Preference.UIState.savePlayerState(forPlayerID: player.label, properties: properties)
    }
  }

  // MARK: - Restore State / Deserialize from prefs

  func string(for name: PropName) -> String? {
    return PlayerSaveState.string(for: name, properties)
  }

  /// Relies on `Bool` being serialized to `String` with value `Y` or `N`
  func bool(for name: PropName) -> Bool? {
    return PlayerSaveState.bool(for: name, properties)
  }

  func int(for name: PropName) -> Int? {
    return PlayerSaveState.int(for: name, properties)
  }

  /// Relies on `Double` being serialized to `String`
  func double(for name: PropName) -> Double? {
    return PlayerSaveState.double(for: name, properties)
  }

  /// Expects to parse CSV `String` with two tokens
  func nsSize(for name: PropName) -> NSSize? {
    if let csv = string(for: name) {
      let tokens = csv.split(separator: ",")
      if tokens.count == 2, let width = Double(tokens[0]), let height = Double(tokens[1]) {
        return NSSize(width: width, height: height)
      }
      Logger.log("Failed to parse property as NSSize: \(name.rawValue.quoted)")
    }
    return nil
  }

  static private func string(for name: PropName, _ properties: [String: Any]) -> String? {
    return properties[name.rawValue] as? String
  }

  static private func bool(for name: PropName, _ properties: [String: Any]) -> Bool? {
    return Bool.yn(string(for: name, properties))
  }

  static private func int(for name: PropName, _ properties: [String: Any]) -> Int? {
    if let intString = string(for: name, properties) {
      return Int(intString)
    }
    return nil
  }

  /// Relies on `Double` being serialized to `String`
  static private func double(for name: PropName, _ properties: [String: Any]) -> Double? {
    if let doubleString = string(for: name, properties) {
      return Double(doubleString)
    }
    return nil
  }

  // Utility function for parsing complex object from CSV
  static private func deserializeCSV<T>(_ propName: PropName, fromProperties properties: [String: Any], expectedTokenCount: Int, version: String,
                                        errPreamble: String, _ parseFunc: (String, inout IndexingIterator<[String]>) throws -> T?) rethrows -> T? {
    guard let csvString = string(for: propName, properties) else {
      return nil
    }
    Logger.log("PlayerSaveState: restoring. Read pref \(propName.rawValue.quoted) → \(csvString.quoted)", level: .verbose)
    let tokens = csvString.split(separator: ",").map{String($0)}
    guard tokens.count == expectedTokenCount else {
      Logger.log("\(errPreamble) not enough tokens (expected \(expectedTokenCount) but found \(tokens.count))", level: .error)
      return nil
    }
    var iter = tokens.makeIterator()

    let version = iter.next()
    guard version == PlayerSaveState.geoPrefStringVersion else {
      Logger.log("\(errPreamble) bad version (expected \(PlayerSaveState.geoPrefStringVersion.quoted) but found \(version?.quoted ?? "nil"))", level: .error)
      return nil
    }

    return try parseFunc(errPreamble, &iter)
  }

  /// String -> `LayoutSpec`
  static private func deserializeLayoutSpec(from properties: [String: Any]) -> MainWindowController.LayoutSpec? {
    return deserializeCSV(.layoutSpec, fromProperties: properties, expectedTokenCount: 11, version: PlayerSaveState.specPrefStringVersion,
                          errPreamble: PlayerSaveState.specErrPre, { errPreamble, iter in

      let leadingSidebarTab = MainWindowController.Sidebar.Tab(name: iter.next())
      let traillingSidebarTab = MainWindowController.Sidebar.Tab(name: iter.next())

      guard let modeInt = Int(iter.next()!), let mode = MainWindowController.WindowMode(rawValue: modeInt),
            let isLegacyStyle = Bool.yn(iter.next()) else {
        Logger.log("\(errPreamble) could not parse mode or isLegacyStyle", level: .error)
        return nil
      }

      guard let topBarPlacement = Preference.PanelPlacement(Int(iter.next()!)),
            let trailingSidebarPlacement = Preference.PanelPlacement(Int(iter.next()!)),
            let bottomBarPlacement = Preference.PanelPlacement(Int(iter.next()!)),
            let leadingSidebarPlacement = Preference.PanelPlacement(Int(iter.next()!)) else {
        Logger.log("\(errPreamble) could not parse bar placements", level: .error)
        return nil
      }

      guard let enableOSC = Bool.yn(iter.next()),
            let oscPositionInt = Int(iter.next()!),
            let oscPosition = Preference.OSCPosition(rawValue: oscPositionInt) else {
        Logger.log("\(errPreamble) could not parse enableOSC or oscPosition", level: .error)
        return nil
      }

      var leadingTabGroups = MainWindowController.Sidebar.TabGroup.fromPrefs(for: .leadingSidebar)
      let leadVis: MainWindowController.Sidebar.Visibility = leadingSidebarTab == nil ? .hide : .show(tabToShow: leadingSidebarTab!)
      // If the tab groups prefs changed somehow since the last run, just add it for now so that the geometry can be restored.
      // Will correct this at the end of restore.
      if let visibleTab = leadVis.visibleTab, !leadingTabGroups.contains(visibleTab.group) {
        Logger.log("Restore state is invalid: leadingSidebar has visibleTab \(visibleTab.name) which is outside its configured tab groups", level: .error)
        leadingTabGroups.insert(visibleTab.group)
      }
      let leadingSidebar = MainWindowController.Sidebar(.leadingSidebar, tabGroups: leadingTabGroups, placement: leadingSidebarPlacement, visibility: leadVis)

      var trailingTabGroups = MainWindowController.Sidebar.TabGroup.fromPrefs(for: .trailingSidebar)
      let trailVis: MainWindowController.Sidebar.Visibility = traillingSidebarTab == nil ? .hide : .show(tabToShow: traillingSidebarTab!)
      // Account for invalid visible tab (see note above)
      if let visibleTab = trailVis.visibleTab, !trailingTabGroups.contains(visibleTab.group) {
        Logger.log("Restore state is invalid: trailingSidebar has visibleTab \(visibleTab.name) which is outside its configured tab groups", level: .error)
        trailingTabGroups.insert(visibleTab.group)
      }
      let trailingSidebar = MainWindowController.Sidebar(.trailingSidebar, tabGroups: trailingTabGroups, placement: trailingSidebarPlacement, visibility: trailVis)

      return MainWindowController.LayoutSpec(leadingSidebar: leadingSidebar, trailingSidebar: trailingSidebar, mode: mode, isLegacyStyle: isLegacyStyle, topBarPlacement: topBarPlacement, bottomBarPlacement: bottomBarPlacement, enableOSC: enableOSC, oscPosition: oscPosition)
    })
  }

  /// String -> `MainWindowGeometry`
  static private func deserializeWindowGeometry(from properties: [String: Any]) -> MainWindowGeometry? {
    return deserializeCSV(.windowGeometry, fromProperties: properties, expectedTokenCount: 12, version: PlayerSaveState.geoPrefStringVersion,
                          errPreamble: PlayerSaveState.geoErrPre, { errPreamble, iter in

      guard let videoAspectRatio = Double(iter.next()!),
            let topBarHeight = Double(iter.next()!),
            let trailingBarWidth = Double(iter.next()!),
            let bottomBarHeight = Double(iter.next()!),
            let leadingBarWidth = Double(iter.next()!),
            let insideLeadingWidth = Double(iter.next()!),
            let insideTrailingWidth = Double(iter.next()!),
            let winOriginX = Double(iter.next()!),
            let winOriginY = Double(iter.next()!),
            let winWidth = Double(iter.next()!),
            let winHeight = Double(iter.next()!) else {
        Logger.log("\(errPreamble) could not parse one or more tokens", level: .error)
        return nil
      }

      let windowFrame = CGRect(x: winOriginX, y: winOriginY, width: winWidth, height: winHeight)
      return MainWindowGeometry(windowFrame: windowFrame, topBarHeight: topBarHeight, trailingBarWidth: trailingBarWidth, bottomBarHeight: bottomBarHeight, leadingBarWidth: leadingBarWidth, insideBarLeadingWidth: insideLeadingWidth, insideBarTrailingWidth: insideTrailingWidth, videoAspectRatio: videoAspectRatio)
    })
  }

  /// Restore player state from prior launch
  func restoreTo(_ player: PlayerCore) {
    let log = player.log
    log.verbose("Restoring player state from prior launch")
    let info = player.info
    let mainWindow = player.mainWindow!

    if let hdrEnabled = bool(for: .hdrEnabled) {
      info.hdrEnabled = hdrEnabled
    }

    if let size = nsSize(for: .userPreferredVideoContainerSizeWide) {
      info.userPreferredVideoContainerSizeWide = size
    }
    if let size = nsSize(for: .userPreferredVideoContainerSizeTall) {
      info.userPreferredVideoContainerSizeTall = size
    }

    if let geometry = windowGeometry {
      log.verbose("Successfully parsed prior geometry from prefs")

      log.debug("Restoring windowFrame to \(geometry.windowFrame), videoAspectRatio: \(geometry.videoAspectRatio)")
      player.videoView.updateAspectRatio(to: geometry.videoAspectRatio)
      mainWindow.setCurrentWindowGeometry(to: geometry, enqueueAnimation: false)
    } else {
      log.error("Failed to get player window layout and/or geometry from prefs")
    }

    guard let urlString = string(for: .url), let url = URL(string: urlString) else {
      log.error("Could not restore player window: no value for property \(PlayerSaveState.PropName.url.rawValue.quoted)")
      return
    }

    player.openURLs([url], shouldAutoLoad: false)

    let isOnTop = bool(for: .isOnTop) ?? false
    mainWindow.setWindowFloatingOnTop(isOnTop, updateOnTopStatus: true)

    if let playlistPathList = properties[PlayerSaveState.PropName.playlistPaths.rawValue] as? [String] {
      if playlistPathList.count > 1 {
        player.addFilesToPlaylist(pathList: playlistPathList)
      }
    }

    // FIXME: Music Mode restore is broken
    //    if let isInMusicMode = savedState.bool(for: .isMusicMode), isInMusicMode {
    //      enterMusicMode()
    //    }

    // mpv properties

    // Must wait until after mpv init, otherwise they will stick
    let mpv: MPVController = player.mpv
    if let startTime = string(for: .progress) {
      // This is actaully a decimal number but mpv expects a string
      mpv.setString(MPVOption.PlaybackControl.start, startTime)
    }

    if let wasPaused = bool(for: .paused) {
      mpv.setFlag(MPVOption.PlaybackControl.pause, wasPaused)
    }

    if let vid = int(for: .vid) {
      mpv.setInt(MPVOption.TrackSelection.vid, vid)
    }
    if let aid = int(for: .aid) {
      mpv.setInt(MPVOption.TrackSelection.aid, aid)
    }
    if let sid = int(for: .sid) {
      mpv.setInt(MPVOption.TrackSelection.sid, sid)
    }
    if let sid2 = int(for: .sid2) {
      mpv.setInt(MPVOption.Subtitles.secondarySid, sid2)
    }

    if let hwdec = string(for: .hwdec) {
      mpv.setString(MPVOption.Video.hwdec, hwdec)
    }

    if let deinterlace = bool(for: .deinterlace) {
      mpv.setFlag(MPVOption.Video.deinterlace, deinterlace)
    }

    if let brightness = int(for: .brightness) {
      mpv.setInt(MPVOption.Equalizer.brightness, brightness)
    }
    if let contrast = int(for: .contrast) {
      mpv.setInt(MPVOption.Equalizer.contrast, contrast)
    }
    if let saturation = int(for: .saturation) {
      mpv.setInt(MPVOption.Equalizer.saturation, saturation)
    }
    if let gamma = int(for: .gamma) {
      mpv.setInt(MPVOption.Equalizer.gamma, gamma)
    }
    if let hue = int(for: .hue) {
      mpv.setInt(MPVOption.Equalizer.hue, hue)
    }

    if let playSpeed = double(for: .playSpeed) {
      mpv.setDouble(MPVOption.PlaybackControl.speed, playSpeed)
    }
    if let volume = double(for: .volume) {
      mpv.setDouble(MPVOption.Audio.volume, volume)
    }
    if let isMuted = bool(for: .isMuted) {
      mpv.setFlag(MPVOption.Audio.mute, isMuted)
    }
    if let maxVolume = int(for: .maxVolume) {
      mpv.setInt(MPVOption.Audio.volumeMax, maxVolume)
    }
    if let audioDelay = double(for: .audioDelay) {
      mpv.setDouble(MPVOption.Audio.audioDelay, audioDelay)
    }
    if let subDelay = double(for: .subDelay) {
      mpv.setDouble(MPVOption.Subtitles.subDelay, subDelay)
    }
    if let isSubVisible = bool(for: .isSubVisible) {
      mpv.setFlag(MPVOption.Subtitles.subVisibility, isSubVisible)
    }
    if let isSub2Visible = bool(for: .isSub2Visible) {
      mpv.setFlag(MPVOption.Subtitles.secondarySubVisibility, isSub2Visible)
    }
    if let subScale = double(for: .subScale) {
      mpv.setDouble(MPVOption.Subtitles.subScale, subScale)
    }
    if let subPos = int(for: .subPos) {
      mpv.setInt(MPVOption.Subtitles.subPos, subPos)
    }
    if let loopPlaylist = string(for: .loopPlaylist) {
      mpv.setString(MPVOption.PlaybackControl.loopPlaylist, loopPlaylist)
    }
    if let loopFile = string(for: .loopFile) {
      mpv.setString(MPVOption.PlaybackControl.loopFile, loopFile)
    }
    if let abLoopA = double(for: .abLoopA) {
      if let abLoopB = double(for: .abLoopB) {
        mpv.setDouble(MPVOption.PlaybackControl.abLoopB, abLoopB)
      }
      mpv.setDouble(MPVOption.PlaybackControl.abLoopA, abLoopA)
    }
    if let videoRotation = int(for: .videoRotation) {
      mpv.setInt(MPVOption.Video.videoRotate, videoRotation)
    }

    if let audioFilters = string(for: .audioFilters) {
      mpv.setString(MPVProperty.af, audioFilters)
    }
    if let videoFilters = string(for: .videoFilters) {
      mpv.setString(MPVProperty.vf, videoFilters)
    }
  }

}
