//
//  PlayerSaveState.swift
//  iina
//
//  Created by Matt Svoboda on 8/6/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

extension MainWindowController {
  // Data structure for saving to prefs / restoring from prefs the UI state of a single player window
  struct PlayerSaveState {
    enum PropName: String {
      case launchID = "launchID"

      case playlist = "playlist"

      case windowGeometry = "windowGeometry"
      case layoutSpec = "layoutSpec"
//      case windowFrame = "windowFrame"
      case isMinimized = "minimized"
//      case bars = "bars"  /// "`TopSize`,`TrailingSize`,`BtmSize`,`LeadingSize` `TopPlacement`,`TrailingPlacement`,`BtmPlacement`"

      case url = "url"
      case progress = "progress"
      case paused = "paused"
    }

    static private let specPrefStringVersion = "1"
    static private let specErrPre = "Failed to parse LayoutSpec from string:"
    static private let geoErrPre = "Failed to parse WindowGeometry from string:"
    static private let geoPrefStringVersion = "1"

    let properties: [String: Any]

    init(_ props: [String: Any]) {
      self.properties = props
    }

    func string(for name: PropName) -> String? {
      return properties[name.rawValue] as? String
    }

    func bool(for name: PropName) -> Bool? {
      return properties[name.rawValue] as? Bool
    }

    func int(for name: PropName) -> Int? {
      return properties[name.rawValue] as? Int
    }

    // Utility function for parsing complex object from CSV
    private func fromCSV<T>(_ propName: PropName, expectedTokenCount: Int, version: String, errPreamble: String,
                            _ closure: (String, inout IndexingIterator<[String]>) throws -> T?) rethrows -> T? {
      guard let csvString = string(for: propName) else {
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

      return try closure(errPreamble, &iter)
    }

    /// `LayoutSpec` -> String
    private static func toPrefString(_ spec: LayoutSpec) -> String {
      let leadingSidebarTab: String = spec.leadingSidebar.visibleTab?.name ?? "nil"
      let trailingSidebarTab: String = spec.trailingSidebar.visibleTab?.name ?? "nil"
      return [specPrefStringVersion,
              leadingSidebarTab,
              trailingSidebarTab,
              spec.isFullScreen.yn,
              spec.isLegacyMode.yn,
              String(spec.topBarPlacement.rawValue),
              String(spec.trailingSidebarPlacement.rawValue),
              String(spec.bottomBarPlacement.rawValue),
              String(spec.leadingSidebarPlacement.rawValue),
              spec.enableOSC.yn,
              String(spec.oscPosition.rawValue)
      ].joined(separator: ",")
    }

    /// String -> `LayoutSpec`
    func layoutSpec() -> LayoutSpec? {
      return fromCSV(.layoutSpec, expectedTokenCount: 11, version: PlayerSaveState.specPrefStringVersion,
                     errPreamble: PlayerSaveState.specErrPre, { errPreamble, iter in

        let leadingSidebarTab = Sidebar.Tab(name: iter.next())
        let traillingSidebarTab = Sidebar.Tab(name: iter.next())
        
        guard let isFullScreen = Bool.yn(iter.next()),
              let isLegacyMode = Bool.yn(iter.next()) else {
          Logger.log("\(errPreamble) could not parse isFullScreen or isLegacyMode", level: .error)
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

        let leadingTabGroups = Sidebar.TabGroup.fromPrefs(for: .leadingSidebar)
        let leadVis: Sidebar.Visibility = leadingSidebarTab == nil ? .hide : .show(tabToShow: leadingSidebarTab!)
        // TODO: account for invalid tab
        //      if let visibleTab = leadVis.visibleTab, !leadingTabGroups.contains(visibleTab.group) {
        //        Logger.log("Visible tab \(visibleTab.name) in \("leadingSidebar") is outside its tab groups. The sidebar will close.", level: .error)
        //        leadVis = .hide
        //      }
        let leadingSidebar = Sidebar(.leadingSidebar, tabGroups: leadingTabGroups, placement: leadingSidebarPlacement, visibility: leadVis)

        let trailingTabGroups = Sidebar.TabGroup.fromPrefs(for: .trailingSidebar)
        let trailVis: Sidebar.Visibility = traillingSidebarTab == nil ? .hide : .show(tabToShow: traillingSidebarTab!)
        // TODO: account for invalid tab
        let trailingSidebar = Sidebar(.trailingSidebar, tabGroups: trailingTabGroups, placement: trailingSidebarPlacement, visibility: trailVis)

        return LayoutSpec(leadingSidebar: leadingSidebar, trailingSidebar: trailingSidebar, isFullScreen: isFullScreen, isLegacyMode: isLegacyMode, topBarPlacement: topBarPlacement, bottomBarPlacement: bottomBarPlacement, enableOSC: enableOSC, oscPosition: oscPosition)
      })
    }

    /// `MainWindowGeometry` -> String
    private static func toPrefString(_ geo: MainWindowGeometry) -> String {
      return [geoPrefStringVersion,
              geo.videoSize.width.string2f,
              geo.videoSize.height.string2f,
              geo.videoAspectRatio.string6f,
              geo.topBarHeight.string2f,
              geo.trailingBarWidth.string2f,
              geo.bottomBarHeight.string2f,
              geo.leadingBarWidth.string2f,
              geo.windowFrame.origin.x.string2f,
              geo.windowFrame.origin.y.string2f,
              geo.windowFrame.width.string2f,
              geo.windowFrame.height.string2f].joined(separator: ",")
    }

    /// String -> `MainWindowGeometry`
    func windowGeometry() -> MainWindowGeometry? {
      return fromCSV(.windowGeometry, expectedTokenCount: 12, version: PlayerSaveState.geoPrefStringVersion,
                     errPreamble: PlayerSaveState.geoErrPre, { errPreamble, iter in

        guard let videoWidth = Double(iter.next()!),
              let videoHeight = Double(iter.next()!),
              let videoAspectRatio = Double(iter.next()!),
              let topBarHeight = Double(iter.next()!),
              let trailingBarWidth = Double(iter.next()!),
              let bottomBarHeight = Double(iter.next()!),
              let leadingBarWidth = Double(iter.next()!),
              let winOriginX = Double(iter.next()!),
              let winOriginY = Double(iter.next()!),
              let winWidth = Double(iter.next()!),
              let winHeight = Double(iter.next()!) else {
          Logger.log("\(errPreamble) could not parse one or more tokens", level: .error)
          return nil
        }

        let videoSize = CGSize(width: videoWidth, height: videoHeight)
        let windowFrame = CGRect(x: winOriginX, y: winOriginY, width: winWidth, height: winHeight)
        return MainWindowGeometry(windowFrame: windowFrame, topBarHeight: topBarHeight, trailingBarWidth: trailingBarWidth, bottomBarHeight: bottomBarHeight, leadingBarWidth: leadingBarWidth, videoSize: videoSize, videoAspectRatio: videoAspectRatio)
      })
    }

    static func generatePrefDict(from player: PlayerCore) -> PlayerSaveState {
      var props: [String: Any] = [:]
      let info = player.info
      let layout = player.mainWindow.currentLayout

      props[PropName.launchID.rawValue] = (NSApp.delegate as! AppDelegate).launchID

      // - Window state:

      /// `layoutSpec`
      props[PropName.layoutSpec.rawValue] = toPrefString(layout.spec)

      /// `windowGeometry`
      let geometry: MainWindowGeometry?
      if layout.isFullScreen {
        geometry = player.mainWindow.fsState.priorWindowedFrame
        // TODO: which screen...?
      } else {
        geometry = player.mainWindow.buildGeometryFromCurrentLayout()
      }
      if let geometry = geometry {
        props[PropName.windowGeometry.rawValue] = toPrefString(geometry)
      }

      /// TODO: `isMinimized`

      // - Video state:

      if let urlString = info.currentURL?.absoluteString ?? nil {
        props[PropName.url.rawValue] = urlString
      }

      if let videoPosition = info.videoPosition?.second {
        props[PropName.progress.rawValue] = String(videoPosition)
      }
      props[PropName.paused.rawValue] = info.isPaused

      /*
       props["deinterlace"] = deinterlace
       props["hwdec"] = hwdec
       props["hdrEnabled"] = hdrEnabled

       props["aid"] = aid
       props["sid"] = sid
       props["sid2"] = secondSid
       props["vid"] = vid

       props["brightness"] = brightness
       props["contrast"] = contrast
       props["saturation"] = saturation
       props["gamma"] = gamma
       props["hue"] = hue
       props["playSpeed"] = playSpeed
       props["volume"] = volume
       props["isMuted"] = isMuted
       props["audioDelay"] = audioDelay
       props["subDelay"] = subDelay
       props["abLoopStatus"] = abLoopStatus.rawValue
       props["userRotationDeg"] = userRotation
       */
      return PlayerSaveState(props)
    }
  }
}
