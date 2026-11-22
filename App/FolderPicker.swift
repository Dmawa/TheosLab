//
// FolderPicker.swift
// Ain
//
// Created by Ain on 2026/11/20.
//

import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct FolderPicker: ViewModifier {
    @Binding var isPresented: Bool
    let types: [UTType]
    let complete: (Result<Selection, Error>) -> Void

    func body(content: Content) -> some View {
        if types == [.data] {
            // SwiftUI fileImporter 在 iOS 16 上对抽象类型 (.data) 会丢失确认按钮，
            // 文件选择改用 UIKit 原生 UIDocumentPickerViewController。
            content.sheet(isPresented: $isPresented) {
                DocumentPicker(types: types) { result in
                    complete(result.map(Selection.init))
                }
                    .ignoresSafeArea()
            }
        } else {
            let importer = content.fileImporter(isPresented: $isPresented, allowedContentTypes: types) { result in
                complete(result.map(Selection.init))
            }
            if #available(iOS 17.0, *) {
                importer.fileDialogDefaultDirectory(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
            } else {
                importer
            }
        }
    }

    final class Selection: @unchecked Sendable {
        let url: URL
        private let hasScope: Bool

        init(_ url: URL) {
            self.url = url
            hasScope = url.startAccessingSecurityScopedResource()
        }

        deinit {
            if hasScope { url.stopAccessingSecurityScopedResource() }
        }
    }

}

private struct DocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let complete: (Result<URL, Error>) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker

        init(_ parent: DocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            parent.complete(.success(url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.complete(.failure(CocoaError(.userCancelled)))
        }
    }
}
