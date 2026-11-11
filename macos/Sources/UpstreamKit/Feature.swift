import Foundation

/// A part of the app with state of its own (branches, history, the forge),
/// owned by `AppModel` and reaching git and the selected repository through
/// it. `app` is set once, right after the model is made.
@MainActor public protocol Feature: AnyObject {
    var app: AppModel? { get set }
}
