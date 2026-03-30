//
//  DrivingTimesCard.swift
//  myLatest
//

import SwiftUI

// MARK: - Driving Times Card

struct DrivingTimesCard: View {
    let estimates: [DrivingTimeEstimate]
    let provider: DrivingProvider
    @Environment(\.themePalette) private var palette

    private var poweredByText: String {
        switch provider {
        case .apple:  return "Powered by Apple Maps"
        case .google: return "Powered by Google Maps"
        }
    }

    var body: some View {
        CardContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Driving Times", systemImage: "car.fill")
                        .font(.transit(14, weight: .bold))
                        .foregroundStyle(palette.accent)
                    Spacer()
                    Text(poweredByText)
                        .font(.transit(11, weight: .medium))
                        .foregroundStyle(palette.textTertiary)
                }

                if estimates.isEmpty {
                    Text("Add destinations in Settings to see live driving times from your current location.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(estimates) { estimate in
                        DrivingTimeRow(estimate: estimate, provider: provider)
                        if estimate.id != estimates.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Driving Time Row

private struct DrivingTimeRow: View {
    let estimate: DrivingTimeEstimate
    let provider: DrivingProvider
    @Environment(\.openURL) private var openURL
    @Environment(\.themePalette) private var palette

    private var accentColor: Color {
        estimate.hasDelay ? AppTheme.danger : AppTheme.success
    }

    private var statusText: String {
        if let delayMinutes = estimate.delayMinutes, delayMinutes > 0 {
            return "+\(delayMinutes) min delay"
        }
        if estimate.hasDelay {
            return estimate.advisory ?? "Traffic delay reported"
        }
        return "No reported delay"
    }

    private func openInMaps() {
        let dest = estimate.destination
        switch provider {
        case .apple:
            if let url = URL(string: "http://maps.apple.com/?daddr=\(dest.latitude),\(dest.longitude)&dirflg=d") {
                openURL(url)
            }
        case .google:
            let appURL = URL(string: "comgooglemaps://?daddr=\(dest.latitude),\(dest.longitude)&directionsmode=driving")!
            let webURL = URL(string: "https://www.google.com/maps/dir/?api=1&destination=\(dest.latitude),\(dest.longitude)&travelmode=driving")!
            openURL(appURL) { accepted in
                if !accepted { openURL(webURL) }
            }
        }
    }

    var body: some View {
        Button(action: openInMaps) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(estimate.destination.displayName)
                        .font(.transit(18, weight: .bold))
                        .foregroundStyle(palette.textPrimary)
                    Text(estimate.destination.displaySubtitle)
                        .font(.transit(13, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if let errorMessage = estimate.errorMessage {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Unavailable")
                            .font(.transit(18, weight: .bold))
                            .foregroundStyle(AppTheme.danger)
                        Text(errorMessage)
                            .font(.caption2)
                            .foregroundStyle(palette.textSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                } else if let travelMinutes = estimate.travelMinutes {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(travelMinutes) min")
                            .font(.transit(28, weight: .heavy))
                            .foregroundStyle(accentColor)
                        Text(statusText)
                            .font(.transit(12, weight: .bold))
                            .foregroundStyle(accentColor)
                            .multilineTextAlignment(.trailing)
                        if let advisory = estimate.advisory {
                            Text(advisory)
                                .font(.transit(12, weight: .medium))
                                .foregroundStyle(palette.textSecondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}
