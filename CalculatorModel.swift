import AppKit
import Combine

/// State for the Calculator tab. The math itself lives in `Calculator` (Calculator.swift).
/// Kept in the view model so the expression survives the island collapsing.
@MainActor
final class CalculatorModel: ObservableObject {
    @Published var expression = ""
    private var justEvaluated = false

    /// Live answer, or nil while the expression is incomplete / not math.
    var result: String? { Calculator.evaluate(expression) }

    func press(_ key: String) {
        switch key {
        case "C":
            expression = ""
            justEvaluated = false
        case "⌫":
            if !expression.isEmpty { expression.removeLast() }
            justEvaluated = false
        case "=":
            if let r = result { expression = r; justEvaluated = true }
        case "+", "−", "×", "÷", "^":
            if expression.isEmpty && key != "−" { return }
            justEvaluated = false                       // keep going from the last answer
            append(key == "−" ? "-" : key)
        default:                                        // digits, ".", "(", ")"
            if justEvaluated && key != ")" { expression = "" }   // typing a number starts fresh
            justEvaluated = false
            append(key)
        }
    }

    /// ⌘V: take the clipboard text if it looks like math.
    func paste() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        let allowed = Set("0123456789.+-−*/^()×÷x")
        let cleaned = String(text.lowercased().filter { allowed.contains($0) }.prefix(60))
            .replacingOccurrences(of: "−", with: "-")
        guard !cleaned.isEmpty else { return }
        expression = cleaned
        justEvaluated = false
    }

    func copyResult() {
        let text = result ?? expression
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func append(_ s: String) {
        guard expression.count < 60 else { return }
        expression += s
    }
}
