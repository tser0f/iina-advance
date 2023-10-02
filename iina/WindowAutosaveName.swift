//
//  WindowAutosaveName.swift
//  iina
//
//  Created by Matt Svoboda on 8/5/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

enum WindowAutosaveName: Equatable {
  static let playWindowPrefix = "PlayWindow-"
  static let playWindowFmt = "\(playWindowPrefix)%@"

  case preference
  case welcome
  case openURL
  case about
  case inspector  // not always treated like a real window
  case playbackHistory
  // TODO: what about Guide?
  case videoFilter
  case audioFilter
  case fontPicker
  case playWindow(id: String)

  var string: String {
    switch self {
    case .preference:
      return "IINAPreferenceWindow"
    case .welcome:
      return "IINAWelcomeWindow"
    case .openURL:
      return "OpenURLWindow"
    case .about:
      return "AboutWindow"
    case .inspector:
      return "InspectorWindow"
    case .playbackHistory:
      return "PlaybackHistoryWindow"
    case .videoFilter:
      return "VideoFilterWindow"
    case .audioFilter:
      return "AudioFilterWindow"
    case .fontPicker:
      return "IINAFontPickerWindow"
    case .playWindow(let id):
      return String(format: WindowAutosaveName.playWindowFmt, id)
    }
  }

  init?(_ string: String) {
    switch string {
    case WindowAutosaveName.preference.string:
      self = .preference
    case WindowAutosaveName.welcome.string:
      self = .welcome
    case WindowAutosaveName.openURL.string:
      self = .openURL
    case WindowAutosaveName.about.string:
      self = .about
    case WindowAutosaveName.inspector.string:
      self = .inspector
    case WindowAutosaveName.playbackHistory.string:
      self = .playbackHistory
    case WindowAutosaveName.videoFilter.string:
      self = .videoFilter
    case WindowAutosaveName.audioFilter.string:
      self = .audioFilter
    case WindowAutosaveName.fontPicker.string:
      self = .fontPicker
    default:
      if let id = WindowAutosaveName.parseID(from: string, mustStartWith: WindowAutosaveName.playWindowPrefix) {
        self = .playWindow(id: id)
      } else {
        return nil
      }
    }
  }

  /// Returns `id` if `self` is type `.playWindow`; otherwise `nil`
  var playWindowID: String? {
    switch self {
    case .playWindow(let id):
      return id
    default:
      break
    }
    return nil
  }

  private static func parseID(from string: String, mustStartWith prefix: String) -> String? {
    if string.starts(with: prefix) {
      let splitted = string.split(separator: "-", maxSplits: 1)
      if splitted.count == 2 {
        return String(splitted[1])
      }
    }
    return nil
  }
}
