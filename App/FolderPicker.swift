//
// FolderPicker.swift
// Ain
//
// Created by Ain on 2026/11/20.
//

import SwiftUI
import UniformTypeIdentifiers

struct FolderPicker: ViewModifier {
    @Binding var isPresented: Bool
    let types: [UTType]
    let complete: (Result<Selection, Error>) -> Void

    func body(content: Content) -> some View {
        let importer = content.fileImporter(isPresented: $isPresented, allowedContentTypes: types) { result in
            complete(result.map(Selection.init))
        }
        if #available(iOS 17.0, *) {
            importer.fileDialogDefaultDirectory(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        } else {
            importer
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
