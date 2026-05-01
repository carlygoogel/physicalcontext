//
//  ShimmerModifier.swift
//  PhysicalContext
//
//  Created by Carly Googel on 5/4/26.
//

import Foundation
import SwiftUI

extension View {
    func shimmer() -> some View {
        self.modifier(ShimmerModifier())
    }
}

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0
    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .clear, location: phase - 0.3),
                        .init(color: .white.opacity(0.08), location: phase),
                        .init(color: .clear, location: phase + 0.3)
                    ]),
                    startPoint: .leading, endPoint: .trailing
                )
                .animation(.linear(duration: 1.4).repeatForever(autoreverses: false),
                           value: phase)
            )
            .onAppear { phase = 1.3 }
            .clipped()
    }
}
