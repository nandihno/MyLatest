//
//  LoadState.swift
//  myLatest
//

import Foundation

// MARK: - Load State

enum LoadState {
    case idle
    case loading
    case loaded(DashboardData)

    var data: DashboardData? {
        if case .loaded(let d) = self { return d }
        return nil
    }
    var isIdle:    Bool { if case .idle    = self { return true }; return false }
    var isLoading: Bool { if case .loading = self { return true }; return false }
    var isLoaded:  Bool { if case .loaded  = self { return true }; return false }
    var shouldRedact: Bool { !isLoaded }
}
