import SwiftUI
import UIKit

struct ReaderKeyboard: UIViewControllerRepresentable {
    var enabled: Bool
    var previous: () -> Void
    var next: () -> Void
    var menu: () -> Void
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.previousPage = previous; controller.nextPage = next; controller.menu = menu
        if controller.enabled != enabled {
            controller.enabled = enabled
            if enabled && controller.view.window != nil { controller.becomeFirstResponder() }
            else { controller.resignFirstResponder() }
        }
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.enabled = false; controller.resignFirstResponder() }
    final class Controller: UIViewController {
        var enabled = false
        var previousPage: (() -> Void)?, nextPage: (() -> Void)?, menu: (() -> Void)?
        override var canBecomeFirstResponder: Bool { enabled }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); if enabled { becomeFirstResponder() } }
        override var keyCommands: [UIKeyCommand]? {
            guard enabled, !ReaderSelectionDelegate.shared.hasSelection else { return nil }
            let inputs = [(UIKeyCommand.inputLeftArrow, #selector(back)), (UIKeyCommand.inputUpArrow, #selector(back)),
                          (UIKeyCommand.inputPageUp, #selector(back)), (UIKeyCommand.inputRightArrow, #selector(forward)),
                          (UIKeyCommand.inputDownArrow, #selector(forward)), (UIKeyCommand.inputPageDown, #selector(forward)),
                          (" ", #selector(forward)), (UIKeyCommand.inputEscape, #selector(showMenu))]
            return inputs.map { input, action in
                let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
                command.wantsPriorityOverSystemBehavior = true; return command
            }
        }
        @objc private func back() { previousPage?() }
        @objc private func forward() { nextPage?() }
        @objc private func showMenu() { menu?() }
    }
}
