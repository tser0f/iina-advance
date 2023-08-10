//
//  UIAnimation.swift
//  iina
//
//  Created by Matt Svoboda on 2023-04-09.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

typealias TaskFunc = (() -> Void)
typealias AnimationBlock = (NSAnimationContext) -> Void

class UIAnimation {

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

  // MARK: - UIAnimation.Task

  struct Task {
    let duration: CGFloat
    let timingFunction: CAMediaTimingFunction?
    let runFunc: TaskFunc

    init(duration: CGFloat = UIAnimation.DefaultDuration,
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

  // MARK: - UIAnimation.Queue

  class Queue {

    private var isRunning = false
    private var queue = LinkedList<Task>()

    /// Convenience function. Same as `run([Task])`, but for a single animation.
    func run(_ task: Task, then doAfter: TaskFunc? = nil) {
      run([task], then: doAfter)
    }

    /// Recursive function which executes each of the given `AnimationTask`s one after another.
    /// Will execute without animation if motion reduction is enabled, or if wrapped in a call to `UIAnimation.disableAnimation()`.
    /// If animating, it uses either the supplied `duration` for duration, or if that is not provided, uses `UIAnimation.DefaultDuration`.
    func run(_ tasks: [Task], then doAfter: TaskFunc? = nil) {

      var needsLaunch = false
      queue.appendAll(tasks)
      if let doAfter = doAfter {
        queue.append(zeroDurationTask(doAfter))
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
      var nextTask: UIAnimation.Task? = nil

      // Group zero-duration tasks together if possible
      var zeroDurationTasks: [UIAnimation.Task] = []
      while let task = self.queue.first, task.duration == 0 {
        self.queue.removeFirst()
        zeroDurationTasks.append(task)
      }
      if !zeroDurationTasks.isEmpty {
        nextTask = UIAnimation.zeroDurationTask{
          for task in zeroDurationTasks {
            task.runFunc()
          }
        }
      } else if let poppedTask = queue.removeFirst() {
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
    if UIAnimation.isAnimationEnabled {
      self.animator().constant = newConstantValue
    } else {
      self.constant = newConstantValue
    }
  }
}
