import QtQuick
import QtTest
import "../WindowModel.js" as WindowModel

TestCase {
  name: "WindowModel"

  function test_gridNavigation() {
    compare(WindowModel.nextGridIndex(0, "down", 5, 2, true), 2)
    compare(WindowModel.nextGridIndex(2, "down", 5, 2, true), 4)
    compare(WindowModel.nextGridIndex(4, "down", 5, 2, true), 4)
    compare(WindowModel.nextGridIndex(3, "down", 5, 2, true), 4)
    compare(WindowModel.nextGridIndex(0, "up", 5, 2, true), 4)
    compare(WindowModel.nextGridIndex(1, "up", 5, 2, true), 3)
    compare(WindowModel.nextGridIndex(4, "right", 5, 2, true), 0)
    compare(WindowModel.nextGridIndex(0, "left", 5, 2, true), 4)
  }

  function test_noWrapNavigation() {
    compare(WindowModel.nextGridIndex(4, "right", 5, 2, false), 4)
    compare(WindowModel.nextGridIndex(0, "left", 5, 2, false), 0)
    compare(WindowModel.nextGridIndex(0, "up", 5, 2, false), 0)
    compare(WindowModel.nextGridIndex(3, "down", 5, 2, false), 4)
  }

  function test_configNormalization() {
    var config = WindowModel.normalizedConfig({
      maxItemsPerRow: 7,
      filterBy: ["currentMonitor", "same-class"],
      killKey: "x"
    }, {
      direction: "backward",
      commitOnModifierRelease: true
    })

    compare(config.itemsPerRow, 7)
    compare(config.filterBy[0], "current_monitor")
    compare(config.filterBy[1], "same_class")
    compare(config.killKey, "x")
    compare(config.direction, "previous")
    verify(config.commitOnModifierRelease)
    compare(config.excludeWorkspaces.length, 1)
    compare(config.excludeWorkspaces[0], "special:.*")

    var defaults = WindowModel.normalizedConfig({}, {})
    verify(defaults.commitOnModifierRelease)
    compare(defaults.switchMode, "clients")
    compare(defaults.showWorkspace, false)
    compare(defaults.dimBackdrop, false)
    compare(defaults.itemsPerRow, 4)
    compare(defaults.maxVisibleRows, 3)
    compare(defaults.filterBy.length, 0)

    compare(WindowModel.normalizedConfig({ switchMode: "workspace" }, {}).switchMode, "workspaces")
    compare(WindowModel.normalizedConfig({}, {}).switchMode, "clients")
    compare(WindowModel.normalizedConfig({ excludeWorkspaces: ["scratchpad"] }, {}).excludeWorkspaces[0], "scratchpad")

    compare(WindowModel.normalizedConfig({}, {}).dimBackdrop, false)
    compare(WindowModel.normalizedConfig({ dimBackdrop: true }, {}).dimBackdrop, true)
    compare(WindowModel.normalizedConfig({}, {}).showWorkspace, false)
    compare(WindowModel.normalizedConfig({ showWorkspace: false }, {}).showWorkspace, false)
    compare(WindowModel.normalizedConfig({ showWorkspaceNumbers: false }, {}).showWorkspace, false)
  }

  function test_terminalCommandParsing() {
    compare(WindowModel.terminalCommandFromExec("xdg-terminal-exec --app-id=TUI.tile -e lazydocker"), "lazydocker")
    compare(WindowModel.terminalCommandFromExec("omarchy-launch-webapp https://example.com"), "")
    compare(WindowModel.terminalCommandFromExec("xdg-terminal-exec -e /usr/bin/lazysql"), "lazysql")
    compare(WindowModel.terminalCommandFromCmdline("foot\x00--app-id=TUI.tile\x00-e\x00k9s\x00"), "k9s")
    compare(WindowModel.terminalCommandFromCmdline("foot\x00--app-id=TUI.tile\x00"), "")
  }

  function test_workspaceLayout() {
    var clients = [
      { address: "0x1", mapped: true, workspace: { id: 1 }, at: [100, 100], size: [900, 500], class: "firefox", title: "Mozilla Firefox", pid: 10 },
      { address: "0x2", mapped: true, workspace: { id: 1 }, at: [1000, 100], size: [900, 500], class: "foot", pid: 20 },
      { address: "0x3", mapped: true, workspace: { id: 2 }, at: [0, 0], size: [100, 100], class: "x", pid: 30 },
      { address: "0x4", mapped: false, workspace: { id: 1 }, at: [0, 0], size: [100, 100], class: "y", pid: 40 }
    ]
    var monitors = [{ id: 7, x: 100, y: 100, width: 1800, height: 1000 }]

    var layout = WindowModel.workspaceLayout(clients, monitors, 1, 7)
    compare(layout.length, 2)
    compare(layout[0].x, 0)
    compare(layout[0].y, 0)
    compare(layout[0].w, 0.5)
    compare(layout[0].h, 0.5)
    compare(layout[0].appClass, "firefox")
    compare(layout[0].title, "Mozilla Firefox")
    compare(layout[0].pid, 10)
    compare(layout[1].x, 0.5)
    compare(layout[1].y, 0)
    compare(layout[1].appClass, "foot")
    compare(layout[1].pid, 20)

    compare(WindowModel.workspaceLayout(clients, [], 1, 7).length, 0)
  }

  function test_workspaceFilterAndOrdering() {
    var workspaces = [
      { id: 4, name: "4", monitorID: 1, windows: 2 },
      { id: 2, name: "2", monitorID: 1, windows: 1 },
      { id: 3, name: "3", monitorID: 2, windows: 1 },
      { id: -98, name: "special:scratchpad", monitorID: 1, windows: 1 },
      { id: 5, name: "5", monitorID: 1, windows: 0 },
      { id: 1, name: "1", monitorID: 1, windows: 1 }
    ]
    var clients = [
      { address: "0x1", mapped: true, workspace: { id: 2 }, focusHistoryID: 0 },
      { address: "0x2", mapped: true, workspace: { id: 4 }, focusHistoryID: 1 },
      { address: "0x3", mapped: true, workspace: { id: 1 }, focusHistoryID: 2 },
      { address: "0x4", mapped: true, workspace: { id: 3 }, focusHistoryID: 3 }
    ]

    var currentMonitor = WindowModel.normalizedConfig({
      switchMode: "workspaces",
      filterBy: ["current_monitor"]
    }, {})
    var filtered = WindowModel.filteredWorkspaces(workspaces, currentMonitor, 2, clients)
    compare(filtered.length, 3)
    compare(filtered[0].id, 2)
    compare(filtered[1].id, 4)
    compare(filtered[2].id, 1)

    // After focusing a client on workspace 4, workspace 4 becomes most recent.
    var refocused = clients.map(function(client) {
      var copy = {}
      for (var key in client) copy[key] = client[key]
      if (copy.workspace.id === 4) copy.focusHistoryID = 0
      else if (copy.workspace.id === 2) copy.focusHistoryID = 1
      else copy.focusHistoryID = copy.focusHistoryID + 1
      return copy
    })
    var reordered = WindowModel.filteredWorkspaces(workspaces, currentMonitor, 4, refocused)
    compare(reordered[0].id, 4)
    compare(reordered[1].id, 2)
    compare(reordered[2].id, 1)

    var all = WindowModel.filteredWorkspaces(
      workspaces,
      WindowModel.normalizedConfig({ switchMode: "workspaces", filterBy: [] }, {}),
      2,
      clients)
    compare(all.length, 4)
    compare(all[0].id, 2)
    compare(all[1].id, 4)
    compare(all[2].id, 1)
    compare(all[3].id, 3)
  }

  function test_excludedWorkspaces() {
    var config = WindowModel.normalizedConfig({
      excludeWorkspaces: ["special:.*", "scratchpad"]
    }, {})
    var clients = [
      { address: "0x1", mapped: true, workspace: { id: 1, name: "1" }, focusHistoryID: 0 },
      { address: "0x2", mapped: true, workspace: { id: -98, name: "special:scratchpad" }, focusHistoryID: 1 },
      { address: "0x3", mapped: true, workspace: { id: 9, name: "scratchpad" }, focusHistoryID: 2 }
    ]

    var filteredClients = WindowModel.filteredClients(clients, config)
    compare(filteredClients.length, 1)
    compare(filteredClients[0].address, "0x1")

    var workspaces = [
      { id: 1, name: "1", monitorID: 1, windows: 1 },
      { id: -98, name: "special:scratchpad", monitorID: 1, windows: 1 },
      { id: 9, name: "scratchpad", monitorID: 1, windows: 1 }
    ]
    var filteredWorkspaces = WindowModel.filteredWorkspaces(workspaces, config, 1, clients)
    compare(filteredWorkspaces.length, 1)
    compare(filteredWorkspaces[0].id, 1)
  }

  function test_emptyWorkspacesExcluded() {
    var workspaces = [
      { id: 1, name: "1", monitorID: 1, windows: 1 },
      { id: 2, name: "2", monitorID: 1, windows: 0 },
      { id: 3, name: "3", monitorID: 1, windows: 0 }
    ]
    var config = WindowModel.normalizedConfig({ switchMode: "workspaces", filterBy: [] }, {})

    var occupied = [
      { address: "0x1", mapped: true, workspace: { id: 1 }, focusHistoryID: 0 }
    ]
    var filtered = WindowModel.filteredWorkspaces(workspaces, config, 1, occupied)
    compare(filtered.length, 1)
    compare(filtered[0].id, 1)

    // A workspace whose only client is unmapped counts as empty.
    var onlyUnmapped = [
      { address: "0x2", mapped: false, workspace: { id: 1 }, focusHistoryID: 0 }
    ]
    compare(WindowModel.filteredWorkspaces(workspaces, config, 1, onlyUnmapped).length, 0)

    // No clients at all: nothing to show.
    compare(WindowModel.filteredWorkspaces(workspaces, config, 1, []).length, 0)
  }

  function test_filterAndMruSort() {
    var clients = [
      { address: "0x3", mapped: true, monitor: 1, class: "B", workspace: { id: 2 }, focusHistoryID: 2 },
      { address: "0x1", mapped: true, monitor: 1, class: "A", workspace: { id: 1 }, focusHistoryID: 0 },
      { address: "0x2", mapped: true, monitor: 1, class: "B", workspace: { id: 1 }, focusHistoryID: 1 },
      { address: "0x4", mapped: true, monitor: 2, class: "A", workspace: { id: 1 }, focusHistoryID: 3 }
    ]

    var monitorConfig = WindowModel.normalizedConfig({ filterBy: ["current_monitor"] }, {})
    var monitorResult = WindowModel.filteredClients(clients, monitorConfig)
    compare(monitorResult.length, 3)
    compare(monitorResult[0].address, "0x1")
    compare(monitorResult[1].address, "0x2")
    compare(monitorResult[2].address, "0x3")

    var workspaceConfig = WindowModel.normalizedConfig({ filterBy: ["current_workspace"] }, {})
    var workspaceResult = WindowModel.filteredClients(clients, workspaceConfig)
    compare(workspaceResult.length, 3)
    compare(workspaceResult[2].address, "0x4")

    var classConfig = WindowModel.normalizedConfig({ filterBy: ["same_class"] }, {})
    var classResult = WindowModel.filteredClients(clients, classConfig)
    compare(classResult.length, 2)
    compare(classResult[1].address, "0x4")
  }
}
