//
//  RestorableState.swift
//  iina
//
//  Created by Matt Svoboda on 8/6/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

struct RestorableState {
  // TODO: find cool way to store in prefs as Strings, but map to Swift types
  let properties: [String: Any]

  init(_ props: [String: Any]) {
    self.properties = props
  }

  static func from(_ player: PlayerCore) -> RestorableState {
    var props: [String: Any] = [:]
    let info = player.info

    if let frame = player.mainWindow.window?.frame {
      props["windowFrame"] = "\(frame.origin.x),\(frame.origin.y),\(frame.width),\(frame.height)"
    }
    if let urlString = info.currentURL?.absoluteString ?? nil {
      props["url"] = urlString
    }
    if let videoPosition = info.videoPosition?.second {
      props["progress"] = String(videoPosition)
    }
    props["paused"] = String(info.isPaused)
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
    return RestorableState(props)
  }
}
