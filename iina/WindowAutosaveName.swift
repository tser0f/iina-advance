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
  static let miniPlayerPrefix = "MiniPlayWindow-"
  static let playWindowFmt = "\(playWindowPrefix)%@"
  static let miniPlayerFmt = "\(miniPlayerPrefix)%@"

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
  case mainPlayer(id: String)
  case miniPlayer(id: String)

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
    case .mainPlayer(let id):
      return String(format: WindowAutosaveName.playWindowFmt, id)
    case .miniPlayer(let id):
      return String(format: WindowAutosaveName.miniPlayerFmt, id)
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
        self = .mainPlayer(id: id)
      } else if let id = WindowAutosaveName.parseID(from: string, mustStartWith: WindowAutosaveName.miniPlayerPrefix) {
        self = .miniPlayer(id: id)
      } else {
        return nil
      }
    }
  }

  private static func parseID(from string: String, mustStartWith prefix: String) -> String? {
    if string.starts(with: prefix) {
      let splitted = string.split(separator: "-")
      if splitted.count == 2 {
        return String(splitted[1])
      }
    }
    return nil
  }
}
