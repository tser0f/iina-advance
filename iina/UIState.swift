//
//  UIState.swift
//  iina
//
//  Created by Matt Svoboda on 8/6/23.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

/// Notes on performance:
/// Apple's `NSUserDefaults`, when getting & saving preference values, utilizes an in-memory cache which is very fast.
/// And although it periodically saves "dirty" values to disk, and the interval between writes is unclear, this doesn't appear to cause
/// a significant performance penalty, and certainly can't be much improved upon by IINA. Also, as playing video is by its nature very
/// data-intensive, writes to the .plist should be trivial by comparison.
extension Preference {
  class UIState {
    class LaunchStatus {
      static let stillRunning: Int = 1
      static let indeterminate1: Int = 2
      static let indeterminate2: Int = 3
      static let done: Int = 9
    }

    static private let iinaLaunchFmt = "iinaLaunch-%@"
    // Comma-separated list of open windows, back to front
    static private let openWindowListFmt = "uiOpenWindows-%@"

    static func makeOpenWindowListKey(forLaunchID launchID: Int) -> String {
      return String(format: Preference.UIState.openWindowListFmt, String(launchID))
    }

    static func launchName(forID launchID: Int) -> String {
      return String(format: Preference.UIState.iinaLaunchFmt, String(launchID))
    }

    static func launchID(fromLaunchName launchName: String) -> Int? {
      if launchName.starts(with: "iinaLaunch-") {
        let splitted = launchName.split(separator: "-", maxSplits: 1)
        if splitted.count == 2 {
          return Int(splitted[1])
        }
      }
      return nil
    }

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

    static func disableSaveAndRestoreUntilNextLaunch() {
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
    static func getSavedOpenWindowsBackToFront(forLaunchID launchID: Int) -> [String] {
      guard isRestoreEnabled else {
        Logger.log("UI restore disabled. Returning empty open window list")
        return []
      }

      let key = Preference.UIState.makeOpenWindowListKey(forLaunchID: launchID)
      let csv = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespaces) ?? ""
      Logger.log("Loaded list of previously open windows: \(csv.quoted)", level: .verbose)
      if csv.isEmpty {
        return []
      }
      return csv.components(separatedBy: ",").map{ $0.trimmingCharacters(in: .whitespaces)}
    }

    static private func getCurrentOpenWindowNames(excludingWindowName nameToExclude: String? = nil) -> [String] {
      var orderNamePairs: [(Int, String)] = []
      for window in NSApp.windows {
        let name = window.uiStateSaveName
        if !name.isEmpty && window.isVisible {
          if let nameToExclude = nameToExclude, nameToExclude == name {
            continue
          }
          orderNamePairs.append((window.orderedIndex, name))
        }
      }
      return orderNamePairs.sorted(by: { (left, right) in left.0 > right.0}).map{ $0.1 }
    }

    static func saveCurrentOpenWindowList(excludingWindowName nameToExclude: String? = nil) {
      let openWindowNames = self.getCurrentOpenWindowNames(excludingWindowName: nameToExclude)
      saveOpenWindowList(windowNamesBackToFront: openWindowNames, forLaunchID: AppDelegate.launchID)
    }

    static private func saveOpenWindowList(windowNamesBackToFront: [String], forLaunchID launchID: Int) {
      guard isSaveEnabled else { return }
      //      Logger.log("Saving open windows: \(windowNamesBackToFront)", level: .verbose)
      let csv = windowNamesBackToFront.map{ $0 }.joined(separator: ",")
      let key = Preference.UIState.makeOpenWindowListKey(forLaunchID: launchID)

      UserDefaults.standard.setValue(csv, forKey: key)
    }

    static func clearSavedStateForThisLaunch() {
      clearSavedState(forLaunchID: AppDelegate.launchID)
    }

    static func clearSavedState(forLaunchID launchID: Int) {
      let launchName = Preference.UIState.launchName(forID: launchID)

      // Clear state for saved players:
      let openWindowList = getSavedOpenWindowsBackToFront(forLaunchID: launchID)
      for windowEnum in openWindowList.compactMap({WindowAutosaveName($0)}) {
        if let playerID = windowEnum.playWindowID {
          Preference.UIState.clearPlayerSaveState(forPlayerID: playerID)
        }
      }

      let windowListKey = Preference.UIState.makeOpenWindowListKey(forLaunchID: launchID)
      Logger.log("Clearing saved list of open windows (pref key: \(windowListKey.quoted))")
      UserDefaults.standard.removeObject(forKey: windowListKey)

      Logger.log("Clearing saved launch status (pref key: \(launchName.quoted))")
      UserDefaults.standard.removeObject(forKey: launchName)
    }

    static func clearAllSavedWindowsState() {
      guard isSaveEnabled else {
        Logger.log("Will not clear saved UI state; UI save is disabled")
        return
      }
      Logger.log("Clearing all saved window states from prefs", level: .debug)

      let pastLaunchNames = Preference.UIState.collectPastLaunches()
      for pastLaunchName in pastLaunchNames {
        guard let pastLaunchID = Preference.UIState.launchID(fromLaunchName: pastLaunchName) else { continue }
        clearSavedState(forLaunchID: pastLaunchID)
      }
      clearSavedStateForThisLaunch()
    }

    static private func getPlayerIDs(from windowAutosaveNames: [WindowAutosaveName]) -> [String] {
      var ids: [String] = []
      for windowName in windowAutosaveNames {
        switch windowName {
        case WindowAutosaveName.playWindow(let id):
          ids.append(id)
        default:
          break
        }
      }
      return ids
    }

    static func getPlayerSaveState(forPlayerID playerID: String) -> PlayerSaveState? {
      guard isRestoreEnabled else { return nil }
      let key = WindowAutosaveName.playWindow(id: playerID).string
      guard let propDict = UserDefaults.standard.dictionary(forKey: key) else {
        return nil
      }
      return PlayerSaveState(propDict)
    }

    static func savePlayerState(forPlayerID playerID: String, properties: [String: Any]) {
      guard isSaveEnabled else { return }
      let key = WindowAutosaveName.playWindow(id: playerID).string
      UserDefaults.standard.setValue(properties, forKey: key)
    }

    static func clearPlayerSaveState(forPlayerID playerID: String) {
      let key = WindowAutosaveName.playWindow(id: playerID).string
      UserDefaults.standard.removeObject(forKey: key)
      Logger.log("Removed stored UI state for player \(key.quoted)", level: .verbose)
    }

    /// Returns list of "launch name" identifiers for past launches of IINA which have saved state to restore.
    /// This omits launches which are detected as still running.
    static func collectPastLaunches() -> [String] {
      let smallestValidLaunchID = Preference.integer(for: .smallestValidLaunchID)
      var foundNextSmallestLaunchID = false
      var newSmallestValidLaunchID: Int = smallestValidLaunchID

      var pastLaunches: [String: Int] = [:]
      for launchID in smallestValidLaunchID..<AppDelegate.launchID {
        let launchName = Preference.UIState.launchName(forID: launchID)
        let launchStatus: Int = UserDefaults.standard.integer(forKey: launchName)
        // 0 === nil
        if launchStatus > 0 {
          if !foundNextSmallestLaunchID {
            // Don't need to make this logic too smart. It's just an optimization for future launches
            newSmallestValidLaunchID = launchID
            foundNextSmallestLaunchID = true
          }
          pastLaunches[launchName] = launchStatus
        }
      }

      var countOfLaunchesToWaitOn = 0
      for (pastLaunchName, pastLaunchStatus) in pastLaunches {
        if pastLaunchStatus != Preference.UIState.LaunchStatus.done {
          Logger.log("Looks like past launch is still running: \(pastLaunchName.quoted)", level: .verbose)
          countOfLaunchesToWaitOn += 1
          var newValue = Preference.UIState.LaunchStatus.indeterminate1
          if pastLaunchStatus == Preference.UIState.LaunchStatus.indeterminate1 {
            newValue = Preference.UIState.LaunchStatus.indeterminate2
          }
          UserDefaults.standard.setValue(newValue, forKey: pastLaunchName)
        }
      }

      if newSmallestValidLaunchID != smallestValidLaunchID {
        Logger.log("Updating smallestValidLaunchID pref to: \(newSmallestValidLaunchID)", level: .verbose)
        Preference.set(newSmallestValidLaunchID, for: .smallestValidLaunchID)
      }

      if countOfLaunchesToWaitOn > 0 {
        Logger.log("Waiting 1s to see if \(countOfLaunchesToWaitOn) past instances are still running...", level: .verbose)
        Thread.sleep(forTimeInterval: 1)
      }

      var pastLaunchNames: [String] = []
      for (pastLaunchName, _) in pastLaunches {
        let launchStatus: Int = UserDefaults.standard.integer(forKey: pastLaunchName)
        if launchStatus == Preference.UIState.LaunchStatus.stillRunning {
          Logger.log("Instance is still running: \(pastLaunchName.quoted)", level: .verbose)
        } else {
          if launchStatus != Preference.UIState.LaunchStatus.done {
            Logger.log("Instance \(pastLaunchName.quoted) has launchStatus \(launchStatus). Assuming it is defunct. Will roll its windows into current launch", level: .verbose)
          }
          pastLaunchNames.append(pastLaunchName)
        }
      }

      return pastLaunchNames
    }

    /// Consolidates all player windows (& others) from any past launches which are no longer running into the windows for this instance.
    /// Updates prefs to reflect new conslidated state.
    /// Returns all window names for this launch instance, back to front.
    static func consolidateOpenWindowsFromPastLaunches() -> [WindowAutosaveName] {
      // Could have been a long time since data was last collected. Get a fresh set of data:
      let pastLaunchNames = Preference.UIState.collectPastLaunches()

      var completeNameList: [String] = []
      var nameSet = Set<String>()
      for pastLaunchName in pastLaunchNames {
        guard let launchID = Preference.UIState.launchID(fromLaunchName: pastLaunchName) else {
          Logger.log("Failed to parse launchID from launchName: \(pastLaunchName.quoted)", level: .error)
          continue
        }
        let savedWindowNameStrings = getSavedOpenWindowsBackToFront(forLaunchID: launchID)
        for nameString in savedWindowNameStrings {
          completeNameList.append(nameString)
          nameSet.insert(nameString)
        }
      }

      // Remove duplicates, favoring front-most copies
      var deduplicatedReverseNameList: [String] = []
      for nameString in completeNameList.reversed() {
        if nameSet.contains(nameString) {
          deduplicatedReverseNameList.append(nameString)
          nameSet.remove(nameString)
        } else {
          Logger.log("Skipping duplicate open window: \(nameString.quoted)", level: .verbose)
        }
      }

      let finalWindowNameList = Array(deduplicatedReverseNameList.reversed())
      Logger.log("Consolidated open windows from past launches, saving under this launchID: \(finalWindowNameList)", level: .verbose)
      saveOpenWindowList(windowNamesBackToFront: finalWindowNameList, forLaunchID: AppDelegate.launchID)
      for pastLaunchName in pastLaunchNames {
        Logger.log("Removing past launch from prefs: \(pastLaunchName.quoted)", level: .verbose)
        UserDefaults.standard.removeObject(forKey: pastLaunchName)
      }

      return finalWindowNameList.compactMap{WindowAutosaveName($0)}
    }
  }
}
