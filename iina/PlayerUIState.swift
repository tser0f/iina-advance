//
//  PlayerUIState.swift
//  iina
//
//  Created by Matt Svoboda on 8/6/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

// Data structure for saving to prefs / restoring from prefs the UI state of a single player window
struct PlayerUIState {
  enum PropName: String {
    case launchID = "launchID"

    case windowFrame = "windowFrame"
    case isFullScreen = "fullScreen"
    case isMinimized = "minimized"
    case bars = "bars"  /// "`TopSize`,`TrailingSize`,`BtmSize`,`LeadingSize` `TopPlacement`,`TrailingPlacement`,`BtmPlacement`"

    case url = "url"
    case progress = "progress"
    case paused = "paused"
  }

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

  static private func bars(from layout: MainWindowController.LayoutPlan) -> String {
    let barSizes: [CGFloat] = [layout.topBarHeight, layout.trailingBarWidth,
                               layout.bottomBarHeight, layout.leadingBarWidth]
    let barPlacements: [Int] = [layout.topBarPlacement.rawValue, layout.trailingSidebarPlacement.rawValue,
                                layout.bottomBarPlacement.rawValue, layout.leadingSidebarPlacement.rawValue]
    let barsSizesString = barSizes.map{$0.string2f}.joined(separator: ",")
    let barsPlacementsString = barPlacements.map{String($0)}.joined(separator: ",")
    return "\(barsSizesString) \(barsPlacementsString)"
  }

  static func from(_ player: PlayerCore) -> PlayerUIState {
    var props: [String: Any] = [:]
    let info = player.info
    let layout = player.mainWindow.currentLayout

    props[PropName.launchID.rawValue] = (NSApp.delegate as! AppDelegate).launchID

    // - Window state:

    /// `windowFrame`
    if let frame = player.mainWindow.window?.frame {
      props[PropName.windowFrame.rawValue] = "\(frame.origin.x),\(frame.origin.y),\(frame.width),\(frame.height)"
    }

    /// `bars`
    props[PropName.bars.rawValue] = bars(from: layout)
    /// `isFullScreen`
    props[PropName.isFullScreen.rawValue] = layout.isFullScreen
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
    return PlayerUIState(props)
  }
}
