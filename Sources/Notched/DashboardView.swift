import SwiftUI

struct DashboardView: View {
  @EnvironmentObject private var store: SessionStore
  @State private var now = Date()
  /// Forwarded from NotchRootView so we can re-fetch recents each time
  /// the panel expands (not just on first appear).
  var isExpanded: Bool = true

  private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      DashboardHeader(now: now)

      // Scrollable middle: live tasks + recent sessions
      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: 0) {
          if store.tasks.isEmpty && store.recentSessions.isEmpty {
            EmptyStateView()
          }

          if !store.tasks.isEmpty {
            VStack(spacing: 0) {
              ForEach(Array(store.tasks.enumerated()), id: \.element.id) { index, task in
                TaskRowView(task: task, now: now)
                if index < store.tasks.count - 1 {
                  Rectangle().fill(Theme.divider).frame(height: 1)
                }
              }
            }
          }

          if !store.recentSessions.isEmpty {
            if !store.tasks.isEmpty {
              Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 4)
            }
            RecentSessionsView(sessions: Array(store.recentSessions.prefix(6)), now: now)
          }
        }
      }

      ActivityFeedView(entries: store.activity)
    }
    .padding(Theme.panelPadding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .onReceive(tick) { now = $0 }
    .task { store.refreshRecentSessions() }
    .onChange(of: isExpanded) { expanded in
      if expanded { store.refreshRecentSessions() }
    }
  }
}

// MARK: - Empty state

private struct EmptyStateView: View {
  var body: some View {
    Text("No Claude Code sessions yet")
      .font(Theme.Text.body)
      .foregroundStyle(Theme.textDim)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 24)
  }
}

// MARK: - Recent sessions

private struct RecentSessionsView: View {
  let sessions: [PastSession]
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("RECENT")
        .font(Theme.Text.label)
        .foregroundStyle(Theme.textDim)
        .padding(.top, 8)
        .padding(.bottom, 4)

      ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
        PastSessionRowView(session: session, now: now)
        if index < sessions.count - 1 {
          Rectangle().fill(Theme.divider).frame(height: 1)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct PastSessionRowView: View {
  let session: PastSession
  let now: Date

  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      // Neutral dot — session is done/past
      Circle()
        .fill(Theme.textDim)
        .frame(width: 6, height: 6)

      VStack(alignment: .leading, spacing: 2) {
        Text(session.title)
          .font(Theme.Text.title)
          .foregroundStyle(Theme.textSecondary)
          .lineLimit(1)

        HStack(spacing: 4) {
          Text(session.repo)
            .font(Theme.Text.meta)
            .foregroundStyle(Theme.textDim)
          if let branch = session.branch {
            Text("·").font(Theme.Text.meta).foregroundStyle(Theme.textDim)
            Text(branch).font(Theme.Text.meta).foregroundStyle(Theme.textDim)
          }
          Text("·").font(Theme.Text.meta).foregroundStyle(Theme.textDim)
          Text(relativeTime(now.timeIntervalSince(session.lastActive)))
            .font(Theme.Text.meta)
            .foregroundStyle(Theme.textDim)
        }
      }

      Spacer(minLength: 8)

      Button("RESUME") {
        ResumeLauncher.launch(session: session)
      }
      .buttonStyle(NotchSecondaryButtonStyle())
    }
    .padding(.vertical, 7)
  }

  private func relativeTime(_ interval: TimeInterval) -> String {
    let s = max(0, Int(interval))
    if s < 60 { return "\(s)s ago" }
    let m = s / 60
    if m < 60 { return "\(m)m ago" }
    let h = m / 60
    if h < 24 { return "\(h)h ago" }
    return "\(h / 24)d ago"
  }
}

// MARK: - Header / stats

private struct DashboardHeader: View {
  @EnvironmentObject private var store: SessionStore
  let now: Date

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        HStack(spacing: 6) {
          Text("AGENTNOTCH")
            .font(Theme.Text.label)
            .foregroundStyle(Theme.textDim)
          Text("v1.4.0")
            .font(Theme.Text.meta)
            .foregroundStyle(Theme.textDim)
        }
        Spacer()
        HStack(spacing: 10) {
          Text("\(store.runningCount) running").font(Theme.Text.meta).foregroundStyle(
            Theme.textSecondary)
          Text("\(store.tasks.count) total").font(Theme.Text.meta).foregroundStyle(Theme.textDim)
        }
      }

      HStack(alignment: .top, spacing: 18) {
        StatCell(
          label: "NEEDS YOU", value: "\(store.needsYouCount)", sub: "sorted to the top",
          big: true, valueColor: Theme.statusNeedsYou
        )
        StatCell(
          label: "WAITING ON YOU",
          value: store.waitingOnYouSince.map { AgentTask.durationText(now.timeIntervalSince($0)) }
            ?? "—",
          sub: store.waitingOnYouSince == nil ? "nothing pending" : "since first flagged",
          valueColor: Theme.statusRunning
        )
        StatCell(label: "RUNS", value: "\(store.tasks.count)", sub: "tracked this session")
        StatCell(label: "COST", value: "—", sub: "not tracked yet")
        StatCell(
          label: "SHIPPED", value: "\(store.shippedCount)",
          sub: "\(store.testsPassedCount) tests passed",
          valueColor: Theme.statusDone
        )
      }.frame(maxWidth: .infinity)
    }
  }
}

private struct StatCell: View {
  let label: String
  let value: String
  let sub: String
  var big: Bool = false
  var valueColor: Color = Theme.textPrimary

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(Theme.Text.label)
        .foregroundStyle(Theme.textDim)
        .fixedSize()
      Text(value)
        .font(big ? Theme.Text.hero : Theme.Text.stat)
        .foregroundStyle(valueColor)
      Text(sub)
        .font(Theme.Text.meta)
        .foregroundStyle(Theme.textSecondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

// MARK: - Activity feed

private struct ActivityFeedView: View {
  let entries: [ActivityEntry]

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("ACTIVITY FEED")
        .font(Theme.Text.label)
        .foregroundStyle(Theme.textDim)
        .padding(.bottom, 2)

      if entries.isEmpty {
        Text("Nothing yet")
          .font(Theme.Text.meta)
          .foregroundStyle(Theme.textDim)
      } else {
        ForEach(entries) { entry in
          HStack(spacing: 8) {
            Text(entry.time)
              .font(Theme.Text.meta)
              .foregroundStyle(Theme.textDim)
            Text(entry.repo)
              .font(Theme.mono(9, .medium))
              .foregroundStyle(Theme.textSecondary)
            Text(entry.message)
              .font(Theme.Text.meta)
              .foregroundStyle(Theme.textSecondary)
            Spacer()
          }
        }
      }
    }.frame(maxWidth: .infinity)
  }
}

#Preview {
  let store = SessionStore()
  return DashboardView()
    .environmentObject(store)
    .frame(width: 520, height: 420)
    .background(Theme.background)
}
