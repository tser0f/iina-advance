//
//  UIState.swift
//  iina
//
//  Created by Matt Svoboda on 8/6/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

extension Preference {
  /** Notes on performance:
   Apple's `NSUserDefaults`, when getting & saving preference values, utilizes an in-memory cache which is very fast.
   And although it periodically saves "dirty" values to disk, and the interval between writes is unclear, this doesn't appear to cause
   a significant performance penalty, and certainly can't be much improved upon by IINA. Also, as playing video is by its nature very
   data-intensive, writes to the .plist should be trivial by comparison. */
  class UIState {
    /// This value, when set to true, disables state loading & saving for the remaining lifetime of this instance of IINA
    /// (overriding any user settings); calls to `set()` will not be saved for the next launch, and any new get() requests
    /// will return the default values.
    private static var disableForThisInstance = false

    static var isSaveEnabled: Bool {
      return !disableForThisInstance && Preference.bool(for: .enableSaveUIState)
    }

    static var isRestoreEnabled: Bool {
      return !disableForThisInstance && Preference.bool(for: .enableRestoreUIState)
    }

    static func disablePersistentStateUntilNextLaunch() {
      disableForThisInstance = true
    }

    // Convenience method. If restoring UI state is enabled, returns the saved value; otherwise returns the saved value.
    // Note: doesn't work for enums.
    static func get<T>(_ key: Key) -> T {
      if isRestoreEnabled {
        if let val = Preference.value(for: key) as? T {
          return val
        }
      }
      return Preference.typedDefault(for: key)
    }

    // Convenience method. If saving UI state is enabled, saves the given value. Otherwise does nothing.
    static func set<T: Equatable>(_ value: T, for key: Key) {
      guard isSaveEnabled else { return }
      if let existing = Preference.object(for: key) as? T, existing == value {
        return
      }
      Preference.set(value, for: key)
    }

    // Returns the autosave names of windows which have been saved in the set of open windows
    private static func getSavedOpenWindowsBackToFront() -> [String] {
      guard isRestoreEnabled else {
        Logger.log("UI restore disabled. Returning empty open window list")
        return []
      }

      let csv = Preference.string(for: Key.uiOpenWindowsBackToFrontList)?.trimmingCharacters(in: .whitespaces) ?? ""
      Logger.log("Loaded list of previously open windows: \(csv.quoted)", level: .verbose)
      if csv.isEmpty {
        return []
      }
      return csv.components(separatedBy: ",").map{ $0.trimmingCharacters(in: .whitespaces)}
    }

    static func saveOpenWindowList(windowNamesBackToFront: [String]) {
      guard isSaveEnabled else { return }
      //      Logger.log("Saving open windows: \(windowNamesBackToFront)", level: .verbose)
      let csv = windowNamesBackToFront.map{ $0 }.joined(separator: ",")
      Preference.set(csv, for: Key.uiOpenWindowsBackToFrontList)
    }

    static func clearOpenWindowList() {
      saveOpenWindowList(windowNamesBackToFront: [])
    }

    /// Workaround for IINA PlayerCore init weirdness which sometimes creates a new `player0` at startup, if some random other UI code
    /// happens to call `PlayerCore.lastActive` or `PlayerCore.active`. If this happens before we try to restore the `player0` from a
    /// previous launch, that would cause a conflict. Workaround: look for previous `player0` and remap it to some higher number.
    static func getSavedWindowsWithPlayerZeroWorkaround() -> [WindowAutosaveName] {
      let windowNamesStrings = Preference.UIState.getSavedOpenWindowsBackToFront()
      let windowNamesBackToFront = windowNamesStrings.compactMap{WindowAutosaveName($0)}

      var foundPlayerZero = false
      var largestPlayerID: UInt = 0

      for windowName in windowNamesBackToFront {
        switch windowName {
        case WindowAutosaveName.mainPlayer(let id):
          guard let uid = UInt(id) else { break }
          if uid == 0 {
            foundPlayerZero = true
          } else if uid > largestPlayerID {
            largestPlayerID = uid
          }
        default:
          break
        }
      }

      guard foundPlayerZero else {
        Logger.log("PlayerZero not found in saved windows", level: .verbose)
        return windowNamesBackToFront
      }

      let newPlayerZeroID = String(largestPlayerID + 1)

      guard let propList = Preference.UIState.getPlayerState(playerID: "0") else {
        Logger.log("PlayerZero was listed in saved windows but could not find a prop list entry for it! Skipping...", level: .error)
        return windowNamesBackToFront
      }

      let oldPlayerZeroString = WindowAutosaveName.mainPlayer(id: "0").string
      let newPlayerZeroString = WindowAutosaveName.mainPlayer(id: newPlayerZeroID).string

      Preference.UIState.setPlayerState(playerID: newPlayerZeroID, propList)

      Logger.log("Remapped saved window props: \(oldPlayerZeroString.quoted) -> \(newPlayerZeroString.quoted)")

      let newWindowNamesStrings = windowNamesStrings.map { $0 == oldPlayerZeroString ? newPlayerZeroString : $0 }
      Preference.UIState.saveOpenWindowList(windowNamesBackToFront: newWindowNamesStrings)
      Logger.log("Re-saved window list with remapped name: \(oldPlayerZeroString.quoted) -> \(newPlayerZeroString.quoted)")
      // In case you were wondering, just leave the old entry for player0. It will be overwritten soon enough anyway.

      return newWindowNamesStrings.compactMap{WindowAutosaveName($0)}
    }

    static func getPlayerState(playerID: String) -> RestorableState? {
      guard isRestoreEnabled else { return nil }
      let key = WindowAutosaveName.mainPlayer(id: playerID).string
      guard let propDict = UserDefaults.standard.dictionary(forKey: key) else {
        return nil
      }
      return RestorableState(propDict)
    }

    static func setPlayerState(playerID: String, _ state: RestorableState) {
      guard isSaveEnabled else { return }
      let key = WindowAutosaveName.mainPlayer(id: playerID).string
      UserDefaults.standard.setValue(state.properties, forKey: key)
    }

    static func removePlayerState(playerID: String) {
      let key = WindowAutosaveName.mainPlayer(id: playerID).string
      UserDefaults.standard.setValue(nil, forKey: key)
    }

    private func getCurrentOpenWindowNames(excludingWindowName nameToExclude: String? = nil) -> [String] {
      var orderNamePairs: [(Int, String)] = []
      for window in NSApp.windows {
        let name = window.frameAutosaveName
        if !name.isEmpty && window.isVisible {
          if let nameToExclude = nameToExclude, nameToExclude == name {
            continue
          }
          orderNamePairs.append((window.orderedIndex, name))
        }
      }
      return orderNamePairs.sorted(by: { (left, right) in left.0 > right.0}).map{ $0.1 }
    }

  }
}
