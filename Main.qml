import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// The display side of agent usage. All extraction lives behind
// omarchy-agent-usage-update, which writes one JSON record per agent into
// the usage directory; this file only discovers those records, watches them
// for changes, and optionally merges snapshots synced from other machines.
Item {
  id: root
  visible: false

  property var settings: ({})

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string usageDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/agents/usage"
  readonly property string tasksPath: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/agents/tasks.json"
  property var tasksData: ({})

  FileView {
    id: tasksFile
    path: root.tasksPath
    watchChanges: true
    printErrors: false
    onLoaded: {
      try {
        root.tasksData = JSON.parse(text()) || ({})
      } catch (e) {
        root.tasksData = ({})
      }
    }
  }

  // ------------------------------------------------------------- discovery

  property var agentIds: []
  property var agents: []
  property int dataRevision: 0

  Process {
    id: listProcess
    running: false
    command: ["find", root.usageDir, "-maxdepth", "1", "-name", "*.json", "-printf", "%f\n"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyAgentListing(text)
    }
  }

  function rescanAgents() {
    if (!listProcess.running) listProcess.running = true
  }

  function applyAgentListing(output) {
    var ids = []
    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var name = lines[i].trim()
      if (name.slice(-5) === ".json") ids.push(name.slice(0, -5))
    }
    ids.sort()
    // Same list, same objects: reassigning the model would tear down every
    // FileView just to build identical ones.
    if (JSON.stringify(ids) !== JSON.stringify(agentIds)) agentIds = ids
  }

  Instantiator {
    id: agentInstantiator
    model: root.agentIds

    delegate: Agent {
      required property var modelData
      agentId: modelData
      path: root.usageDir + "/" + modelData + ".json"
      onRecordChanged: root.recordsChanged()
    }

    onObjectAdded: (index, object) => root.rebuildAgents()
    onObjectRemoved: (index, object) => root.rebuildAgents()
  }

  // Each record's FileView follows its file on its own; this catches the ones
  // whose watch was lost when an update replaced the file underneath them.
  function reloadRecords() {
    for (var i = 0; i < agents.length; i++)
      if (agents[i]) agents[i].reload()
    tasksFile.reload()
  }

  function rebuildAgents() {
    var result = []
    for (var i = 0; i < agentInstantiator.count; i++) {
      var agent = agentInstantiator.objectAt(i)
      if (agent) result.push(agent)
    }
    agents = result
    recordsChanged()
  }

  function recordsChanged() {
    dataRevision++
    scheduleLimitsRetry()
    scheduleSync()
  }

  // A collector that could not reach its limits endpoint at all — typically
  // the seconds after login before the network is up — writes retryAdvised
  // into its record. Honor it with one sooner try instead of waiting out the
  // full refresh interval; a run that reaches the endpoint clears the flag.
  // Only the advising agents rerun, so an outage at one provider does not
  // put every other collector on a 30-second treadmill.
  property var retryAgentIds: []

  Timer {
    id: limitsRetry
    interval: 30000
    running: root.retryAgentIds.length > 0
    repeat: false
    onTriggered: {
      var toRetry = root.retryAgentIds.slice()
      root.retryAgentIds = []
      root.runUpdate("limits", toRetry)
    }
  }

  function scheduleLimitsRetry() {
    var pending = []
    for (var i = 0; i < agents.length; i++) {
      var record = agents[i] ? agents[i].record : null
      if (record && record.id && record.retryAdvised === true)
        pending.push(String(record.id))
    }
    pending.sort()
    if (JSON.stringify(pending) !== JSON.stringify(retryAgentIds))
      retryAgentIds = pending
  }

  // ------------------------------------------------------------- update

  // An agent crossed into its rate limits: ask often enough to show the
  // ceiling approaching, but don't spin.
  readonly property bool nearLimit: {
    var rev = dataRevision
    for (var i = 0; i < agents.length; i++) {
      var record = agents[i] ? agents[i].record : null
      var limits = record && Array.isArray(record.limits) ? record.limits : []
      for (var j = 0; j < limits.length; j++) {
        if (Number(limits[j].percent) >= 0.8) return true
      }
    }
    return false
  }

  // When nothing is close, the update interval setting decides how often
  // to ask again.
  readonly property int configuredIntervalSec: Math.max(30, Math.min(3600, Number(setting("refreshIntervalSec", 900)) || 900))
  readonly property int refreshIntervalSec: nearLimit ? Math.min(60, configuredIntervalSec) : configuredIntervalSec

  property string pendingUpdateKind: ""

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.runUpdate(root.nearLimit ? "limits" : "normal")
  }

  Process {
    id: updateProcess
    running: false
    onExited: {
      root.rescanAgents()
      root.reloadRecords()
      if (root.pendingUpdateKind !== "") {
        var kind = root.pendingUpdateKind
        root.pendingUpdateKind = ""
        root.runUpdate(kind)
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("agents", text.trim())
    }
  }

  function updateCommand(kind, agentIds) {
    var scriptPath = root.home + "/.config/omarchy/plugins/sushantkr.agents/run_sync.sh"
    var command = [scriptPath]
    if (kind === "force") command.push("--force")
    if (kind === "limits") command.push("--limits-only")
    var providers = settings && settings.providers ? settings.providers : {}
    for (var id in providers) {
      if (providers[id] && providers[id].enabled === false) command.push("--except", id)
    }
    if (agentIds) {
      for (var i = 0; i < agentIds.length; i++) command.push(agentIds[i])
    }
    return command
  }

  function runUpdate(kind, agentIds) {
    if (updateProcess.running) {
      // Collapse queued requests to one full rerun; a forced refresh outranks
      // the cheaper kinds it might have been queued behind.
      if (kind === "force" || root.pendingUpdateKind === "") root.pendingUpdateKind = kind
      return
    }
    updateProcess.command = updateCommand(kind, agentIds)
    updateProcess.running = true
  }

  function refresh() { refreshAll(true) }
  function refreshAll(force) { runUpdate(force === true ? "force" : "normal") }

  // Opening the panel wants the numbers that go stale on the wire, not
  // another walk over every transcript on disk — the collectors reuse their
  // recent scans in this mode.
  function refreshLimits() { runUpdate("limits") }

  // ------------------------------------------------------------- providers

  // An agent earns a place in the bar and the panel by being switched on in
  // settings and having actually produced numbers — locally or on a synced
  // device. With nothing to show, the whole module collapses out of the bar
  // rather than sitting there dimmed.
  property var enabledProviders: {
    var rev = dataRevision
    var result = []
    var localIds = {}
    for (var i = 0; i < agents.length; i++) {
      var record = agents[i] ? agents[i].record : null
      if (!record || !record.id) continue
      var id = String(record.id)
      localIds[id] = true
      if (!providerEnabled(id)) continue
      var display = displayProvider(record)
      if (providerHasData(display)) result.push(display)
    }
    // An agent that only ever ran on another machine has no local record, but
    // its synced numbers still deserve a tab. Rate limits stay blank — they
    // are per-account and never travel.
    var syncedProviders = syncConfigured() && aggregateData && aggregateData.providers ? aggregateData.providers : {}
    for (var syncedId in syncedProviders) {
      if (localIds[syncedId] || !providerEnabled(syncedId)) continue
      var stats = syncedProviders[syncedId] || {}
      var syncedDisplay = displayProvider({ id: syncedId, name: stats.providerName || syncedId })
      if (providerHasData(syncedDisplay)) result.push(syncedDisplay)
    }
    return orderedProviders(result)
  }

  // The panel gives a section to any agent that has a subscription or tokens/activity/current task.
  readonly property var subscribedProviders: enabledProviders.filter(providerHasSubscription)

  function providerHasSubscription(p) {
    return (p.limits && p.limits.length > 0) || (p.accounts && p.accounts.length > 0)
      || !!p.balance || p.tierLabel !== ""
      || numberValue(p.todayTotalTokens) > 0 || numberValue(p.totalTokens) > 0
      || (p.currentTask && p.currentTask.task !== "")
  }

  // ----------------------------------------------------------------- order
  //
  // The panel's agents in the order someone dragged them into, kept beside the
  // usage records. An agent the order doesn't name yet keeps its place after
  // the ones it does.
  readonly property string orderPath: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/omarchy/agents/order.json"
  property var providerOrder: []

  function orderedProviders(list) {
    var order = providerOrder
    var rank = function(p) {
      var i = order.indexOf(p.providerId)
      return i < 0 ? order.length : i
    }
    return list.slice().sort(function(a, b) { return rank(a) - rank(b) })
  }

  // Moves one agent to a position among the ones shown, and saves the result.
  function moveProvider(id, to) {
    var ids = subscribedProviders.map(function(p) { return p.providerId })
    var from = ids.indexOf(id)
    if (from < 0) return
    to = Math.max(0, Math.min(ids.length - 1, to))
    if (from === to) return
    ids.splice(to, 0, ids.splice(from, 1)[0])
    for (var i = 0; i < providerOrder.length; i++)
      if (ids.indexOf(providerOrder[i]) < 0) ids.push(providerOrder[i])
    providerOrder = ids
    orderFile.setText(JSON.stringify(ids) + "\n")
  }

  FileView {
    id: orderFile
    path: root.orderPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      var parsed = []
      try { parsed = JSON.parse(text()) } catch (e) { parsed = [] }
      if (Array.isArray(parsed)) providerOrder = parsed
    }
  }

  function providerEnabled(id) {
    var map = settings && settings.providers ? settings.providers : {}
    return !map[id] || map[id].enabled !== false
  }

  function numberValue(val) {
    var n = Number(val)
    return isFinite(n) ? n : 0
  }

  function providerHasData(p) {
    return numberValue(p.totalPrompts) > 0 || numberValue(p.totalSessions) > 0
      || numberValue(p.activeDays) > 0 || numberValue(p.todayPrompts) > 0
      || numberValue(p.todaySessions) > 0 || numberValue(p.todayTotalTokens) > 0
      || numberValue(p.totalTokens) > 0 || (p.limits && p.limits.length > 0)
      || (p.accounts && p.accounts.length > 0) || !!p.balance
      || (p.ready === true && p.tierLabel !== "")
      || (p.currentTask && p.currentTask.task !== "")
  }

  // A prepaid agent's credit ledger. Like rate limits, the balance is
  // per-account and never merged across devices.
  function balanceValue(raw) {
    if (!raw || typeof raw !== "object") return null
    var remaining = Number(raw.remaining)
    var funded = Number(raw.funded)
    if (!isFinite(remaining) || remaining < 0) return null
    return {
      remaining: remaining,
      funded: isFinite(funded) && funded > 0 ? funded : 0,
      spent: Math.max(0, Number(raw.spent) || 0),
      currency: String(raw.currency || "USD"),
      estimated: raw.estimated === true
    }
  }

  function displayProvider(record) {
    var stats = syncedStatsFor(String(record.id))
    var synced = !!stats
    var deviceCount = synced ? Number(stats.deviceCount || aggregateData.deviceCount || 0) : 0

    var pid = String(record.id)
    var mUsage = synced ? (stats.modelUsage || ({})) : (record.modelUsage || ({}))
    var sumModelTokens = 0
    for (var m in mUsage) {
      var b = mUsage[m] || {}
      sumModelTokens += Number(b.inputTokens || 0) + Number(b.outputTokens || 0)
        + Number(b.cacheReadInputTokens || 0) + Number(b.cacheCreationInputTokens || 0)
    }
    var todayTokensVal = synced ? numberValue(stats.todayTotalTokens) : numberValue(record.todayTotalTokens)
    var totalTokensVal = Math.max(todayTokensVal, sumModelTokens)

    var taskInfo = root.tasksData && root.tasksData[pid] ? root.tasksData[pid] : null

    return {
      providerId: pid,
      providerName: String(record.name || record.id),
      ready: record.ready === true || synced,
      usageStatusText: String(record.usageStatusText || ""),
      authHelpText: String(record.authHelpText || ""),

      // Rate limits and balances stay per-account and are never merged
      // across devices.
      limits: Array.isArray(record.limits) ? record.limits : [],
      limitsStale: record.limitsStale === true,
      limitsFetchedAt: numberValue(record.limitsFetchedAt),
      tierLabel: String(record.tierLabel || ""),
      // Every subscription account's own limits, once there's more than one.
      accounts: Array.isArray(record.accounts) ? record.accounts : [],
      accountSwitch: record.accountSwitch || ({ mode: "manual", threshold: 95 }),
      // Codex's free full resets of its rate limits, when it has any.
      resetCredits: record.resetCredits || null,
      balance: balanceValue(record.balance),

      todayPrompts: synced ? numberValue(stats.todayPrompts) : numberValue(record.todayPrompts),
      todaySessions: synced ? numberValue(stats.todaySessions) : numberValue(record.todaySessions),
      todayTotalTokens: todayTokensVal,
      totalTokens: totalTokensVal,
      currentTask: taskInfo,
      todayTokensByModel: synced ? (stats.todayTokensByModel || ({})) : (record.todayTokensByModel || ({})),
      recentDays: synced ? (stats.recentDays || []) : (record.recentDays || []),
      totalPrompts: synced ? numberValue(stats.totalPrompts) : numberValue(record.totalPrompts),
      totalSessions: synced ? numberValue(stats.totalSessions) : numberValue(record.totalSessions),
      activeDays: synced ? numberValue(stats.activeDays) : numberValue(record.activeDays),
      modelUsage: mUsage,
      hasLocalStats: synced ? (stats.hasLocalStats !== false) : (record.hasLocalStats !== false),
      hasPromptStats: synced ? (stats.hasPromptStats !== false) : (record.hasPromptStats !== false),

      syncEnabled: synced,
      syncDeviceCount: deviceCount,
      syncUpdatedAt: aggregateData && aggregateData.updatedAt ? aggregateData.updatedAt : ""
    }
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // ------------------------------------------------------------------ sync

  property var syncModeSetting: setting("syncMode", setting("syncEnabled", false))
  property bool syncEnabled: parseSyncEnabled(syncModeSetting)
  property string syncDir: String(setting("syncDir", ""))
  property string syncFileName: String(setting("syncFileName", ""))
  property string syncDeviceId: String(setting("syncDeviceId", ""))
  property string detectedHostname: ""
  readonly property string syncEffectiveDir: expandPath(syncDir)

  function parseSyncEnabled(val) {
    if (typeof val === "boolean") return val
    var s = String(val || "").trim().toLowerCase()
    return s === "on" || s === "true" || s === "yes" || s === "1"
  }

  function syncConfigured() {
    return syncEnabled && syncEffectiveDir !== ""
  }

  Process {
    id: hostnameProcess
    running: false
    command: ["hostname"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var host = text.trim()
        if (host !== "") root.detectedHostname = host
      }
    }
  }

  Component.onCompleted: {
    hostnameProcess.running = true
    rescanAgents()
  }

  readonly property string syncEffectiveDeviceId: {
    var id = syncDeviceId.trim()
    if (id !== "") return id
    return detectedHostname !== "" ? detectedHostname : "device"
  }

  readonly property string syncEffectiveFileName: {
    var name = syncFileName.trim()
    if (name !== "") return name.slice(-5) === ".json" ? name : name + ".json"
    return (detectedHostname !== "" ? detectedHostname : "device") + ".json"
  }

  readonly property string syncSnapshotPath: syncConfigured() ? syncEffectiveDir + "/" + syncEffectiveFileName : home + "/.cache/omarchy/agents-disabled.json"

  // What this machine writes for other machines to read: only the fields
  // that can be merged across devices.
  function localUsageSnapshot() {
    var providers = {}
    for (var i = 0; i < agents.length; i++) {
      var record = agents[i] ? agents[i].record : null
      if (!record || !record.id) continue
      var id = String(record.id)
      providers[id] = {
        providerName: String(record.name || id),
        ready: record.ready === true,
        hasLocalStats: record.hasLocalStats !== false,
        hasPromptStats: record.hasPromptStats !== false,
        scope: String(record.scope || "device"),
        todayPrompts: numberValue(record.todayPrompts),
        todaySessions: numberValue(record.todaySessions),
        todayTotalTokens: numberValue(record.todayTotalTokens),
        todayTokensByModel: cloneValue(record.todayTokensByModel, ({})),
        recentDays: cloneValue(record.recentDays, []),
        totalPrompts: numberValue(record.totalPrompts),
        totalSessions: numberValue(record.totalSessions),
        activeDays: numberValue(record.activeDays),
        activeDates: Array.isArray(record.activeDates) ? record.activeDates.slice() : [],
        modelUsage: cloneValue(record.modelUsage, ({}))
      }
    }
    return {
      schemaVersion: 1,
      deviceId: syncEffectiveDeviceId,
      hostname: detectedHostname,
      updatedAt: (new Date()).toISOString(),
      providers: providers
    }
  }

  function cloneValue(val, fallback) {
    if (!val || typeof val !== "object") return fallback
    try { return JSON.parse(JSON.stringify(val)) } catch (e) { return fallback }
  }

  function expandPath(path) {
    var s = String(path || "").trim()
    if (s === "" || !home) return ""
    if (s === "~") return home
    if (s.slice(0, 2) === "~/") return home + s.slice(1)
    return s
  }

  // -------------------------------------------------------- sync listening

  property var snapshotFiles: []
  property var aggregateData: null

  Process {
    id: syncListProcess
    running: false
    command: ["find", root.syncEffectiveDir, "-maxdepth", "1", "-name", "*.json", "-printf", "%f\n"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySyncListing(text)
    }
  }

  Timer {
    id: syncScanTimer
    interval: 60000
    repeat: true
    running: root.syncConfigured()
    triggeredOnStart: true
    onTriggered: root.rescanSyncSnapshots()
  }

  function rescanSyncSnapshots() {
    if (!syncConfigured() || syncListProcess.running) return
    syncListProcess.running = true
  }

  function applySyncListing(output) {
    var files = []
    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var name = lines[i].trim()
      if (name.slice(-5) === ".json") files.push(name)
    }
    files.sort()
    if (JSON.stringify(files) !== JSON.stringify(snapshotFiles)) snapshotFiles = files
  }

  Instantiator {
    id: syncInstantiator
    model: root.syncConfigured() ? root.snapshotFiles : []

    delegate: Item {
      id: snapshotItem
      required property var modelData
      property var data: null

      FileView {
        path: root.syncEffectiveDir + "/" + snapshotItem.modelData
        watchChanges: true
        printErrors: false
        onLoaded: snapshotItem.parse(text())
        onLoadFailed: snapshotItem.clear()
      }

      function clear() {
        data = null
        root.rebuildSyncAggregate()
      }

      function parse(content) {
        try {
          var parsed = JSON.parse(String(content || ""))
          data = parsed && typeof parsed === "object" ? parsed : null
        } catch (e) {
          data = null
        }
        root.rebuildSyncAggregate()
      }
    }

    onObjectAdded: (index, object) => root.rebuildSyncAggregate()
    onObjectRemoved: (index, object) => root.rebuildSyncAggregate()
  }

  // --------------------------------------------------------- sync snapshot

  FileView {
    id: localSnapshotFile
    path: root.syncSnapshotPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  Timer {
    id: syncWriteDebounce
    interval: 2500
    repeat: false
    onTriggered: root.writeLocalSnapshotNow()
  }

  function scheduleSync() {
    if (!syncConfigured()) return
    syncWriteDebounce.restart()
  }

  function writeLocalSnapshotNow() {
    if (!syncConfigured()) return
    var payload = JSON.stringify(localUsageSnapshot(), null, 2) + "\n"
    localSnapshotFile.setText(payload)
  }

  // -------------------------------------------------------- sync aggregate

  function rebuildSyncAggregate() {
    if (!syncConfigured()) {
      aggregateData = null
      recordsChanged()
      return
    }

    var snapshots = []
    var deviceIds = {}
    for (var i = 0; i < syncInstantiator.count; i++) {
      var item = syncInstantiator.objectAt(i)
      var snap = item ? item.data : null
      if (snap && snap.providers && typeof snap.providers === "object") {
        snapshots.push(snap)
        var dev = String(snap.deviceId || snap.hostname || ("device-" + i))
        deviceIds[dev] = true
      }
    }

    if (snapshots.length === 0) {
      aggregateData = null
      recordsChanged()
      return
    }

    var providerIds = {}
    for (var s = 0; s < snapshots.length; s++) {
      for (var pid in snapshots[s].providers) providerIds[pid] = true
    }

    var aggregatedProviders = {}
    for (var id in providerIds) {
      var acc = {
        providerName: "",
        ready: false,
        hasLocalStats: false,
        hasPromptStats: false,
        todayPrompts: 0,
        todaySessions: 0,
        todayTotalTokens: 0,
        todayTokensByModel: ({}),
        recentByDay: ({}),
        totalPrompts: 0,
        totalSessions: 0,
        activeDays: 0,
        activeDates: ({}),
        modelUsage: ({}),
        devices: ({})
      }

      for (var j = 0; j < snapshots.length; j++) {
        var stats = snapshots[j].providers[id]
        if (!stats) continue

        var devId = String(snapshots[j].deviceId || snapshots[j].hostname || ("device-" + j))
        acc.devices[devId] = true

        if (!acc.providerName && stats.providerName) acc.providerName = String(stats.providerName)
        acc.hasLocalStats = acc.hasLocalStats || stats.hasLocalStats !== false
        acc.hasPromptStats = acc.hasPromptStats || stats.hasPromptStats !== false
        var additive = String(stats.scope || "device") !== "account"
        acc.todayPrompts = combineNumber(additive, acc.todayPrompts, stats.todayPrompts)
        acc.todaySessions = combineNumber(additive, acc.todaySessions, stats.todaySessions)
        acc.todayTotalTokens = combineNumber(additive, acc.todayTotalTokens, stats.todayTotalTokens)
        acc.totalPrompts = combineNumber(additive, acc.totalPrompts, stats.totalPrompts)
        acc.totalSessions = combineNumber(additive, acc.totalSessions, stats.totalSessions)

        var dates = Array.isArray(stats.activeDates) ? stats.activeDates : []
        for (var k = 0; k < dates.length; k++) acc.activeDates[dates[k]] = true
        acc.activeDays = Math.max(acc.activeDays, numberValue(stats.activeDays))

        mergeTokenMap(additive, acc.todayTokensByModel, stats.todayTokensByModel)
        mergeRecentDays(additive, acc.recentByDay, stats.recentDays)
        mergeModelUsage(additive, acc.modelUsage, stats.modelUsage)
      }

      var recentDays = []
      var sortedDays = Object.keys(acc.recentByDay).sort()
      for (var d = 0; d < sortedDays.length; d++)
        recentDays.push({ date: sortedDays[d], messageCount: acc.recentByDay[sortedDays[d]] })

      var providerDevices = Object.keys(acc.devices)
      aggregatedProviders[id] = {
        providerName: acc.providerName || id,
        ready: acc.ready || providerDevices.length > 0,
        hasLocalStats: acc.hasLocalStats,
        hasPromptStats: acc.hasPromptStats,
        todayPrompts: acc.todayPrompts,
        todaySessions: acc.todaySessions,
        todayTotalTokens: acc.todayTotalTokens,
        todayTokensByModel: acc.todayTokensByModel,
        recentDays: recentDays,
        totalPrompts: acc.totalPrompts,
        totalSessions: acc.totalSessions,
        activeDays: Math.max(acc.activeDays, Object.keys(acc.activeDates).length),
        modelUsage: acc.modelUsage,
        deviceCount: providerDevices.length
      }
    }

    aggregateData = {
      updatedAt: (new Date()).toISOString(),
      deviceCount: Object.keys(deviceIds).length,
      providers: aggregatedProviders
    }
    recordsChanged()
  }

  function combineNumber(additive, current, candidate) {
    var val = numberValue(candidate)
    return additive ? (current + val) : Math.max(current, val)
  }

  function mergeTokenMap(additive, target, source) {
    if (!source || typeof source !== "object") return
    for (var k in source) {
      var val = numberValue(source[k])
      target[k] = additive ? ((target[k] || 0) + val) : Math.max(target[k] || 0, val)
    }
  }

  function mergeRecentDays(additive, byDay, days) {
    if (!Array.isArray(days)) return
    for (var i = 0; i < days.length; i++) {
      var entry = days[i]
      if (!entry || !entry.date) continue
      var count = numberValue(entry.messageCount)
      byDay[entry.date] = additive ? ((byDay[entry.date] || 0) + count) : Math.max(byDay[entry.date] || 0, count)
    }
  }

  function mergeModelUsage(additive, target, source) {
    if (!source || typeof source !== "object") return
    for (var model in source) {
      var src = source[model] || {}
      var dst = target[model] || (target[model] = {
        inputTokens: 0,
        outputTokens: 0,
        cacheReadInputTokens: 0,
        cacheCreationInputTokens: 0
      })
      dst.inputTokens = combineNumber(additive, dst.inputTokens, src.inputTokens)
      dst.outputTokens = combineNumber(additive, dst.outputTokens, src.outputTokens)
      dst.cacheReadInputTokens = combineNumber(additive, dst.cacheReadInputTokens, src.cacheReadInputTokens)
      dst.cacheCreationInputTokens = combineNumber(additive, dst.cacheCreationInputTokens, src.cacheCreationInputTokens)
    }
  }

  function syncedStatsFor(providerId) {
    if (!syncConfigured() || !aggregateData || !aggregateData.providers) return null
    return aggregateData.providers[providerId] || null
  }

  // ---------------------------------------------------------------- format

  function formatTokenCount(n) {
    if (n === undefined || n === null) return I18n.formatNumber(0)
    if (n >= 1e9) return I18n.formatNumber(n / 1e9, 1) + "B"
    if (n >= 1e6) return I18n.formatNumber(n / 1e6, 1) + "M"
    if (n >= 1e3) return I18n.formatNumber(n / 1e3, 1) + "K"
    return I18n.formatNumber(n)
  }

  function friendlyModelName(raw) {
    var s = String(raw || "").trim()
    var known = {
      "claude-opus-4-7": "Claude Opus 4.7",
      "claude-sonnet-4-6": "Claude Sonnet 4.6",
      "claude-haiku-4-5": "Claude Haiku 4.5",
      "gpt-5": "GPT-5",
      "gpt-5-mini": "GPT-5 mini",
      "codex-auto-review": "Codex Review",
      "gemini-2.5-pro": "Gemini 2.5 Pro",
      "gemini-2.5-flash": "Gemini 2.5 Flash",
      "deepseek-chat": "DeepSeek Chat",
      "deepseek-reasoner": "DeepSeek Reasoner"
    }
    if (known[s]) return known[s]
    return s.replace(/[-_]/g, " ").replace(/\b\w/g, function(c) { return c.toUpperCase() })
  }
}
