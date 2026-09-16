import SwiftUI

/// Shared job tooltip: separate visual treatment from the compact progress dots.
struct CIJobHoverPanel: View {
    let job: PipelineStage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Label(job.state.label, systemImage: "circle.fill")
                    .foregroundStyle(job.state.color)
                Spacer(minLength: 0)
                Label(job.duration == "—" || job.duration.isEmpty ? L("耗时未知") : job.duration,
                      systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 10))
            if let group = job.group, !group.isEmpty, group != job.name {
                Text(LF("阶段：%@", group))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(width: 210, alignment: .leading)
        .background(Color(red: 0.10, green: 0.12, blue: 0.16), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.13)))
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct CIJobHoverTarget {
    let job: PipelineStage
    let bounds: Anchor<CGRect>
}

struct CIJobHoverPreference: PreferenceKey {
    static var defaultValue: CIJobHoverTarget? { nil }
    static func reduce(value: inout CIJobHoverTarget?, nextValue: () -> CIJobHoverTarget?) {
        if let next = nextValue() { value = next }
    }
}

/// Render above the entire panel, rather than between sibling cards and borders.
struct CIJobHoverOverlay: View {
    let target: CIJobHoverTarget?

    var body: some View {
        GeometryReader { geometry in
            if let target {
                let node = geometry[target.bounds]
                let below = node.minY < 110
                Color.clear
                    .overlay(alignment: .topLeading) {
                        CIJobHoverPanel(job: target.job)
                            .alignmentGuide(.top) { dimensions in below ? 0 : dimensions.height }
                            .offset(
                                x: min(max(8, node.midX - 105), max(8, geometry.size.width - 218)),
                                y: below ? node.maxY + 6 : node.minY - 6
                            )
                    }
            }
        }
        .allowsHitTesting(false)
    }
}
