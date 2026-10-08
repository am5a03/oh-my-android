import SwiftUI

struct FeatureGridView: View {
    let context: DeviceContext
    @Environment(AppModel.self) private var model

    private let columns = Array(repeating: GridItem(.fixed(Theme.cellWidth), spacing: 6), count: Theme.columns)
    /// These actions now have dedicated, selected-app controls above the grid.
    private let quickActionIDs: Set<String> = ["app.restart", "app.clearData", "app.deepLink"]

    var body: some View {
        ScrollView(.vertical) {
            GlassEffectContainer(spacing: 12) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    AppQuickActionsView(context: context).id(context.device.appSelectionKey)
                    ForEach(FeatureCatalog.sections(for: context.device)) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(section.category.title.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 4)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                                ForEach(section.features.filter { !quickActionIDs.contains($0.id) }, id: \.id) { feature in
                                    FeatureCell(feature: feature, context: context)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .scrollIndicators(.hidden)
        .modifier(AppActionConfirmation())
    }
}
