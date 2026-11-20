//
// IDEEditor.swift
// Ain
//
// Created by Ain on 2026/11/20.
//

import SwiftUI
import UIKit

struct EditorLocation: Equatable {
    let line: Int
    let column: Int
    let id = UUID()
}

struct IDEEditor: UIViewRepresentable {
    @Binding var text: String
    let path: String
    let location: EditorLocation?
    let projectWords: [String]
    let editable: Bool
    var predictionEnabled = true
    var editingChanged: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CodeSurface {
        let surface = CodeSurface()
        let view = surface.editor
        view.backgroundColor = .systemBackground
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.spellCheckingType = .no
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 16, right: 12)
        view.accessibilityIdentifier = "source-editor"
        view.accessibilityLabel = "代码编辑器"
        context.coordinator.gutter = surface.gutter
        view.delegate = context.coordinator
        view.inputAccessoryView = context.coordinator.accessory
        (view as? CodeTextView)?.handleCompletion = { [weak coordinator = context.coordinator] key in
            coordinator?.handleCompletion(key) ?? false
        }
        return surface
    }

    func updateUIView(_ surface: CodeSurface, context: Context) {
        let view = surface.editor
        let editor = context.coordinator
        let changedPrediction = editor.parent.predictionEnabled != predictionEnabled
        editor.parent = self
        view.isEditable = editable
        if editor.loadedPath != path || view.text != text {
            editor.loadedPath = path
            view.text = text
            view.selectedRange = NSRange(location: 0, length: 0)
            view.undoManager?.removeAllActions()
            editor.highlight(view)
            surface.gutter.setNeedsDisplay()
            editor.updateCompletions(view)
        }
        if let location, editor.lastLocation != location {
            editor.lastLocation = location
            editor.jump(location, in: view)
        }
        if changedPrediction { editor.updateCompletions(view) }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: IDEEditor
        var loadedPath: String?
        var lastLocation: EditorLocation?
        private weak var view: UITextView?
        weak var gutter: LineNumbers?
        private let suggestions = UIStackView()
        private var matches: [String] = []
        private var selectedSuggestion = 0
        private var prefix = NSRange(location: 0, length: 0)
        private static let word = try! NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z_0-9]*"#)
        private static let keywords = """
            auto bool break case char const continue default do double else enum extern float for if inline int long
            register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while
            class constexpr namespace nullptr private protected public template typename using new delete override
            id nil YES NO self super instancetype import interface implementation property protocol synthesize end
            selector available autoreleasepool try catch finally throw weak strong nonatomic readonly readwrite
            hook hookf orig new ctor dtor group init end config self subclass log
            include define endif ifdef ifndef elif error pragma undef warning
            let var func extension guard defer async await true false final fileprivate import
            """.split(whereSeparator: \.isWhitespace).map(String.init)
        private static let symbols = ["NSLog", "NSString", "NSArray", "NSDictionary", "NSObject", "NSInteger",
                                      "UIView", "UIViewController", "UIColor", "dispatch_async", "dispatch_get_main_queue",
                                      "printf", "size_t", "Makefile", "ARCHS", "TARGET", "THEOS", "THEOS_MAKE_PATH",
                                      "LIBRARY_NAME", "APPLICATION_NAME", "TWEAK_NAME", "CoreGraphics", "UIKit",
                                      "Foundation", "CGRectMake", "CGRectZero", "CGPointMake", "CGSizeMake",
                                      "UIEdgeInsetsMake", "UIViewAutoresizingFlexibleWidth", "UIButton",
                                      "UIFont", "UIImage", "UIImageView", "UILabel", "UITableView", "UIStackView",
                                      "UIApplication", "UIWindow", "UIWindowScene", "UIAlertController",
                                      "NSFileManager", "NSData", "NSMutableArray", "NSTimer", "NSURLSession",
                                      "NSPredicate", "NSError", "NSSet", "NSRange", "NSMakeRange", "CFRelease",
                                      "CFStringRef", "dispatch_once", "dispatch_after", "dispatch_queue_t"]
        private static let members = ["alloc", "init", "new", "sharedApplication", "defaultManager", "mainBundle",
                                      "viewDidLoad", "viewWillAppear", "viewDidAppear", "viewWillDisappear",
                                      "addSubview", "removeFromSuperview", "setNeedsLayout", "layoutIfNeeded",
                                      "addTarget", "backgroundColor", "cornerRadius", "bounds", "frame",
                                      "layer", "alpha", "hidden", "textColor", "textAlignment", "font",
                                      "connectedScenes", "keyWindow", "rootViewController", "presentViewController"]
        private static let tokens = try! NSRegularExpression(pattern:
            #"(?s:/\*.*?(?:\*/|\z))|//[^\r\n]*|@?"(?:\\.|[^"\\\r\n])*"|'(?:\\.|[^'\\\r\n])*'|\b(?:0[xX][0-9A-Fa-f]+|[0-9]+(?:\.[0-9]+)?)\b|[@%]?[A-Za-z_][A-Za-z_0-9]*"#)
        private static let keywordSet = Set(keywords)
        private static let symbolSet = Set(symbols)
        private static let pairs = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"]

        init(_ parent: IDEEditor) { self.parent = parent }

        lazy var accessory: UIView = {
            let bar = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 42))
            bar.backgroundColor = .secondarySystemBackground
            let scroll = UIScrollView()
            scroll.showsHorizontalScrollIndicator = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            suggestions.axis = .horizontal
            suggestions.spacing = 12
            suggestions.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(scroll)
            scroll.addSubview(suggestions)
            NSLayoutConstraint.activate([
                scroll.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
                scroll.topAnchor.constraint(equalTo: bar.topAnchor),
                scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
                suggestions.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 12),
                suggestions.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -12),
                suggestions.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                suggestions.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                suggestions.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
            ])
            return bar
        }()

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            if textView.markedTextRange == nil {
                highlight(textView)
                updateCompletions(textView)
            }
            gutter?.setNeedsDisplay()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.editingChanged(true)
            updateCompletions(textView)
        }
        func textViewDidEndEditing(_ textView: UITextView) {
            parent.editingChanged(false)
            (textView as? CodeTextView)?.showPrediction(nil)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if textView.markedTextRange == nil { updateCompletions(textView) }
            gutter?.setNeedsDisplay()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            gutter?.setNeedsDisplay()
            (scrollView as? CodeTextView)?.positionPrediction()
        }

        func textView(_ view: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard view.markedTextRange == nil else { return true }
            let source = view.text as NSString
            if text == "\n" {
                let line = source.lineRange(for: NSRange(location: range.location, length: 0))
                let before = source.substring(with: NSRange(location: line.location, length: range.location - line.location))
                let indent = before.prefix { $0 == " " || $0 == "\t" }
                if !indent.isEmpty || before.last == "{" {
                    replace(view, range: range, with: "\n" + indent + (before.last == "{" ? "    " : ""))
                    return false
                }
            }
            if range.length == 0, Self.pairs.values.contains(text),
               range.location < source.length, source.substring(with: NSRange(location: range.location, length: 1)) == text {
                view.selectedRange = NSRange(location: range.location + 1, length: 0)
                return false
            }
            if let closing = Self.pairs[text] {
                let selected = source.substring(with: range)
                replace(view, range: range, with: text + selected + closing)
                view.selectedRange = NSRange(location: range.location + 1, length: range.length)
                return false
            }
            return true
        }

        func highlight(_ view: UITextView) {
            let storage = view.textStorage
            let text = storage.string
            let ns = text as NSString
            let range = NSRange(location: 0, length: ns.length)
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: UIColor.label, range: range)
            if ns.length <= 350_000 {
                let make = parent.path.lowercased().hasSuffix(".mk") ||
                    ["Makefile", "makefile", "GNUmakefile"].contains((parent.path as NSString).lastPathComponent)
                Self.tokens.enumerateMatches(in: text, range: range) { result, _, _ in
                    guard let target = result?.range else { return }
                    let token = ns.substring(with: target)
                    let color: UIColor
                    if token.hasPrefix("//") || token.hasPrefix("/*") { color = .systemGreen }
                    else if token.hasPrefix("\"") || token.hasPrefix("@\"") || token.hasPrefix("'") { color = .systemOrange }
                    else if token.first?.isNumber == true { color = .systemTeal }
                    else if Self.keywordSet.contains(String(token.drop(while: { $0 == "@" || $0 == "%" }))) { color = .systemPurple }
                    else if Self.symbolSet.contains(token) || (make && token == token.uppercased()) { color = .systemBlue }
                    else { return }
                    storage.addAttribute(.foregroundColor, value: color, range: target)
                }
            }
            storage.endEditing()
            view.typingAttributes[.foregroundColor] = UIColor.label
        }

        func updateCompletions(_ view: UITextView) {
            self.view = view
            matches = []
            selectedSuggestion = 0
            let ns = view.text as NSString
            let cursor = view.selectedRange.location
            if parent.predictionEnabled, view.selectedRange.length == 0, cursor <= ns.length {
                var start = cursor
                while start > max(0, cursor - 64) {
                    let unit = ns.character(at: start - 1)
                    guard (65...90).contains(unit) || (97...122).contains(unit) ||
                            (48...57).contains(unit) || unit == 95 else { break }
                    start -= 1
                }
                prefix = NSRange(location: start, length: cursor - start)
                let input = ns.substring(with: prefix)
                let lineStart = ns.lineRange(for: NSRange(location: start, length: 0)).location
                let preceding = ns.substring(with: NSRange(location: lineStart, length: start - lineStart))
                let member = preceding.hasSuffix(".") || (preceding.contains("[") && preceding.last?.isWhitespace == true)
                let directive = preceding.hasSuffix("@") || preceding.hasSuffix("%") || preceding.hasSuffix("#")
                let matchesLineComment = preceding.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                if !matchesLineComment, input.count >= 2 || member || directive {
                    let before = NSRange(location: max(0, cursor - 16_000), length: min(cursor, 16_000))
                    let nearby = Self.word.matches(in: view.text, range: before).reversed().map { ns.substring(with: $0.range) }
                    let declarations = EditorSymbol.read(view.text).map { $0.name.trimmingCharacters(in: CharacterSet(charactersIn: ":")) }
                    let projectNames = parent.projectWords.map {
                        (($0 as NSString).lastPathComponent as NSString).deletingPathExtension
                    }
                    let candidates = directive ? Self.keywords : (member ? Self.members : []) +
                        declarations + nearby + projectNames + Self.symbols + Self.keywords
                    var seen = Set<String>()
                    let lower = input.lowercased()
                    matches = Array(candidates.filter {
                        $0 != input && $0.lowercased().hasPrefix(lower) && seen.insert($0).inserted
                    }.prefix(10))
                }
            }
            renderSuggestions()
        }

        private func renderSuggestions() {
            if let editor = view as? CodeTextView {
                let text = editor.text as NSString
                let nextIndex = NSMaxRange(prefix)
                let atLineEnd = nextIndex >= text.length ||
                    [UInt16(10), UInt16(13)].contains(text.character(at: nextIndex))
                let match = matches.isEmpty ? nil : matches[selectedSuggestion]
                editor.showPrediction(atLineEnd && prefix.length >= 2
                    ? match.map { String($0.dropFirst(prefix.length)) } : nil)
            }
            for subview in suggestions.arrangedSubviews {
                suggestions.removeArrangedSubview(subview)
                subview.removeFromSuperview()
            }
            for (index, word) in matches.enumerated() {
                let button = UIButton(type: .system)
                button.setTitle(word, for: .normal)
                button.titleLabel?.font = .monospacedSystemFont(ofSize: 13, weight: index == selectedSuggestion ? .bold : .medium)
                if index == selectedSuggestion {
                    button.tintColor = .label
                    button.backgroundColor = .tertiarySystemFill
                }
                button.accessibilityLabel = "补全 \(word)"
                button.addAction(UIAction { [weak self] _ in
                    self?.accept(word)
                }, for: .touchUpInside)
                suggestions.addArrangedSubview(button)
            }
            if matches.isEmpty {
                for text in ["\t", "#", "%", "@", "{", "}", ";"] {
                    let button = UIButton(type: .system)
                    button.setTitle(text == "\t" ? "Tab" : text, for: .normal)
                    button.addAction(UIAction { [weak self] _ in self?.view?.insertText(text) }, for: .touchUpInside)
                    suggestions.addArrangedSubview(button)
                }
            }
        }

        private func accept(_ word: String) {
            guard let view, view.markedTextRange == nil,
                  NSMaxRange(prefix) == view.selectedRange.location else { return }
            replace(view, range: prefix, with: word)
            matches = []
            renderSuggestions()
        }

        func handleCompletion(_ key: String) -> Bool {
            guard !matches.isEmpty else { return false }
            switch key {
            case "\t": accept(matches[selectedSuggestion])
            case UIKeyCommand.inputEscape:
                matches = []
                renderSuggestions()
            case UIKeyCommand.inputDownArrow, UIKeyCommand.inputUpArrow:
                let step = key == UIKeyCommand.inputDownArrow ? 1 : -1
                selectedSuggestion = (selectedSuggestion + step + matches.count) % matches.count
                renderSuggestions()
            default: return false
            }
            return true
        }

        func jump(_ location: EditorLocation, in view: UITextView) {
            let ns = view.text as NSString
            var start = 0
            for _ in 0..<max(0, location.line - 1) {
                guard start < ns.length else { break }
                start = NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0)))
            }
            let lineEnd = start < ns.length ? NSMaxRange(ns.lineRange(for: NSRange(location: start, length: 0))) : ns.length
            let target = min(lineEnd, start + max(0, location.column - 1))
            view.selectedRange = NSRange(location: target, length: 0)
            view.scrollRangeToVisible(view.selectedRange)
        }

        private func replace(_ view: UITextView, range: NSRange, with text: String) {
            guard let start = view.position(from: view.beginningOfDocument, offset: range.location),
                  let end = view.position(from: start, offset: range.length),
                  let selected = view.textRange(from: start, to: end) else { return }
            view.replace(selected, withText: text)
            view.selectedRange = NSRange(location: range.location + (text as NSString).length, length: 0)
            textViewDidChange(view)
        }
    }
}

final class CodeTextView: UITextView {
    var handleCompletion: ((String) -> Bool)?
    private let prediction = UILabel()

    func showPrediction(_ suffix: String?) {
        prediction.text = suffix
        prediction.font = font
        prediction.textColor = .tertiaryLabel
        if prediction.superview == nil {
            prediction.isUserInteractionEnabled = false
            prediction.isAccessibilityElement = false
            addSubview(prediction)
        }
        positionPrediction()
    }

    func positionPrediction() {
        prediction.isHidden = true
        guard isFirstResponder, markedTextRange == nil, !(prediction.text ?? "").isEmpty,
              let caret = selectedTextRange?.end else { return }
        let rectangle = caretRect(for: caret)
        let size = prediction.sizeThatFits(.zero)
        guard rectangle.minX + size.width < bounds.maxX - textContainerInset.right,
              rectangle.intersects(bounds) else { return }
        prediction.frame = CGRect(x: rectangle.minX + 1, y: rectangle.midY - size.height / 2,
                                   width: size.width + 1, height: size.height)
        prediction.isHidden = false
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.count == 1, let key = presses.first?.key, key.modifierFlags.isEmpty {
            let input: String
            switch key.keyCode {
            case .keyboardUpArrow: input = UIKeyCommand.inputUpArrow
            case .keyboardDownArrow: input = UIKeyCommand.inputDownArrow
            case .keyboardEscape: input = UIKeyCommand.inputEscape
            case .keyboardTab: input = "\t"
            default: input = key.charactersIgnoringModifiers
            }
            if handleCompletion?(input) == true { return }
        }
        super.pressesBegan(presses, with: event)
    }
}

final class CodeSurface: UIView {
    let editor: UITextView
    let gutter = LineNumbers()

    override init(frame: CGRect) {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: .zero)
        container.widthTracksTextView = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        editor = CodeTextView(frame: .zero, textContainer: container)
        super.init(frame: frame)
        gutter.editor = editor
        gutter.backgroundColor = .secondarySystemBackground
        gutter.isAccessibilityElement = false
        for view in [editor, gutter] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(equalTo: bottomAnchor),
            gutter.widthAnchor.constraint(equalToConstant: 49),
            editor.leadingAnchor.constraint(equalTo: gutter.trailingAnchor),
            editor.trailingAnchor.constraint(equalTo: trailingAnchor),
            editor.topAnchor.constraint(equalTo: topAnchor),
            editor.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        gutter.setNeedsDisplay()
    }
}

final class LineNumbers: UIView {
    weak var editor: UITextView?

    override func draw(_ rect: CGRect) {
        guard let editor, let text = editor.text else { return }
        let ns = text as NSString
        let manager = editor.layoutManager
        let inset = editor.textContainerInset.top
        let offset = editor.contentOffset.y
        let visible = CGRect(x: 0, y: max(0, offset - inset), width: editor.bounds.width,
                             height: editor.bounds.height + inset)
        let glyphs = manager.glyphRange(forBoundingRect: visible, in: editor.textContainer)
        var prior = -1
        var line = 1
        var scan = 0
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let style: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.secondaryLabel,
            .font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
            .paragraphStyle: paragraph
        ]
        manager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, glyphRange, _ in
            let index = manager.characterIndexForGlyph(at: glyphRange.location)
            let start = ns.lineRange(for: NSRange(location: index, length: 0)).location
            guard start != prior else { return }
            if prior != -1 || index == start {
                while scan < start {
                    scan = NSMaxRange(ns.lineRange(for: NSRange(location: scan, length: 0)))
                    line += 1
                }
                (String(line) as NSString).draw(in: CGRect(x: 2, y: used.minY + inset - offset + 1,
                                                           width: self.bounds.width - 9, height: 19),
                                                withAttributes: style)
            }
            prior = start
        }
        if ns.length == 0 || text.last?.isNewline == true {
            let extra = manager.extraLineFragmentRect
            if extra.minY + inset - offset <= bounds.height {
                if ns.length > 0 {
                    while scan < ns.length {
                        scan = NSMaxRange(ns.lineRange(for: NSRange(location: scan, length: 0)))
                        line += 1
                    }
                }
                (String(line) as NSString).draw(in: CGRect(x: 2, y: extra.minY + inset - offset + 1,
                                                           width: bounds.width - 9, height: 19),
                                                withAttributes: style)
            }
        }
    }
}
