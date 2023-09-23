//
//  CocoaAnimation.swift
//  iina
//
//  Created by Matt Svoboda on 2023-04-09.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

typealias TaskFunc = (() -> Void)
typealias AnimationBlock = (NSAnimationContext) -> Void

class CocoaAnimation {

  // MARK: Constants

  static let DefaultDuration = 0.25
  static let FullScreenTransitionDuration = 0.25  // Roughly matching the noticeable portion of the native duration (as of MacOS 13.4)
  static let OSDAnimationDuration = 0.5
  static let CropAnimationDuration = 0.2

  // MARK: "Disable all" override switch

  private static var disableAllAnimation = false

  // Wrap a block of code inside this function to disable its animations
  static func disableAnimation<T>(_ closure: () throws -> T) rethrows -> T {
    let prevDisableState = disableAllAnimation
    disableAllAnimation = true
    defer {
      disableAllAnimation = prevDisableState
    }
    return try closure()
  }

  static var isAnimationEnabled: Bool {
    get {
      return disableAllAnimation ? false : !AccessibilityPreferences.motionReductionEnabled
    }
  }

  // MARK: - CocoaAnimation.Task

  struct Task {
    let duration: CGFloat
    let timingFunction: CAMediaTimingFunction?
    let runFunc: TaskFunc

    init(duration: CGFloat = CocoaAnimation.DefaultDuration,
         timing timingName: CAMediaTimingFunctionName? = nil,
         _ runFunc: @escaping TaskFunc) {
      self.duration = duration
      if let timingName = timingName {
        self.timingFunction = CAMediaTimingFunction(name: timingName)
      } else {
        self.timingFunction = nil
      }
      self.runFunc = runFunc
    }
  }

  static func zeroDurationTask(_ runFunc: @escaping TaskFunc) -> Task {
    return Task(duration: 0, timing: nil, runFunc)
  }

  // MARK: - CocoaAnimation.SerialQueue

  class SerialQueue {

    private(set) var isRunning = false
    private var taskQueue = LinkedList<Task>()

    /// Convenience function. Same as `run([Task])`, but for a single animation.
    func run(_ task: Task, then doAfter: TaskFunc? = nil) {
      run([task], then: doAfter)
    }

    func runZeroDuration(_ runFunc: @escaping TaskFunc, then doAfter: TaskFunc? = nil) {
      run(CocoaAnimation.zeroDurationTask(runFunc), then: doAfter)
    }

    /// Recursive function which enqueues each of the given `AnimationTask`s for execution, one after another.
    /// Will execute without animation if motion reduction is enabled, or if wrapped in a call to `CocoaAnimation.disableAnimation()`.
    /// If animating, it uses either the supplied `duration` for duration, or if that is not provided, uses `CocoaAnimation.DefaultDuration`.
    func run(_ tasks: [Task], then doAfter: TaskFunc? = nil) {

      var needsLaunch = false
      taskQueue.appendAll(tasks)
      if let doAfter = doAfter {
        taskQueue.append(zeroDurationTask(doAfter))
      }

      if isRunning {
        // Let existing chain pick up the new animations
      } else {
        isRunning = true
        needsLaunch = true
      }

      if needsLaunch {
        runTasks()
      }
    }

    private func runTasks() {
      var nextTask: CocoaAnimation.Task? = nil

      if let poppedTask = taskQueue.removeFirst() {
        nextTask = poppedTask
      } else {
        self.isRunning = false
      }

      guard let nextTask = nextTask else { return }

      NSAnimationContext.runAnimationGroup({ context in
        let disableAnimation = !isAnimationEnabled || AccessibilityPreferences.motionReductionEnabled
        if disableAnimation {
          context.duration = 0
        } else {
          context.duration = nextTask.duration
        }
        context.allowsImplicitAnimation = !disableAnimation

        if let timingFunc = nextTask.timingFunction {
          context.timingFunction = timingFunc
        }
        nextTask.runFunc()
      }, completionHandler: {
        self.runTasks()
      })
    }
  }

  static func runAsync(_ task: Task, then doAfter: TaskFunc? = nil) {
    NSAnimationContext.runAnimationGroup({ context in
      let disableAnimation = !isAnimationEnabled || AccessibilityPreferences.motionReductionEnabled
      if disableAnimation {
        context.duration = 0
      } else {
        context.duration = task.duration
      }
      context.allowsImplicitAnimation = !disableAnimation

      if let timingFunc = task.timingFunction {
        context.timingFunction = timingFunc
      }
      task.runFunc()
    }, completionHandler: {
      if let doAfter = doAfter {
        doAfter()
      }
    })
  }
}

// MARK: - Extensions for disabling animation

extension NSLayoutConstraint {
  /// Even when executed inside an animation block, MacOS only sometimes creates implicit animations for changes to constraints.
  /// Using an explicit call to `animator()` seems to be required to guarantee it, but we do not always want it to animate.
  /// This function will automatically disable animations in case they are disabled.
  func animateToConstant(_ newConstantValue: CGFloat) {
    if CocoaAnimation.isAnimationEnabled {
      self.animator().constant = newConstantValue
    } else {
      self.constant = newConstantValue
    }
  }
}
