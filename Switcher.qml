import QtQuick
import QtQuick.Controls
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
  property int queuedMoveDelta: 0
  property int selectedIndex: 0
  property var runtimeConfig: WindowModel.normalizedConfig({}, {})
  property string errorMessage: ""

  readonly property int windowCount: windowModel.count
  readonly property int minimumCellWidth: Style.space(190)
  readonly property int cellWidth: Style.space(210)
  readonly property int cellHeight: Style.space(142)
  readonly property int contentPadding: Style.spacing.panelPadding
  readonly property int surfaceBorderWidth: Math.max(1, Style.normalBorderWidth)
  readonly property int headerHeight: Math.max(Style.space(34), Style.font.caption + Style.spacing.controlPaddingY * 2)
  readonly property int footerHeight: Math.max(Style.space(34), Style.font.caption + Style.spacing.controlPaddingY * 2)
  readonly property int availableGridWidth: Math.max(root.minimumCellWidth, panel.width - Style.gapsOut * 4 - root.contentPadding * 2 - root.surfaceBorderWidth * 2)
  readonly property int widthLimitedColumns: Math.max(1, Math.floor(root.availableGridWidth / root.cellWidth))
  readonly property int columns: Math.max(1, Math.min(runtimeConfig.itemsPerRow, widthLimitedColumns, Math.max(1, windowCount)))
  readonly property int visualColumns: Math.max(1, Math.min(columns, Math.floor(Math.max(0, grid.width) / cellWidth)))
  readonly property int rows: Math.max(1, Math.ceil(windowCount / visualColumns))
  readonly property int visibleRows: Math.min(rows, runtimeConfig.maxVisibleRows)
  readonly property int gridWidth: columns * cellWidth
  readonly property int gridHeight: visibleRows * cellHeight
  readonly property int cardWidth: Math.min(panel.width - Style.gapsOut * 4, Math.max(Style.space(380), gridWidth + contentPadding * 2 + surfaceBorderWidth * 2))
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
    root.errorMessage = ""
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
          var activeWorkspaceId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : NaN
          var workspaceList = WindowModel.filteredWorkspaces(combined.workspaces || [], root.runtimeConfig, activeWorkspaceId, clientsSnapshot)
          entries = []
          for (var w = 0; w < workspaceList.length; w++) {
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
              layout: layout
            })
          }
        } else {
          entries = WindowModel.filteredClients(JSON.parse(String(rawText || "[]")), root.runtimeConfig)
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
          selectionKey: "workspace:" + workspaceId,
          address: "",
          workspaceId: workspaceId,
          workspaceTarget: workspaceId > 0 ? String(workspaceId) : "name:" + String(entry.name || ""),
          title: String(entry.name || workspaceId),
          windowClass: windows + (windows === 1 ? " window" : " windows"),
          workspaceName: String(entry.lastwindowtitle || ""),
          monitor: Number(entry.monitorID || 0),
          iconSource: Quickshell.iconPath("preferences-desktop-workspaces", true)
            || Quickshell.iconPath("application-x-executable", true),
          layoutJson: JSON.stringify(entry.layout || [])
        })
      } else {
        var workspace = entry.workspace || {}
        var address = String(entry.address || "")
        windowModel.append({
          selectionKey: "client:" + address,
          address: address,
          workspaceId: 0,
          workspaceTarget: "",
          title: String(entry.title || entry.class || "Untitled window"),
          windowClass: String(entry.class || entry.initialClass || "Application"),
          workspaceName: String(workspace.name || workspace.id || ""),
          monitor: Number(entry.monitor || 0),
          iconSource: root.iconFor(entry.class || entry.initialClass || "", entry.pid, entry.title),
          layoutJson: "[]"
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

  function activateSelected() {
    if (root.selectedIndex < 0 || root.selectedIndex >= windowModel.count) {
      if (!root.loading) root.dismiss()
      return
    }

    var selected = windowModel.get(root.selectedIndex)
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

  function isReleaseModifier(key) {
    return key === Qt.Key_Alt
  }

  function modifierKeyExpr() {
    return 'hl.is_key_down("Alt_L") or hl.is_key_down("Alt_R")'
  }

  ListModel { id: windowModel }

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
            root.dismiss()
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

              // Client mode: icon, title, and class/workspace subtitle.
              Column {
                visible: !windowCard.workspaceMode
                anchors.fill: parent
                anchors.margins: Style.spacing.md
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

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "h/j/k/l or 🞀/🞃/🞁/🞂  Navigate"
            color: Color.menu.text
            opacity: 0.52
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.runtimeConfig.switchMode !== "workspaces"
            text: root.runtimeConfig.killKey.toUpperCase() + " / Del  Close"
            color: Color.menu.text
            opacity: 0.52
            font.family: Style.font.menuFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
