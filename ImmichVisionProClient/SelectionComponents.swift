//
//  SelectionComponents.swift
//  ImmichVisionProClient
//
//  Created by Julian Gray on 2/12/26.
//

import SwiftUI

// MARK: - Selection Overlay

/// Checkmark circle overlay for grid cells in selection mode
struct SelectionOverlay: View {
    let isSelected: Bool
    let isSelectionMode: Bool

    var body: some View {
        if isSelectionMode {
            ZStack {
                Circle()
                    .fill(isSelected ? Color.white : Color.black.opacity(0.3))
                    .frame(width: 24, height: 24)

                Circle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: 24, height: 24)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                }
            }
            .padding(6)
        }
    }
}

// MARK: - Select Button

/// Button to enter selection mode
struct SelectButton: View {
    let isSelectionMode: Bool
    let action: () -> Void

    var body: some View {
        Button("Select", action: action)
            .buttonStyle(.bordered)
            .fixedSize()
            .opacity(isSelectionMode ? 0 : 1)
    }
}

// MARK: - Batch Action Set

enum BatchActionSet {
    case standard
    case locked
}

// MARK: - Batch Action Bar

/// Floating glass capsule with batch action buttons — styled to match the primary tab ornament
struct BatchActionBar: View {
    let selectedCount: Int
    let actionSet: BatchActionSet
    let isPerformingAction: Bool
    let onAddToAlbum: () -> Void
    let onMakeOffline: () -> Void
    let onShare: () -> Void
    let onHideOrUnhide: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            switch actionSet {
            case .standard:
                batchButton(icon: "rectangle.stack.badge.plus", label: "Album", action: onAddToAlbum)
                batchButton(icon: "arrow.down.circle", label: "Offline", action: onMakeOffline)
                batchButton(icon: "square.and.arrow.up", label: "Share", action: onShare)
                batchButton(icon: "eye.slash", label: "Hide", action: onHideOrUnhide)
                batchButton(icon: "trash", label: "Delete", action: onDelete)

            case .locked:
                batchButton(icon: "square.and.arrow.up", label: "Share", action: onShare)
                batchButton(icon: "eye", label: "Unhide", action: onHideOrUnhide)
                batchButton(icon: "trash", label: "Delete", action: onDelete)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .glassBackgroundEffect(in: Capsule())
        .disabled(isPerformingAction)
        .opacity(isPerformingAction ? 0.6 : 1)
    }

    private func batchButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(label)
                    .font(.caption2)
            }
            .frame(width: 64, height: 48)
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Selection Toolbar Content

/// Toolbar items displayed during selection mode
struct SelectionToolbarContent: ToolbarContent {
    let selectedCount: Int
    let totalCount: Int
    let onSelectAll: () -> Void
    let onCancel: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 8) {
                // Selected count (hidden when 0)
                if selectedCount > 0 {
                    Text("\(selectedCount) selected")
                        .font(.headline)
                        .fixedSize()
                }

                Button(selectedCount == totalCount ? "Deselect All" : "Select All") {
                    onSelectAll()
                }
                .buttonStyle(.bordered)
                .fixedSize()

                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .fixedSize()
            }
        }
    }
}

// MARK: - Context Menu Extension

extension View {
    func contextMenuIfNotSelecting<MenuContent: View>(
        isSelectionMode: Bool,
        @ViewBuilder menuContent: () -> MenuContent
    ) -> some View {
        self.contextMenu {
            if !isSelectionMode {
                menuContent()
            }
        }
    }
}
