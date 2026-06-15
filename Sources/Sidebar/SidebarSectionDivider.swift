import SwiftUI

struct SidebarSectionDivider: View {
    @Binding var sectionHeight: Double
    @Binding var dragInitialHeight: Double?
    let totalHeight: CGFloat
    let clamp: (Double, CGFloat) -> CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.gray.opacity(0.3))
            .frame(height: 4)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if dragInitialHeight == nil {
                            dragInitialHeight = sectionHeight
                        }
                        sectionHeight = Double(clamp(
                            (dragInitialHeight ?? sectionHeight) + Double(value.translation.height),
                            totalHeight
                        ))
                    }
                    .onEnded { _ in
                        dragInitialHeight = nil
                    }
            )
    }
}
