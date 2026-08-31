import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "WindowModel.js" as WindowModel

Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property bool loading: false
  property bool chooseInitialSelection: false
  property bool earlyCommitArmed: false
  property bool modifierReleasedWhileLoading: false
  property bool sawKeyEvent: false
  property bool openedViaShortcut: false
  property bool refreshPending: false
  // These maps retain the original destination while a window/workspace is
  // parked in Switcharoo's special workspace.
  property var minimizedClients: ({})
  property var minimizedWorkspaces: ({})
  property bool minimizedStateLoaded: false
  property bool minimizedStateDirectoryReady: false
  property bool showingMinimized: false
  readonly property string minimizedStateDir: (Quickshell.env("XDG_STATE_HOME")
    || Quickshell.env("HOME") + "/.local/state")
  readonly property string minimizedStatePath: root.minimizedStateDir + "/switcharoo-minimized.json"
  property int queuedMoveDelta: 0
  property int selectedIndex: 0
  property var runtimeConfig: WindowModel.normalizedConfig({}, {})
  property int lastKnownCardWidth: 0
  property string errorMessage: ""

  readonly property int windowCount: windowModel.count
  readonly property int minimumCellWidth: Style.space(190)
  readonly property int cellWidth: Style.space(210)
  readonly property int cellHeight: Style.space(142)
  readonly property int contentPadding: Style.spacing.panelPadding
  readonly property int surfaceBorderWidth: Math.max(1, Style.normalBorderWidth)
  readonly property int headerHeight: Math.max(Style.space(34), Style.font.caption + Style.spacing.controlPaddingY * 2)
  readonly property int footerHeight: Math.max(Style.space(34), Style.font.caption + Style.spacing.controlPaddingY * 2)
  // Keep the navigation and action captions on one line without overlapping
  // when the grid contains only one or two items.
  readonly property int footerMinimumWidth: Style.space(560)
  readonly property int availableGridWidth: Math.max(root.minimumCellWidth, panel.width - Style.gapsOut * 4 - root.contentPadding * 2 - root.surfaceBorderWidth * 2)
  readonly property int widthLimitedColumns: Math.max(1, Math.floor(root.availableGridWidth / root.cellWidth))
  readonly property int columns: Math.max(1, Math.min(runtimeConfig.itemsPerRow, widthLimitedColumns, Math.max(1, windowCount)))
  readonly property int visualColumns: Math.max(1, Math.min(columns, Math.floor(Math.max(0, grid.width) / cellWidth)))
  readonly property int rows: Math.max(1, Math.ceil(windowCount / visualColumns))
  readonly property int visibleRows: Math.min(rows, runtimeConfig.maxVisibleRows)
  readonly property int gridWidth: columns * cellWidth
  readonly property int gridHeight: visibleRows * cellHeight
  readonly property int calculatedCardWidth: Math.min(panel.width - Style.gapsOut * 4, Math.max(root.footerMinimumWidth, gridWidth + contentPadding * 2 + surfaceBorderWidth * 2))
  // Keep the previous card width during the asynchronous initial snapshot so
  // clearing the model does not make the card briefly collapse and grow again.
  readonly property int cardWidth: root.loading && root.lastKnownCardWidth > 0
    ? root.lastKnownCardWidth : root.calculatedCardWidth
  readonly property int cardHeight: Math.min(panel.height - Style.gapsOut * 4, headerHeight + gridHeight + footerHeight + contentPadding * 2 + surfaceBorderWidth * 2)

  function pluginId() {
    return String((root.manifest && root.manifest.id) || "io.github.gabrielvincent.switcharoo")
  }

  function shellEntry() {
    var config = root.shell && root.shell.shellConfig ? root.shell.shellConfig : null
    var plugins = config && Array.isArray(config.plugins) ? config.plugins : []
    var id = root.pluginId()
    for (var i = 0; i < plugins.length; i++) {
      if (plugins[i] && String(plugins[i].id || "") === id) return plugins[i]
    }
    return {}
  }

  function parsePayload(payloadJson) {
    if (!payloadJson) return {}
    try {
      var parsed = JSON.parse(payloadJson)
      return parsed && typeof parsed === "object" ? parsed : {}
    } catch (error) {
      console.warn("Switcharoo: invalid summon payload:", error)
      return {}
    }
  }

  function open(payloadJson) {
    var openedViaShortcut = root.openedViaShortcut
    root.openedViaShortcut = false

    var nextConfig = WindowModel.normalizedConfig(root.shellEntry(), root.parsePayload(payloadJson))

    // Hyprland consumes every Alt+Tab as a global binding, including presses
    // made while this exclusive-focus overlay is already open. Treat repeated
    // summons as navigation instead of rebuilding the model and resetting the
    // cursor to its initial position.
    if (root.opened) {
      root.runtimeConfig = nextConfig
      var delta = nextConfig.direction === "previous" ? -1 : 1
      if (root.loading) root.queuedMoveDelta += delta
      else root.move(delta < 0 ? "left" : "right")
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      return
    }

    var commitWasArmed = root.earlyCommitArmed
    root.earlyCommitArmed = false
    earlyCommitExpiry.stop()

    root.runtimeConfig = nextConfig
    root.opened = true
    root.loading = true
    // Never expose the model from the previous invocation while the new
    // compositor snapshot is being collected.  In particular, workspace
    // previews can otherwise appear briefly in their old order and then jump
    // when applySnapshot() replaces them.
    windowModel.clear()
    root.errorMessage = ""
    root.showingMinimized = false
    root.queuedMoveDelta = 0
    root.chooseInitialSelection = true
    root.modifierReleasedWhileLoading = commitWasArmed
    root.sawKeyEvent = false
    if (root.runtimeConfig.commitOnModifierRelease && openedViaShortcut)
      modifierWatchTimer.restart()
    else
      modifierWatchTimer.stop()
    root.requestSnapshot()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    root.opened = false
    root.loading = false
    root.queuedMoveDelta = 0
    root.showingMinimized = false
    root.modifierReleasedWhileLoading = false
    root.sawKeyEvent = false
    modifierWatchTimer.stop()
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.pluginId())
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function requestSnapshot() {
    if (snapshotProcess.running) {
      root.refreshPending = true
      return
    }
    if (root.runtimeConfig.switchMode === "workspaces") {
      snapshotProcess.command = [
        "bash",
        "-c",
        "jq -n --argjson clients \"$(hyprctl -j clients)\" --argjson workspaces \"$(hyprctl -j workspaces)\" --argjson monitors \"$(hyprctl -j monitors)\" '{clients:$clients, workspaces:$workspaces, monitors:$monitors}'"
      ]
    } else {
      snapshotProcess.command = ["hyprctl", "-j", "clients"]
    }
    snapshotProcess.running = true
  }

  function terminalCommandForPid(pid) {
    var number = Number(pid)
    if (!isFinite(number) || number <= 0) return ""

    cmdlineView.path = "/proc/" + number + "/cmdline"
    var cmdline = ""
    try {
      cmdline = cmdlineView.text()
    } catch (error) {
      return ""
    }

    return WindowModel.terminalCommandFromCmdline(cmdline)
  }

  function iconFor(windowClass, pid, title) {
    var requested = String(windowClass || "")
    var clsLower = requested.toLowerCase()

    // Icon cascade from hyprland-alttab: desktop-entry id variants first, then
    // StartupWMClass, then app-name/title matching (Chrome PWAs), then themed
    // icon names, then a generic executable icon.
    var idVariants = [requested, clsLower, requested.replace(/-/g, ""), requested.split(".")[0]]
    for (var i = 0; i < idVariants.length; i++) {
      var variant = idVariants[i]
      if (!variant) continue
      var entry = DesktopEntries.byId(variant)
      if (entry && entry.icon)
        return Quickshell.iconPath(String(entry.icon), "application-x-executable")
    }

    var entries = DesktopEntries.applications.values || []

    for (var j = 0; j < entries.length; j++) {
      var startupClass = String(entries[j].startupClass || "").toLowerCase()
      if (startupClass && startupClass === clsLower && entries[j].icon)
        return Quickshell.iconPath(String(entries[j].icon), "application-x-executable")
    }

    // Omarchy starts TUI apps in a terminal with a shared app-id (TUI.tile / TUI.float).
    // The client PID belongs to the terminal, so read its cmdline and resolve the
    // command following `-e` back to a desktop entry's icon.
    if (clsLower.indexOf("tui.") === 0) {
      var terminalCommand = root.terminalCommandForPid(pid)
      if (terminalCommand) {
        for (var k = 0; k < entries.length; k++) {
          if (WindowModel.terminalCommandFromExec(String(entries[k].execString || "")) === terminalCommand
              && entries[k].icon)
            return Quickshell.iconPath(String(entries[k].icon), "application-x-executable")
        }
        var tuiIcon = Quickshell.iconPath(terminalCommand, true)
        if (tuiIcon) return tuiIcon
      }
    }

    var titleLower = String(title || "").toLowerCase()
    if (titleLower) {
      for (var m = 0; m < entries.length; m++) {
        var appName = String(entries[m].name || "").toLowerCase()
        if (appName && titleLower.indexOf(appName) !== -1 && entries[m].icon)
          return Quickshell.iconPath(String(entries[m].icon), "application-x-executable")
      }
    }

    var themeVariants = [requested, clsLower, requested.split("-")[0], requested.split(".").pop()]
    for (var n = 0; n < themeVariants.length; n++) {
      var themeVariant = themeVariants[n]
      if (!themeVariant) continue
      var themed = Quickshell.iconPath(themeVariant, true)
      if (themed) return themed
    }

    return Quickshell.iconPath("application-x-executable", true)
  }

  function selectedAddress() {
    if (root.selectedIndex < 0 || root.selectedIndex >= windowModel.count) return ""
    return String(windowModel.get(root.selectedIndex).address || "")
  }

  function selectedIdentity() {
    if (root.selectedIndex < 0 || root.selectedIndex >= windowModel.count) return ""
    return String(windowModel.get(root.selectedIndex).selectionKey || "")
  }

  function applySnapshot(rawText, exitCode) {
    pointerGate.reset()
    var previousIdentity = root.selectedIdentity()
    var entries = []
    var workspaceMode = root.runtimeConfig.switchMode === "workspaces"
    var subject = workspaceMode ? "workspaces" : "clients"

    if (exitCode !== 0) {
      root.errorMessage = "Unable to query Hyprland " + subject
    } else {
      try {
        if (workspaceMode) {
          var combined = JSON.parse(String(rawText || "{}"))
          var clientsSnapshot = combined.clients || []
          var monitorsSnapshot = combined.monitors || []
          root.reconcileMinimizedState(clientsSnapshot)
          var activeWorkspaceId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : NaN
          var workspaceList = WindowModel.filteredWorkspaces(combined.workspaces || [], root.runtimeConfig, activeWorkspaceId, clientsSnapshot).filter(function(workspace) {
            return String(workspace.name || "").indexOf("special:switcharoo_minimized_workspace_") !== 0
          })
          entries = []
          if (root.showingMinimized) {
            var remainingWorkspaces = ({})
            var workspaceKeys = Object.keys(root.minimizedWorkspaces)
            for (var mw = 0; mw < workspaceKeys.length; mw++) {
              var minimizedWorkspace = root.minimizedWorkspaces[workspaceKeys[mw]]
              var addresses = minimizedWorkspace.addresses || []
              var members = clientsSnapshot.filter(function(client) {
                return client && client.mapped !== false
                  && String((client.workspace || {}).name || "") === String(minimizedWorkspace.specialTarget || "")
                  && addresses.indexOf(String(client.address || "")) !== -1
              })
              if (members.length === 0) continue
              remainingWorkspaces[workspaceKeys[mw]] = minimizedWorkspace
              var parkedWorkspace = members[0].workspace || {}
              var rawMinimizedLayout = WindowModel.workspaceLayout(clientsSnapshot, monitorsSnapshot, parkedWorkspace.id, members[0].monitor)
              var minimizedLayout = []
              for (var ml = 0; ml < rawMinimizedLayout.length; ml++) {
                var minimizedTile = rawMinimizedLayout[ml]
                minimizedTile.icon = root.iconFor(minimizedTile.appClass, minimizedTile.pid, minimizedTile.title)
                minimizedLayout.push(minimizedTile)
              }
              entries.push({
                id: minimizedWorkspace.id,
                name: minimizedWorkspace.name,
                windows: members.length,
                lastwindowtitle: String(members[0].title || ""),
                monitorID: Number(members[0].monitor || 0),
                layout: minimizedLayout,
                minimized: true,
                clientAddresses: addresses
              })
            }
            root.minimizedWorkspaces = remainingWorkspaces
            root.scheduleMinimizedStateSave()
          }
          for (var w = 0; !root.showingMinimized && w < workspaceList.length; w++) {
            var ws = workspaceList[w]
            var rawLayout = WindowModel.workspaceLayout(clientsSnapshot, monitorsSnapshot, ws.id, ws.monitorID)
            var layout = []
            for (var t = 0; t < rawLayout.length; t++) {
              var tile = rawLayout[t]
              tile.icon = root.iconFor(tile.appClass, tile.pid, tile.title)
              layout.push(tile)
            }
            entries.push({
              id: Number(ws.id),
              name: String(ws.name || ""),
              windows: Math.max(0, Number(ws.windows || 0)),
              lastwindowtitle: String(ws.lastwindowtitle || ""),
              monitorID: Number(ws.monitorID || 0),
              layout: layout,
              minimized: false,
              clientAddresses: clientsSnapshot.filter(function(client) {
                return client && client.mapped !== false
                  && client.workspace && Number(client.workspace.id) === Number(ws.id)
              }).map(function(client) { return String(client.address || "") })
            })
          }
        } else {
          var clientSnapshot = JSON.parse(String(rawText || "[]"))
          root.reconcileMinimizedState(clientSnapshot)
          if (root.showingMinimized) {
            var remainingClients = ({})
            entries = WindowModel.filteredClients(clientSnapshot, { filterBy: [], excludeWorkspaces: [] }).filter(function(client) {
              var address = String(client.address || "")
              var minimizedClient = root.minimizedClients[address]
              if (!minimizedClient
                  || String((client.workspace || {}).name || "") !== String(minimizedClient.specialTarget || ""))
                return false
              remainingClients[address] = minimizedClient
              return true
            })
            root.minimizedClients = remainingClients
            root.scheduleMinimizedStateSave()
          } else {
            entries = WindowModel.filteredClients(clientSnapshot, root.runtimeConfig).filter(function(client) {
              return String((client.workspace || {}).name || "") !== "special:switcharoo_minimized"
            })
          }
        }
        root.errorMessage = ""
      } catch (error) {
        root.errorMessage = "Unable to parse Hyprland " + subject + " data"
        console.warn("Switcharoo:", root.errorMessage, error)
      }
    }

    windowModel.clear()
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (workspaceMode) {
        var windows = Math.max(0, Number(entry.windows || 0))
        var workspaceId = Number(entry.id)
        windowModel.append({
          selectionKey: (entry.minimized ? "minimized-workspace:" : "workspace:") + workspaceId,
          address: "",
          workspaceId: workspaceId,
          workspaceTarget: workspaceId > 0 ? String(workspaceId) : "name:" + String(entry.name || ""),
          title: String(entry.name || workspaceId),
          specialWorkspace: WindowModel.isSpecialWorkspace(entry),
          windowClass: windows + (windows === 1 ? " window" : " windows"),
          workspaceName: String(entry.lastwindowtitle || ""),
          monitor: Number(entry.monitorID || 0),
          iconSource: Quickshell.iconPath("preferences-desktop-workspaces", true)
            || Quickshell.iconPath("application-x-executable", true),
          layoutJson: JSON.stringify(entry.layout || []),
          minimized: entry.minimized === true,
          clientAddressesJson: JSON.stringify(entry.clientAddresses || [])
        })
      } else {
        var workspace = entry.workspace || {}
        var address = String(entry.address || "")
        windowModel.append({
          selectionKey: "client:" + address,
          address: address,
          workspaceId: Number(workspace.id || 0),
          workspaceTarget: Number(workspace.id) > 0 ? String(workspace.id) : "name:" + String(workspace.name || ""),
          title: String(entry.title || entry.class || "Untitled window"),
          specialWorkspace: false,
          windowClass: String(entry.class || entry.initialClass || "Application"),
          workspaceName: String(workspace.name || workspace.id || ""),
          monitor: Number(entry.monitor || 0),
          iconSource: root.iconFor(entry.class || entry.initialClass || "", entry.pid, entry.title),
          layoutJson: "[]",
          minimized: root.showingMinimized,
          clientAddressesJson: "[]"
        })
      }
    }

    if (root.chooseInitialSelection) {
      root.selectedIndex = WindowModel.initialIndex(windowModel.count, root.runtimeConfig.direction)
      root.chooseInitialSelection = false
    } else if (previousIdentity) {
      var restored = -1
      for (var j = 0; j < windowModel.count; j++) {
        if (windowModel.get(j).selectionKey === previousIdentity) {
          restored = j
          break
        }
      }
      root.selectedIndex = restored >= 0 ? restored : Math.min(root.selectedIndex, Math.max(0, windowModel.count - 1))
    } else {
      root.selectedIndex = Math.min(root.selectedIndex, Math.max(0, windowModel.count - 1))
    }

    root.loading = false
    var queuedMoves = root.queuedMoveDelta
    root.queuedMoveDelta = 0
    while (queuedMoves > 0) {
      root.move("right")
      queuedMoves--
    }
    while (queuedMoves < 0) {
      root.move("left")
      queuedMoves++
    }
    root.positionSelection()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })

    if (root.modifierReleasedWhileLoading) {
      root.modifierReleasedWhileLoading = false
      Qt.callLater(root.activateSelected)
    }
  }

  function positionSelection() {
    if (windowModel.count > 0)
      grid.positionViewAtIndex(root.selectedIndex, GridView.Contain)
  }

  function move(direction) {
    if (windowModel.count === 0) return
    pointerGate.reset()
    root.selectedIndex = WindowModel.nextGridIndex(
      root.selectedIndex,
      direction,
      windowModel.count,
      root.visualColumns,
      root.runtimeConfig.wrapNavigation)
    root.positionSelection()
  }

  function select(index) {
    if (index < 0 || index >= windowModel.count) return
    root.selectedIndex = index
    root.positionSelection()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.select(index)
  }

  function validAddress(address) {
    return /^0x[0-9a-f]+$/i.test(String(address || ""))
  }

  function luaQuote(value) {
    return "'" + String(value || "")
      .replace(/\\/g, "\\\\")
      .replace(/'/g, "\\'")
      .replace(/[\r\n]/g, " ") + "'"
  }

  function moveClientToWorkspace(address, workspaceTarget) {
    if (!root.validAddress(address) || !workspaceTarget) return
    // In Hyprland's Lua dispatcher, follow = false is the equivalent of the
    // legacy movetoworkspacesilent dispatcher.
    Quickshell.execDetached([
      "hyprctl", "eval",
      "return hl.dispatch(hl.dsp.window.move({ workspace = " + root.luaQuote(workspaceTarget)
        + ", window = 'address:" + address + "', follow = false }))"
    ])
  }

  function minimizeSelected() {
    if (root.selectedIndex < 0 || root.selectedIndex >= windowModel.count) return
    var selected = windowModel.get(root.selectedIndex)
    if (selected.minimized) {
      if (root.restoreSelected(selected, false)) refreshTimer.restart()
      return
    }

    if (root.runtimeConfig.switchMode === "workspaces") {
      var addresses = []
      try { addresses = JSON.parse(String(selected.clientAddressesJson || "[]")) } catch (error) { return }
      addresses = addresses.filter(root.validAddress)
      if (addresses.length === 0 || selected.specialWorkspace) return

      var key = "workspace:" + String(selected.workspaceId)
      var specialTarget = "special:switcharoo_minimized_workspace_" + String(selected.workspaceId).replace(/-/g, "n")
      root.minimizedWorkspaces[key] = {
        id: Number(selected.workspaceId),
        name: String(selected.title),
        target: String(selected.workspaceTarget),
        addresses: addresses,
        specialTarget: specialTarget
      }
      // Reassign so QML observes the map update.
      root.minimizedWorkspaces = root.minimizedWorkspaces
      root.scheduleMinimizedStateSave()
      for (var i = 0; i < addresses.length; i++)
        root.moveClientToWorkspace(addresses[i], specialTarget)
    } else {
      var address = String(selected.address || "")
      if (!root.validAddress(address) || !selected.workspaceTarget) return
      root.minimizedClients[address] = {
        target: String(selected.workspaceTarget),
        specialTarget: "special:switcharoo_minimized"
      }
      root.minimizedClients = root.minimizedClients
      root.scheduleMinimizedStateSave()
      root.moveClientToWorkspace(address, "special:switcharoo_minimized")
    }
    refreshTimer.restart()
  }

  function restoreSelected(selected, focus) {
    if (root.runtimeConfig.switchMode === "workspaces") {
      var workspaceKey = "workspace:" + String(selected.workspaceId)
      var minimizedWorkspace = root.minimizedWorkspaces[workspaceKey]
      if (!minimizedWorkspace) return false
      delete root.minimizedWorkspaces[workspaceKey]
      root.minimizedWorkspaces = root.minimizedWorkspaces
      root.scheduleMinimizedStateSave()
      var addresses = minimizedWorkspace.addresses || []
      for (var i = 0; i < addresses.length; i++)
        root.moveClientToWorkspace(addresses[i], minimizedWorkspace.target)
      if (focus !== false) {
        Quickshell.execDetached([
          "hyprctl", "eval",
          "return hl.dispatch(hl.dsp.focus({ workspace = " + root.luaQuote(minimizedWorkspace.target) + " }))"
        ])
      }
      return true
    }

    var address = String(selected.address || "")
    var minimizedClient = root.minimizedClients[address]
    if (!minimizedClient) return false
    delete root.minimizedClients[address]
    root.minimizedClients = root.minimizedClients
    root.scheduleMinimizedStateSave()
    root.moveClientToWorkspace(address, minimizedClient.target)
    if (focus !== false) {
      Quickshell.execDetached([
        "hyprctl", "eval",
        "return hl.dispatch(hl.dsp.focus({ window = 'address:" + address + "' }))"
      ])
    }
    return true
  }

  function toggleMinimized() {
    root.showingMinimized = !root.showingMinimized
    root.chooseInitialSelection = true
    root.loading = true
    root.requestSnapshot()
  }

  function activateSelected() {
    if (root.selectedIndex < 0 || root.selectedIndex >= windowModel.count) {
      if (!root.loading) root.dismiss()
      return
    }

    var selected = windowModel.get(root.selectedIndex)
    if (selected.minimized) {
      if (root.restoreSelected(selected)) root.dismiss()
      return
    }
    if (root.runtimeConfig.switchMode === "workspaces") {
      var workspaceTarget = String(selected.workspaceTarget || "")
      if (!workspaceTarget) {
        root.dismiss()
        return
      }

      root.dismiss()
      Quickshell.execDetached([
        "hyprctl",
        "eval",
        "return hl.dispatch(hl.dsp.focus({ workspace = " + root.luaQuote(workspaceTarget) + " }))"
      ])
      return
    }

    var address = String(selected.address || "")
    if (!root.validAddress(address)) {
      if (!root.loading) root.dismiss()
      return
    }

    root.dismiss()
    Quickshell.execDetached([
      "hyprctl",
      "eval",
      "return hl.dispatch(hl.dsp.focus({ window = 'address:" + address + "' }))"
    ])
  }

  // Public IPC method for callers that want to commit the current selection
  // explicitly (for example a custom compositor binding). The "allowEarly"
  // path arms an imminent open when a release arrives before the summon IPC
  // does.
  function commitSelection(mode) {
    if (!root.opened) {
      if (String(mode || "") !== "allowEarly") return "closed"
      root.earlyCommitArmed = true
      earlyCommitExpiry.restart()
      return "armed"
    }
    if (root.loading) {
      root.modifierReleasedWhileLoading = true
      return "pending"
    }
    root.activateSelected()
    return "ok"
  }

  function closeSelected() {
    if (root.runtimeConfig.switchMode === "workspaces") return
    if (root.selectedIndex < 0 || root.selectedIndex >= windowModel.count) return
    var address = String(windowModel.get(root.selectedIndex).address || "")
    if (!root.validAddress(address)) return

    Quickshell.execDetached([
      "hyprctl",
      "eval",
      "return hl.dispatch(hl.dsp.window.close({ window = 'address:" + address + "' }))"
    ])
    windowModel.remove(root.selectedIndex)
    root.selectedIndex = Math.min(root.selectedIndex, Math.max(0, windowModel.count - 1))
    root.positionSelection()
  }

  // Release-modifier support (runtimeConfig.releaseModifiers): modifiers
  // whose release commits the selection. Qt reports the Super key as Key_Meta
  // on some platforms, so "super" matches both Key_Meta and the explicit
  // Super keys; "meta" stays separate for platforms that distinguish them.
  readonly property var _releaseModifierQtKeys: ({
    'alt': [Qt.Key_Alt],
    'meta': [Qt.Key_Meta],
    'super': [Qt.Key_Meta, Qt.Key_Super_L, Qt.Key_Super_R],
  })

  readonly property var _releaseModifierKeysyms: ({
    'alt': ["Alt_L", "Alt_R"],
    'meta': ["Meta_L", "Meta_R"],
    'super': ["Super_L", "Super_R"],
  })

  function isReleaseModifier(key) {
    var names = root.runtimeConfig.releaseModifiers || ["alt"]
    for (var i = 0; i < names.length; i++) {
      var keys = root._releaseModifierQtKeys[String(names[i])]
      if (keys && keys.indexOf(key) !== -1) return true
    }
    return false
  }

  function modifierKeyExpr() {
    var names = root.runtimeConfig.releaseModifiers || ["alt"]
    var exprs = []
    for (var i = 0; i < names.length; i++) {
      var keysyms = root._releaseModifierKeysyms[String(names[i])]
      if (!keysyms) continue
      for (var j = 0; j < keysyms.length; j++)
        exprs.push('hl.is_key_down("' + keysyms[j] + '")')
    }
    if (exprs.length === 0)
      exprs = ['hl.is_key_down("Alt_L")', 'hl.is_key_down("Alt_R")']
    return exprs.join(" or ")
  }

  function loadMinimizedState(raw) {
    if (root.minimizedStateLoaded) return
    try {
      var state = JSON.parse(String(raw || "{}"))
      root.minimizedClients = state && typeof state.clients === "object" ? state.clients : ({})
      root.minimizedWorkspaces = state && typeof state.workspaces === "object" ? state.workspaces : ({})
    } catch (error) {
      console.warn("Switcharoo: invalid minimized state:", error)
      root.minimizedClients = ({})
      root.minimizedWorkspaces = ({})
    }
    root.minimizedStateLoaded = true
  }

  function reconcileMinimizedState(clients) {
    var present = ({})
    var source = Array.isArray(clients) ? clients : []
    for (var i = 0; i < source.length; i++) {
      var address = String(source[i] && source[i].address || "")
      if (root.validAddress(address) && source[i].mapped !== false)
        present[address] = true
    }

    var changed = false
    var clientsNext = ({})
    var clientKeys = Object.keys(root.minimizedClients)
    for (var c = 0; c < clientKeys.length; c++) {
      var clientAddress = clientKeys[c]
      if (present[clientAddress]) clientsNext[clientAddress] = root.minimizedClients[clientAddress]
      else changed = true
    }

    var workspacesNext = ({})
    var workspaceKeys = Object.keys(root.minimizedWorkspaces)
    for (var w = 0; w < workspaceKeys.length; w++) {
      var key = workspaceKeys[w]
      var minimizedWorkspace = root.minimizedWorkspaces[key]
      var addresses = Array.isArray(minimizedWorkspace.addresses) ? minimizedWorkspace.addresses : []
      var existingAddresses = addresses.filter(function(address) { return present[String(address)] })
      if (existingAddresses.length === 0) {
        changed = true
        continue
      }
      if (existingAddresses.length !== addresses.length) changed = true
      var copy = JSON.parse(JSON.stringify(minimizedWorkspace))
      copy.addresses = existingAddresses
      workspacesNext[key] = copy
    }

    if (!changed) return
    root.minimizedClients = clientsNext
    root.minimizedWorkspaces = workspacesNext
    root.scheduleMinimizedStateSave()
  }

  function scheduleMinimizedStateSave() {
    if (root.minimizedStateDirectoryReady) minimizedStateSaveTimer.restart()
  }

  function saveMinimizedState() {
    minimizedStateFile.setText(JSON.stringify({
      version: 1,
      clients: root.minimizedClients,
      workspaces: root.minimizedWorkspaces
    }) + "\n")
  }

  onLoadingChanged: {
    if (!root.loading)
      root.lastKnownCardWidth = root.calculatedCardWidth
  }

  Component.onCompleted: ensureMinimizedStateDir.running = true

  Process {
    id: ensureMinimizedStateDir
    command: ["mkdir", "-p", root.minimizedStateDir]
    onExited: {
      root.minimizedStateDirectoryReady = true
      // Keep the initial read behind mkdir. Otherwise a missing file can be
      // reported before the directory exists, and a quick minimize can try
      // to write into that missing directory.
      minimizedStateFile.reload()
      // A missing file may have completed its implicit load before mkdir.
      // Schedule after the explicit reload so first-run state is persisted.
      root.scheduleMinimizedStateSave()
    }
  }

  ListModel { id: windowModel }

  FileView {
    id: minimizedStateFile
    path: root.minimizedStatePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadMinimizedState(text())
    onLoadFailed: {
      root.loadMinimizedState("")
      // Persist an empty state on first run as well. This both initializes the
      // file and makes the persistence location observable before the first
      // minimize action.
      root.scheduleMinimizedStateSave()
    }
    onSaveFailed: console.warn("Switcharoo: failed to save minimized state", error)
  }

  Timer {
    id: minimizedStateSaveTimer
    interval: 100
    repeat: false
    onTriggered: root.saveMinimizedState()
  }

  FileView {
    id: cmdlineView
    preload: false
    blockAllReads: true
    printErrors: false
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  Process {
    id: snapshotProcess
    command: ["hyprctl", "-j", "clients"]
    stdout: StdioCollector {
      id: snapshotOutput
      waitForEnd: true
    }
    onExited: function(exitCode) {
      root.applySnapshot(snapshotOutput.text, exitCode)
      if (root.refreshPending) {
        root.refreshPending = false
        refreshTimer.restart()
      }
    }
  }

  Timer {
    id: refreshTimer
    interval: 100
    onTriggered: if (root.opened) root.requestSnapshot()
  }

  Timer {
    id: earlyCommitExpiry
    interval: 500
    onTriggered: root.earlyCommitArmed = false
  }

  Timer {
    id: modifierWatchTimer
    interval: 60
    repeat: true
    onTriggered: {
      if (!root.opened || !root.runtimeConfig.commitOnModifierRelease || root.sawKeyEvent) {
        stop()
        return
      }
      if (!modifierCheck.running) {
        modifierCheck.command = [
          "hyprctl",
          "eval",
          "error(tostring(" + root.modifierKeyExpr() + "))"
        ]
        modifierCheck.running = true
      }
    }
  }

  Process {
    id: modifierCheck
    command: []
    stdout: StdioCollector {
      onStreamFinished: {
        if (!root.opened || !root.runtimeConfig.commitOnModifierRelease || root.sawKeyEvent) return
        if (!text.trim().endsWith("true"))
          root.commitSelection()
      }
    }
  }

  Timer {
    id: bindingsCheckTimer
    interval: 3000
    running: true
    onTriggered: if (!bindingsCheck.running) bindingsCheck.running = true
  }

  Process {
    id: bindingsCheck
    command: ["hyprctl", "-j", "binds"]
    stdout: StdioCollector {
      onStreamFinished: {
        var binds = []
        try { binds = JSON.parse(text) } catch (error) { return }
        if (!binds.some(function(bind) { return bind && bind.description === "Switcharoo switcher" }))
          missingBindingsNotify.running = true
      }
    }
  }

  Process {
    id: missingBindingsNotify
    command: [
      "sh",
      "-c",
      'action=$(notify-send -u critical -A default="Open README" "Switcharoo" ' +
      '"No keybinding found. Add switcharoo-bindings.lua to your Hyprland config."); ' +
      '[ "$action" = "default" ] && xdg-open ' +
      '"https://github.com/gabrielvincent/switcharoo/blob/main/README.md"'
    ]
  }

  GlobalShortcut {
    appid: "omarchy-switcharoo"
    name: "next"
    onPressed: {
      root.openedViaShortcut = true
      root.open('{"direction":"next"}')
    }
  }

  GlobalShortcut {
    appid: "omarchy-switcharoo"
    name: "previous"
    onPressed: {
      root.openedViaShortcut = true
      root.open('{"direction":"previous"}')
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (!root.opened) return
      var name = String(event && event.name || "")
      if ([
        "openwindow", "closewindow", "windowtitle", "movewindow", "movewindowv2",
        "workspace", "createworkspace", "destroyworkspace", "moveworkspace", "focusedmon"
      ].indexOf(name) !== -1)
        refreshTimer.restart()
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-switcharoo"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim
      visible: root.runtimeConfig.dimBackdrop
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      anchors.centerIn: parent
      width: root.cardWidth
      height: root.cardHeight
      radius: Style.cornerRadius
      color: Color.menu.background
      borderSpec: Border.surfaceSpec("menu", "border", Color.menu.border, root.surfaceBorderWidth)
      padding: root.contentPadding

      MouseArea { anchors.fill: parent; onClicked: function(mouse) { mouse.accepted = true } }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        z: 10

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          root.sawKeyEvent = true
          modifierWatchTimer.stop()
          var text = String(event.text || "").toLowerCase()
          var backwardsTab = event.key === Qt.Key_Backtab
            || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))

          if (event.key === Qt.Key_Escape) {
            if (root.showingMinimized) root.toggleMinimized()
            else root.dismiss()
          } else if ((event.modifiers & Qt.ShiftModifier) && text === "m") {
            root.toggleMinimized()
          } else if (text === "m") {
            root.minimizeSelected()
          } else if (event.key === Qt.Key_Delete || text === root.runtimeConfig.killKey) {
            root.closeSelected()
          } else if (event.key === Qt.Key_Left || text === "h" || backwardsTab) {
            root.move("left")
          } else if (event.key === Qt.Key_Right || text === "l" || event.key === Qt.Key_Tab) {
            root.move("right")
          } else if (event.key === Qt.Key_Down || text === "j") {
            root.move("down")
          } else if (event.key === Qt.Key_Up || text === "k") {
            root.move("up")
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            root.activateSelected()
          } else {
            return
          }
          event.accepted = true
        }

        Keys.onReleased: function(event) {
          root.sawKeyEvent = true
          modifierWatchTimer.stop()
          if (!root.runtimeConfig.commitOnModifierRelease || !root.isReleaseModifier(event.key)) return
          root.commitSelection()
          event.accepted = true
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: 0

        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            visible: root.showingMinimized
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "←"
            color: Color.menu.text
            opacity: 0.72
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.body

            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleMinimized()
            }
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: root.loading ? "Loading…" : root.windowCount
              + (root.runtimeConfig.switchMode === "workspaces"
                ? (root.windowCount === 1 ? " workspace" : " workspaces")
                : (root.windowCount === 1 ? " window" : " windows"))
            color: Color.menu.text
            opacity: 0.58
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }
        }

        Item {
          width: parent.width
          height: Math.max(0, parent.height - root.headerHeight - root.footerHeight)

          GridView {
            id: grid
            // The initial snapshot is asynchronous.  Keeping the previous
            // model visible here makes the cards appear to reorder on open.
            // Refreshes after loading do not set loading, so normal live
            // updates remain visible without causing a flash.
            visible: !root.loading
            anchors.centerIn: parent
            width: Math.min(parent.width, root.gridWidth)
            height: parent.height
            model: windowModel
            clip: true
            cellWidth: root.cellWidth
            cellHeight: root.cellHeight
            boundsBehavior: Flickable.StopAtBounds

            ScrollBar.vertical: ScrollBar {
              policy: grid.contentHeight > grid.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
              width: Style.space(4)

              background: Rectangle {
                color: "transparent"
              }

              contentItem: Rectangle {
                implicitWidth: Style.space(4)
                radius: width / 2
                color: Util.alpha(Color.menu.text, 0.55)
              }
            }

            delegate: Rectangle {
              id: windowCard
              required property int index
              required property string address
              required property string title
              required property string windowClass
              required property string workspaceName
              required property bool specialWorkspace
              required property string iconSource
              required property string layoutJson

              readonly property bool selected: index === root.selectedIndex
              readonly property bool workspaceMode: root.runtimeConfig.switchMode === "workspaces"
              readonly property var tiles: JSON.parse(windowCard.layoutJson)

              width: root.cellWidth - Style.space(8)
              height: root.cellHeight - Style.space(8)
              radius: Style.cornerRadius
              color: selected ? Color.menu.selectedBackground : Style.normalFillFor(Color.menu.text, Color.accent)
              border.width: selected ? Math.max(2, Style.focusBorderWidth) : Style.normalBorderWidth
              border.color: selected ? Color.accent : Style.normalBorderFor(Color.menu.text, Color.accent)

              // Workspace mode: miniature tiled layout preview.
              Item {
                visible: windowCard.workspaceMode
                anchors.fill: parent

                Item {
                  id: workspaceCanvas
                  anchors {
                    fill: parent
                    margins: Style.spacing.md
                    bottomMargin: root.runtimeConfig.showWorkspace ? Style.space(46) : Style.spacing.md
                  }
                  clip: true

                  Repeater {
                    model: windowCard.tiles
                    delegate: Rectangle {
                      x: workspaceCanvas.width * modelData.x
                      y: workspaceCanvas.height * modelData.y
                      width: workspaceCanvas.width * modelData.w
                      height: workspaceCanvas.height * modelData.h
                      radius: 2
                      clip: true
                      color: windowCard.selected
                        ? Util.alpha(Color.menu.selectedText, 0.16)
                        : Util.alpha(Color.menu.text, 0.12)
                      border.width: 1
                      border.color: windowCard.selected
                        ? Util.alpha(Color.menu.selectedText, 0.45)
                        : Util.alpha(Color.menu.text, 0.28)

                      Image {
                        anchors.centerIn: parent
                        width: Math.max(14, Math.min(parent.width, parent.height) * 0.6)
                        height: width
                        source: modelData.icon || ""
                        sourceSize.width: width
                        sourceSize.height: height
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        smooth: true
                      }
                    }
                  }
                }

                Text {
                  visible: root.runtimeConfig.showWorkspace
                  anchors {
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                    margins: Style.spacing.md
                  }
                  text: windowCard.title
                  textFormat: Text.PlainText
                  color: windowCard.selected ? Color.menu.selectedText : Color.menu.text
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.body
                  font.bold: windowCard.selected
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                  maximumLineCount: 1
                }
              }

              Rectangle {
                id: specialBadge
                visible: windowCard.workspaceMode
                  && windowCard.specialWorkspace
                  && root.runtimeConfig.showSpecialWorkspaceBadge
                anchors {
                  top: parent.top
                  right: parent.right
                  topMargin: Style.spacing.sm
                  rightMargin: Style.spacing.sm
                }
                width: specialBadgeLabel.implicitWidth + Style.spacing.sm * 2
                height: specialBadgeLabel.implicitHeight + Style.space(4)
                radius: height / 2
                color: Color.accent
                z: 2

                Text {
                  id: specialBadgeLabel
                  anchors.centerIn: parent
                  text: "special"
                  color: Color.menu.background
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              // Client mode: centered icon and title.
              Column {
                visible: !windowCard.workspaceMode
                anchors {
                  left: parent.left
                  right: parent.right
                  verticalCenter: parent.verticalCenter
                  leftMargin: Style.spacing.md
                  rightMargin: Style.spacing.md
                }
                height: implicitHeight
                spacing: Style.spacing.sm

                Image {
                  anchors.horizontalCenter: parent.horizontalCenter
                  width: Style.space(58)
                  height: width
                  source: windowCard.iconSource
                  sourceSize.width: width
                  sourceSize.height: height
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true
                  smooth: true
                }

                Text {
                  width: parent.width
                  text: windowCard.title
                  textFormat: Text.PlainText
                  color: windowCard.selected ? Color.menu.selectedText : Color.menu.text
                  font.family: Style.font.menuFamily
                  font.pixelSize: Style.font.body
                  font.bold: windowCard.selected
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                  maximumLineCount: 1
                }

              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                onEntered: root.selectFromPointer(windowCard.index, windowCard, {
                  x: mouseX,
                  y: mouseY
                })
                onPositionChanged: function(mouse) {
                  root.selectFromPointer(windowCard.index, windowCard, mouse)
                }
                onClicked: function(mouse) {
                  root.select(windowCard.index)
                  if (mouse.button === Qt.MiddleButton && root.runtimeConfig.switchMode !== "workspaces")
                    root.closeSelected()
                  else
                    root.activateSelected()
                }
              }
            }
          }

          Column {
            anchors.centerIn: parent
            spacing: Style.spacing.sm
            visible: !root.loading && root.windowCount === 0

            Text {
              width: parent.width
              text: root.errorMessage ? "󰅚" : "󰖯"
              color: root.errorMessage ? Color.urgent : Color.menu.selectedText
              font.family: Style.font.family
              font.pixelSize: Style.font.displayLarge
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              text: root.errorMessage || (root.runtimeConfig.switchMode === "workspaces"
                ? "No matching workspaces"
                : "No matching windows")
              color: Color.menu.text
              opacity: 0.72
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.body
            }
          }
        }

        Item {
          width: parent.width
          height: root.footerHeight

          // Equal-width cells and bullet separators keep each hint distinct
          // while distributing them across the footer.
          RowLayout {
            anchors.fill: parent
            spacing: Style.spacing.sm

            Text {
              text: "h/j/k/l or 🞀/🞃/🞁/🞂  Navigate"
              color: Color.menu.text
              opacity: 0.52
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignLeft
              Layout.fillWidth: true
              Layout.preferredWidth: 0
              Layout.minimumWidth: 0
              Layout.alignment: Qt.AlignVCenter
            }
            Text {
              visible: root.showingMinimized
              text: "Esc  Go back"
              color: Color.menu.text
              opacity: 0.52
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignRight
              Layout.fillWidth: true
              Layout.preferredWidth: 0
              Layout.minimumWidth: 0
              Layout.alignment: Qt.AlignVCenter
            }
            Text {
              visible: !root.showingMinimized && root.runtimeConfig.switchMode !== "workspaces"
              text: root.runtimeConfig.killKey.toUpperCase() + " / Del  Close"
              color: Color.menu.text
              opacity: 0.52
              font.family: Style.font.menuFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignRight
              Layout.fillWidth: true
              Layout.preferredWidth: 0
              Layout.minimumWidth: 0
              Layout.alignment: Qt.AlignVCenter
            }
          }
        }
      }
    }
  }
}
