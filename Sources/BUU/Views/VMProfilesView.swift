import SwiftUI

struct VMProfilesView: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("VM Profiles")
                        .font(.title2.weight(.semibold))
                    Text("Reusable macOS image, hardware and display settings for Mac Tasks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.l)
            .background(.bar)

            Divider()

            MacTaskSettingsView()
        }
        .background(Theme.Colors.canvas)
    }
}
