function clampInteger(value, fallback, minimum, maximum) {
  var parsed = Math.floor(Number(value))
  if (!isFinite(parsed)) parsed = fallback
  return Math.max(minimum, Math.min(maximum, parsed))
}

function normalizeFilterName(value) {
  return String(value || "")
    .replace(/-/g, "_")
    .replace(/([a-z])([A-Z])/g, "$1_$2")
    .toLowerCase()
}

function normalizedConfig(entry, payload) {
  var stored = entry && typeof entry === "object" ? entry : {}
  var request = payload && typeof payload === "object" ? payload : {}

  function pick(key, alias, fallback) {
    if (request[key] !== undefined) return request[key]
    if (alias && request[alias] !== undefined) return request[alias]
    if (stored[key] !== undefined) return stored[key]
    if (alias && stored[alias] !== undefined) return stored[alias]
    return fallback
  }

  var filters = pick("filterBy", "filter_by", [])
  if (!Array.isArray(filters)) filters = [filters]
  filters = filters.map(normalizeFilterName)

  var killKey = String(pick("killKey", "kill_key", "q") || "q")

  var direction = String(pick("direction", "initialDirection", "next") || "next").toLowerCase()
  if (["previous", "prev", "backward", "left"].indexOf(direction) !== -1)
    direction = "previous"
  else
    direction = "next"

  var switchMode = String(pick("switchMode", "switch_mode", "clients") || "clients").toLowerCase()
  switchMode = switchMode === "workspace" || switchMode === "workspaces" ? "workspaces" : "clients"

  return {
    switchMode: switchMode,
    itemsPerRow: clampInteger(pick("itemsPerRow", "maxItemsPerRow", 4), 4, 1, 12),
    maxVisibleRows: clampInteger(pick("maxVisibleRows", "maxRows", 3), 3, 1, 10),
    filterBy: filters,
    killKey: killKey.charAt(0).toLowerCase(),
    direction: direction,
    commitOnModifierRelease: pick("commitOnModifierRelease", "activateOnModifierRelease", true) === true,
    showWorkspace: pick("showWorkspace", "showWorkspaceNumbers", false) !== false,
    dimBackdrop: pick("dimBackdrop", "dim_backdrop", false) === true,
    wrapNavigation: pick("wrapNavigation", "wrap", true) !== false
  }
}

function hasFilter(config, name) {
  var filters = config && Array.isArray(config.filterBy) ? config.filterBy : []
  return filters.indexOf(normalizeFilterName(name)) !== -1
}

function focusRank(client) {
  var rank = Number(client && client.focusHistoryID)
  return isFinite(rank) && rank >= 0 ? rank : 2147483647
}

function filteredClients(snapshot, config) {
  var source = Array.isArray(snapshot) ? snapshot : []
  var active = null

  for (var i = 0; i < source.length; i++) {
    if (focusRank(source[i]) === 0) {
      active = source[i]
      break
    }
  }

  var out = []
  for (var j = 0; j < source.length; j++) {
    var client = source[j]
    if (!client || client.mapped === false) continue

    var address = String(client.address || "")
    if (!/^0x[0-9a-f]+$/i.test(address)) continue

    if (active && hasFilter(config, "current_monitor") && Number(client.monitor) !== Number(active.monitor))
      continue
    if (active && hasFilter(config, "current_workspace")) {
      var workspaceId = client.workspace ? Number(client.workspace.id) : NaN
      var activeWorkspaceId = active.workspace ? Number(active.workspace.id) : NaN
      if (workspaceId !== activeWorkspaceId) continue
    }
    if (active && hasFilter(config, "same_class")
        && String(client.class || "").toLowerCase() !== String(active.class || "").toLowerCase())
      continue

    out.push(client)
  }

  out.sort(function(left, right) {
    var rankDifference = focusRank(left) - focusRank(right)
    if (rankDifference !== 0) return rankDifference
    return String(left.address || "").localeCompare(String(right.address || ""))
  })
  return out
}

function filteredWorkspaces(snapshot, config, activeWorkspaceId, clients) {
  var source = Array.isArray(snapshot) ? snapshot : []
  var clientSource = Array.isArray(clients) ? clients : []
  var activeId = Number(activeWorkspaceId)
  var activeMonitorId = NaN

  for (var i = 0; i < source.length; i++) {
    if (Number(source[i] && source[i].id) === activeId) {
      activeMonitorId = Number(source[i].monitorID)
      break
    }
  }

  // Most-recent-focus rank per workspace: the smallest focusHistoryID among
  // its clients. Lower is more recent, matching client MRU ordering.
  // Workspaces with no mapped clients get no rank and are excluded.
  var recencyById = {}
  for (var c = 0; c < clientSource.length; c++) {
    var client = clientSource[c]
    if (!client || client.mapped === false) continue
    var clientWorkspace = client.workspace || {}
    var clientWorkspaceId = Number(clientWorkspace.id)
    if (!isFinite(clientWorkspaceId)) continue

    var rank = focusRank(client)
    var existing = recencyById[clientWorkspaceId]
    if (existing === undefined || rank < existing) recencyById[clientWorkspaceId] = rank
  }

  var out = []
  for (var j = 0; j < source.length; j++) {
    var workspace = source[j]
    if (!workspace) continue

    var id = Number(workspace.id)
    var name = String(workspace.name || "")
    if (!isFinite(id) || !name || name.indexOf("special:") === 0) continue
    if (hasFilter(config, "current_monitor") && isFinite(activeMonitorId)
        && Number(workspace.monitorID) !== activeMonitorId)
      continue

    // Only show workspaces that currently have at least one client.
    if (recencyById[id] === undefined) continue

    out.push(workspace)
  }

  out.sort(function(left, right) {
    var leftRank = recencyById[Number(left.id)]
    var rightRank = recencyById[Number(right.id)]

    if (leftRank !== rightRank) return leftRank - rightRank

    var idDifference = Number(left.id) - Number(right.id)
    if (idDifference !== 0) return idDifference
    return String(left.name || "").localeCompare(String(right.name || ""))
  })

  return out
}

function workspaceLayout(clients, monitors, workspaceId, monitorId) {
  var source = Array.isArray(clients) ? clients : []
  var monitorList = Array.isArray(monitors) ? monitors : []
  var targetId = Number(workspaceId)
  var monitor = null

  for (var m = 0; m < monitorList.length; m++) {
    if (Number(monitorList[m].id) === Number(monitorId)) {
      monitor = monitorList[m]
      break
    }
  }

  var width = monitor ? Number(monitor.width) : 0
  var height = monitor ? Number(monitor.height) : 0
  var monitorX = monitor ? Number(monitor.x) : 0
  var monitorY = monitor ? Number(monitor.y) : 0
  if (!isFinite(width) || width <= 0 || !isFinite(height) || height <= 0) return []

  var out = []
  for (var j = 0; j < source.length; j++) {
    var client = source[j]
    if (!client || client.mapped === false) continue

    var workspace = client.workspace || {}
    if (Number(workspace.id) !== targetId) continue

    var at = Array.isArray(client.at) ? client.at : []
    var size = Array.isArray(client.size) ? client.size : []
    if (at.length < 2 || size.length < 2) continue

    var x = (Number(at[0]) - monitorX) / width
    var y = (Number(at[1]) - monitorY) / height
    var w = Number(size[0]) / width
    var h = Number(size[1]) / height

    out.push({
      x: Math.max(0, Math.min(1, x)),
      y: Math.max(0, Math.min(1, y)),
      w: Math.max(0, Math.min(1, w)),
      h: Math.max(0, Math.min(1, h)),
      appClass: String(client.class || client.initialClass || ""),
      title: String(client.title || ""),
      pid: Number(client.pid || 0)
    })
  }

  return out
}

function terminalCommandFromArgs(args) {
  var source = Array.isArray(args) ? args : []
  for (var i = 0; i < source.length - 1; i++) {
    if (source[i] === "-e") {
      var command = String(source[i + 1] || "").replace(/"/g, "")
      var slash = command.lastIndexOf("/")
      if (slash !== -1) command = command.slice(slash + 1)
      return command.toLowerCase()
    }
  }
  return ""
}

function terminalCommandFromExec(execString) {
  return terminalCommandFromArgs(String(execString || "").split(/\s+/))
}

function terminalCommandFromCmdline(cmdline) {
  return terminalCommandFromArgs(String(cmdline || "").split("\x00"))
}

function initialIndex(count, direction) {
  if (count <= 1) return 0
  return direction === "previous" ? count - 1 : 1
}

function nextGridIndex(current, direction, count, columns, wrap) {
  if (count <= 1) return 0

  var index = Math.max(0, Math.min(count - 1, current))
  var perRow = Math.max(1, Math.floor(columns))
  var shouldWrap = wrap !== false

  if (direction === "right")
    return index + 1 >= count ? (shouldWrap ? 0 : index) : index + 1

  if (direction === "left")
    return index === 0 ? (shouldWrap ? count - 1 : index) : index - 1

  if (direction === "down") {
    var down = index + perRow
    if (down < count) return down
    return count - 1
  }

  if (direction === "up") {
    if (index >= perRow) return index - perRow
    if (!shouldWrap) return index

    // Wrap to the final populated cell in this column. In a short final row,
    // this may be the preceding row rather than a diagonal neighboring cell.
    var target = index % perRow
    while (target + perRow < count) target += perRow
    return target
  }

  return index
}
