//
//  SuggestedDeviationCard.swift
//  PhysicalContext
//
//  Created by Carly Googel on 5/4/26.
//

import Foundation
import SwiftUI

struct SuggestedDeviationCard: View {
    let suggestion: SuggestedDeviation
    let onAccept: () -> Void
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                TagView(label: suggestion.severity.rawValue.uppercased(),
                        color: suggestion.severity == .major ? Theme.danger
                             : suggestion.severity == .moderate ? Theme.warning
                             : Color(hex: "#3B82F6"))
                Text(suggestion.description)
                    .font(Theme.sans(12)).foregroundColor(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button {
                    expanded.toggle()
                } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.textTertiary)
                }.buttonStyle(.plain)
            }

            if expanded {
                Text(suggestion.reasoning)
                    .font(Theme.sans(11)).foregroundColor(Theme.textSecondary)
                    .padding(8).background(Theme.surfaceHigh).cornerRadius(6)
            }

            HStack {
                Spacer()
                Button("Dismiss") { /* mark dismissed */ }
                    .font(Theme.sans(11))
                    .foregroundColor(Theme.textTertiary)
                    .buttonStyle(.plain)
                Button("Accept as Deviation") {
                    onAccept()
                }
                .font(Theme.sans(11, .medium))
                .foregroundColor(.white)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Theme.warning.opacity(0.85))
                .cornerRadius(6)
                .buttonStyle(.plain)
            }
        }
        .surfaceCard(12)
    }
}
