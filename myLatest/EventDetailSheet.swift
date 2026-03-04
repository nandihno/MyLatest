//
//  EventDetailSheet.swift
//  myLatest
//
//  Wraps EKEventViewController (from EventKitUI) so it can be presented
//  as a SwiftUI .sheet().  Shows the exact same native Calendar event-detail
//  view that the Calendar app uses — title, time, location, notes, invitees, etc.
//

import EventKitUI
import SwiftUI

struct EventDetailSheet: UIViewControllerRepresentable {

    let eventIdentifier: String
    @Environment(\.dismiss) private var dismiss

    // MARK: - UIViewControllerRepresentable

    func makeUIViewController(context: Context) -> UINavigationController {
        let vc = EKEventViewController()

        // Look up the live EKEvent from the same store that fetched it.
        if let ekEvent = CalendarService.shared.ekEvent(withIdentifier: eventIdentifier) {
            vc.event = ekEvent
        }

        vc.allowsEditing  = false  // view-only; set true if you want in-app editing
        vc.allowsCalendarPreview = false
        vc.delegate = context.coordinator

        // Wrap in a NavigationController so the title bar and Done button render.
        return UINavigationController(rootViewController: vc)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    // MARK: - Coordinator (EKEventViewDelegate)

    final class Coordinator: NSObject, EKEventViewDelegate {
        let parent: EventDetailSheet
        init(_ parent: EventDetailSheet) { self.parent = parent }

        func eventViewController(_ controller: EKEventViewController,
                                 didCompleteWith action: EKEventViewAction) {
            parent.dismiss()
        }
    }
}
