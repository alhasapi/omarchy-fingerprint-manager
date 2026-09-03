import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Ui
import qs.Commons
import "components"
import "Model.js" as Model

// Android-style fingerprint manager. Three states, decided by
// omarchy-fingerprint-setup-status before anything else runs:
//   "no-hardware"   -- no reader on this machine
//   "not-installed" -- reader present, no fprintd-compatible backend yet
//   "ready"         -- full manager: enrolled fingers, add/remove-all,
//                      per-task toggles, danger-zone uninstall
//
// Setup and uninstall are NOT reimplemented here -- they hand off to the
// already-tested, already-upstreamed omarchy-setup-security-fingerprint /
// omarchy-remove-security-fingerprint scripts in a floating terminal (same
// launch the Omarchy menu itself uses), then poll back to a fresh status.
//
// This is a summon-only `panel` plugin, not a bar widget: it is a settings
// screen, and every bar widget in Omarchy is a live status indicator. It
// carries no state worth glancing at, so it takes no bar slot and is opened
// from the menu's Security submenu instead:
//   omarchy-shell shell summon alhasapi.fingerprint
Item {
  id: root

  // Injected by the shell's panel Loader (shell.qml onLoaded).
  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  property bool opened: false

  // Absolute path to this plugin's directory, so its bin/ scripts can be
  // launched without depending on PATH. Same idiom as alhasapi.power/Panel.qml.
  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    return url.indexOf("file://") === 0 ? url.substring(7) : url
  }

  property string setupState: "checking" // checking | no-hardware | not-installed | ready
  property bool hardwarePresent: false
  property bool backendPresent: false

  // True while a setup/uninstall floating-terminal handoff may be running,
  // so the panel keeps polling omarchy-fingerprint-setup-status until the
  // backend's presence flips to what that handoff expects.
  property bool handoffPolling: false
  property bool handoffExpectsBackend: true

  property string deviceName: ""
  property string scanType: ""
  property int numEnrollStages: 0
  property var enrolledFingers: []
  readonly property var availableFingers: Model.availableFingers(root.enrolledFingers)

  // Set when the backend is installed but the device itself won't answer.
  // python-validity in particular drops its USB device after a suspend and
  // crash-loops, and fprintd then reports NoSuchDevice. Without surfacing
  // this, an erroring reader looks exactly like an empty enrollment list.
  property string deviceError: ""

  property var toggleState: ({ sudo: false, polkit: false, lock: false })
  property var busyToggles: ({})

  property bool showEnrollFlow: false
  property string enrollingFinger: ""
  property int enrollStage: 0
  property string enrollHintText: ""
  property bool enrollTerminal: false
  property bool enrollSuccess: false

  property bool confirmRemoveAllOpen: false
  property bool confirmUninstallOpen: false

  // Per-task toggles and the uninstall action used to live inline in the
  // main "ready" column -- with the finger list too, that easily exceeded
  // the card's height and the last item (uninstall) rendered off the visible
  // edge. They now live in a full-bleed settings overlay (below), toggled
  // from a header icon, the same pattern avila.ultra-docker/Panel.qml uses
  // for its own settings screen.
  property bool settingsOpen: false

  // Card chrome, matched to Ui/KeyboardPanel.qml and Ui/PopupCard.qml so a
  // summoned card looks like every other Omarchy popup.
  readonly property int cardPadding: Style.spacing.popupPadding
  readonly property var borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))

  // ---------- shell panel-plugin contract ----------

  function open(payloadJson) {
    // Payload is unused: there is only one thing this panel can show. It is
    // still accepted because the shell always passes one.
    root.setupState = "checking"
    // Cleared so a previous summon's device error can't flash under the new
    // one's list before its own probe lands.
    root.deviceError = ""
    root.refreshSetupStatus()
    root.opened = true
    // The window is instantiated hidden, so `focus: true` on the key catcher
    // is evaluated before the surface is mapped and Escape would land
    // nowhere. Re-acquire after mapping -- same reason as wifiqr/Panel.qml.
    Qt.callLater(function() {
      if (root.opened) keyCatcher.forceActiveFocus()
    })
  }

  function close() {
    root.opened = false
    // A re-summon must not resume someone else's half-finished enrollment or
    // reopen a confirmation they walked away from.
    root.settingsOpen = false
    root.confirmRemoveAllOpen = false
    root.confirmUninstallOpen = false
    root.showEnrollFlow = false
    if (enrollProc.running) enrollProc.running = false
    root.enrollingFinger = ""
    root.enrollStage = 0
    root.enrollHintText = ""
    root.enrollTerminal = false
    root.enrollSuccess = false
    // handoffPolling deliberately survives: a setup/uninstall wizard running
    // in its terminal keeps being polled, so reopening shows the new state.
  }

  function dismiss() {
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "alhasapi.fingerprint")
    else close()
  }

  // ---------- state ----------

  function refreshSetupStatus() {
    if (!setupStatusProc.running) setupStatusProc.running = true
  }

  function refreshFprintdStatus() {
    if (!fprintdStatusProc.running) fprintdStatusProc.running = true
  }

  function refreshToggleStatus() {
    if (!toggleStatusProc.running) toggleStatusProc.running = true
  }

  function handleSetupStatus(raw) {
    var parsed = Model.parseLine(raw)
    if (!parsed || parsed.event !== "setup-status") return

    root.hardwarePresent = !!parsed.hardware
    root.backendPresent = !!parsed.backend
    root.setupState = !root.hardwarePresent ? "no-hardware"
      : !root.backendPresent ? "not-installed"
      : "ready"

    if (root.handoffPolling && root.backendPresent === root.handoffExpectsBackend) {
      root.handoffPolling = false
      setupPollTimer.stop()
    }

    if (root.setupState === "ready") {
      root.refreshFprintdStatus()
      root.refreshToggleStatus()
    }
  }

  function handleFprintdStatus(raw) {
    var parsed = Model.parseLine(raw)
    if (!parsed) return

    // A backend that is installed but whose device is gone answers with an
    // error, not a status. Report that rather than falling through to an
    // empty list, which would read as "you have no fingerprints enrolled".
    if (parsed.event === "error") {
      root.deviceError = parsed.code === "NoSuchDevice"
        ? "The fingerprint reader isn't responding. The backend is installed but its device is gone — check `systemctl status python3-validity open-fprintd`."
        : String(parsed.message || "The fingerprint service returned an error.")
      root.deviceName = ""
      root.numEnrollStages = 0
      root.enrolledFingers = []
      return
    }

    if (parsed.event !== "status") return
    root.deviceError = ""
    root.deviceName = String(parsed.name || "")
    root.scanType = String(parsed.scanType || "")
    root.numEnrollStages = Number(parsed.numEnrollStages) || 0
    root.enrolledFingers = parsed.fingers || []
  }

  function handleToggleStatus(raw) {
    var parsed = Model.parseLine(raw)
    if (!parsed || parsed.event !== "toggle-status") return
    root.toggleState = { sudo: !!parsed.sudo, polkit: !!parsed.polkit, lock: !!parsed.lock }
    root.busyToggles = ({})
  }

  function startHandoff(script, expectsBackend) {
    Quickshell.execDetached([
      "omarchy-launch-floating-terminal-with-presentation", script
    ])
    root.handoffExpectsBackend = expectsBackend
    root.handoffPolling = true
    setupPollTimer.restart()
  }

  function startSetup() {
    startHandoff("omarchy-setup-security-fingerprint", true)
  }

  function requestUninstall() {
    root.confirmUninstallOpen = true
  }

  function confirmUninstall() {
    root.confirmUninstallOpen = false
    startHandoff("omarchy-remove-security-fingerprint", false)
  }

  function pickFinger(fingerName) {
    root.enrollingFinger = fingerName
    root.enrollStage = 0
    root.enrollHintText = "Touch the sensor."
    root.enrollTerminal = false
    root.enrollSuccess = false
    enrollProc.command = [root.pluginDir + "bin/omarchy-fprintd-enroll", fingerName]
    enrollProc.running = true
  }

  function cancelEnroll() {
    if (enrollProc.running) enrollProc.running = false
  }

  function dismissEnroll() {
    root.enrollingFinger = ""
    root.enrollTerminal = false
    root.showEnrollFlow = false
    root.refreshFprintdStatus()
  }

  function handleEnrollLine(line) {
    var parsed = Model.parseLine(line)
    if (!parsed) return

    if (parsed.event === "error") {
      root.enrollHintText = String(parsed.message || "Something went wrong.")
      root.enrollTerminal = true
      root.enrollSuccess = false
      return
    }

    root.enrollHintText = Model.enrollHint(parsed.event)
    if (parsed.event === "enroll-stage-passed") root.enrollStage += 1

    if (Model.isEnrollTerminal(parsed.event)) {
      root.enrollTerminal = true
      root.enrollSuccess = parsed.event === "enroll-completed"
    }
  }

  function requestRemoveAll() {
    root.confirmRemoveAllOpen = true
  }

  function confirmRemoveAll() {
    root.confirmRemoveAllOpen = false
    if (!deleteAllProc.running) deleteAllProc.running = true
  }

  function requestToggle(task) {
    if (root.busyToggles[task]) return
    var nextState = root.toggleState[task] ? "off" : "on"
    var busy = Object.assign({}, root.busyToggles)
    busy[task] = true
    root.busyToggles = busy
    toggleProc.command = ["pkexec", root.pluginDir + "bin/omarchy-fingerprint-toggle", task, nextState]
    toggleProc.running = true
  }

  // ---------- bin/ script processes ----------

  Process {
    id: setupStatusProc
    command: [root.pluginDir + "bin/omarchy-fingerprint-setup-status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.handleSetupStatus(text) }
  }

  Process {
    id: fprintdStatusProc
    command: [root.pluginDir + "bin/omarchy-fprintd-status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.handleFprintdStatus(text) }
  }

  Process {
    id: toggleStatusProc
    command: [root.pluginDir + "bin/omarchy-fingerprint-toggle-status"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.handleToggleStatus(text) }
  }

  Process {
    id: deleteAllProc
    command: [root.pluginDir + "bin/omarchy-fprintd-delete-all"]
    onExited: root.refreshFprintdStatus()
  }

  Process {
    id: enrollProc
    stdout: SplitParser { onRead: function(line) { root.handleEnrollLine(line) } }
    onExited: function(exitCode) {
      // A cancelled (SIGTERM'd) run never emits enroll-completed/failed --
      // treat any exit that didn't already reach a terminal event as one.
      // close() cancels a run in flight, so only report into a live panel.
      if (root.opened && !root.enrollTerminal) {
        root.enrollHintText = exitCode === 0 ? root.enrollHintText : "Enrollment stopped."
        root.enrollTerminal = true
        root.enrollSuccess = false
      }
    }
  }

  Process {
    id: toggleProc
    // Re-sync from real PAM state on any exit, success or failure -- a
    // cancelled/failed pkexec may still have partially edited a file.
    onExited: root.refreshToggleStatus()
  }

  // Polls setup-status while a floating-terminal setup/uninstall handoff may
  // still be running, so the panel switches state on its own once the
  // backend's presence changes -- no manual reopen needed.
  Timer {
    id: setupPollTimer
    interval: 3000
    repeat: true
    running: root.handoffPolling
    onTriggered: root.refreshSetupStatus()
  }

  // Belt-and-suspenders: pick up PAM edits made outside this panel (e.g. the
  // user reruns the wizard scripts directly) without waiting on a poll.
  // Same watch pattern as PolkitAgent.qml / lock/Service.qml.
  FileView { path: "/etc/pam.d/sudo"; watchChanges: true; printErrors: false; onFileChanged: root.refreshToggleStatus() }
  FileView { path: "/etc/pam.d/polkit-1"; watchChanges: true; printErrors: false; onFileChanged: root.refreshToggleStatus() }
  FileView { path: "/etc/pam.d/omarchy-lock-fingerprint"; watchChanges: true; printErrors: false; onFileChanged: root.refreshToggleStatus() }

  // ---------- window ----------

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "omarchy-fingerprint"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    // The card wants its content's height, but never more than the screen
    // can show. Whichever surface is actually up decides -- the settings
    // overlay is opened from a short "ready" view and would otherwise be
    // measured against the wrong column. Past the clamp the Flickables take
    // over, so content is scrollable rather than clipped.
    readonly property int desiredContentHeight: root.settingsOpen
      ? settingsColumn.implicitHeight
      : column.implicitHeight
    readonly property int verticalInsets: card.contentTopInset + card.contentBottomInset
    readonly property int maxCardHeight: panel.height - Style.gapsOut * 2
    readonly property int cardHeight: Math.max(
      root.cardPadding * 2,
      Math.min(panel.desiredContentHeight + panel.verticalInsets, panel.maxCardHeight))
    readonly property int cardWidth: Math.min(Style.space(380), panel.width - Style.gapsOut * 2)

    Rectangle {
      anchors.fill: parent
      color: Color.menu.scrim

      MouseArea {
        anchors.fill: parent
        onClicked: root.dismiss()
      }
    }

    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true

      Keys.onEscapePressed: function(event) {
        // Escape backs out one layer at a time: a confirmation, then the
        // settings overlay, then the panel itself.
        if (root.confirmRemoveAllOpen) root.confirmRemoveAllOpen = false
        else if (root.confirmUninstallOpen) root.confirmUninstallOpen = false
        else if (root.settingsOpen) root.settingsOpen = false
        else root.dismiss()
        event.accepted = true
      }

      BorderSurface {
        id: card
        anchors.centerIn: parent
        width: panel.cardWidth
        height: panel.cardHeight
        color: Color.popups.background
        borderSpec: root.borderSpec
        padding: root.cardPadding
        radius: Style.cornerRadius

        // Swallow clicks on the card so they don't reach the scrim's
        // dismissal handler behind it.
        MouseArea {
          anchors.fill: parent
          acceptedButtons: Qt.AllButtons
        }

        Item {
          id: contentHolder
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset

          Flickable {
            id: contentFlick
            anchors.fill: parent
            clip: true
            contentWidth: width
            contentHeight: column.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height

            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
              id: column
              width: contentFlick.width
              spacing: Style.space(14)

              Item {
                width: parent.width
                height: Math.max(headerTitle.implicitHeight, settingsButton.implicitHeight)

                Text {
                  id: headerTitle
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Fingerprint"
                  color: Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                PanelActionButton {
                  id: settingsButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  visible: root.setupState === "ready" && !root.showEnrollFlow
                  iconText: "󰒓"
                  tooltipText: "Settings"
                  foreground: Color.popups.text
                  hoverColor: Color.popups.text
                  fontFamily: Style.font.family
                  onClicked: root.settingsOpen = true
                }
              }

              // ---------- No hardware ----------
              Text {
                visible: root.setupState === "no-hardware"
                text: "No fingerprint reader detected."
                color: Color.muted
                font.family: Style.font.family
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
                width: parent.width
              }

              // ---------- Not installed: hand off to the setup wizard ----------
              Column {
                visible: root.setupState === "not-installed"
                width: parent.width
                spacing: Style.space(10)

                Text {
                  text: root.handoffPolling
                    ? "Setup is running in a terminal window..."
                    : "A fingerprint reader was found, but nothing is set up yet."
                  color: Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                  width: parent.width
                }

                Button {
                  visible: !root.handoffPolling
                  text: "Set up fingerprint authentication"
                  foreground: Color.popups.text
                  fontFamily: Style.font.family
                  bordered: true
                  onClicked: root.startSetup()
                }
              }

              // ---------- Ready: full manager ----------
              Column {
                visible: root.setupState === "ready" && !root.showEnrollFlow
                width: parent.width
                spacing: Style.space(12)

                PanelSectionHeader {
                  text: "ENROLLED FINGERS"
                  foreground: Color.popups.text
                  fontFamily: Style.font.family
                }

                Text {
                  visible: root.deviceError !== ""
                  width: parent.width
                  text: root.deviceError
                  color: Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.WordWrap
                }

                Text {
                  visible: root.deviceError === "" && root.enrolledFingers.length === 0
                  text: "No fingerprints enrolled yet."
                  color: Color.muted
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                }

                Column {
                  width: parent.width
                  spacing: Style.space(2)

                  Repeater {
                    model: root.enrolledFingers
                    FingerRow {
                      required property string modelData
                      width: parent.width
                      foreground: Color.popups.text
                      fontFamily: Style.font.family
                      label: Model.humanLabel(modelData)
                    }
                  }
                }

                Row {
                  spacing: Style.space(8)

                  Button {
                    text: "Add finger"
                    foreground: Color.popups.text
                    fontFamily: Style.font.family
                    bordered: true
                    enabled: root.deviceError === "" && root.availableFingers.length > 0
                    onClicked: { root.showEnrollFlow = true }
                  }

                  Button {
                    text: "Remove all fingerprints"
                    foreground: Color.urgent
                    fontFamily: Style.font.family
                    bordered: true
                    enabled: root.enrolledFingers.length > 0
                    onClicked: root.requestRemoveAll()
                  }
                }
              }

              // ---------- Ready: add-finger flow ----------
              Column {
                visible: root.setupState === "ready" && root.showEnrollFlow
                width: parent.width
                spacing: Style.space(10)

                Button {
                  visible: root.enrollingFinger === ""
                  text: "‹ Back"
                  foreground: Color.popups.text
                  fontFamily: Style.font.family
                  onClicked: { root.showEnrollFlow = false }
                }

                EnrollFlow {
                  width: parent.width
                  foreground: Color.popups.text
                  accent: Color.accent
                  fontFamily: Style.font.family
                  availableFingers: root.availableFingers
                  selectedFinger: root.enrollingFinger
                  enrolling: root.enrollingFinger !== "" && !root.enrollTerminal
                  stage: root.enrollStage
                  totalStages: root.numEnrollStages
                  hintText: root.enrollHintText
                  terminal: root.enrollTerminal
                  success: root.enrollSuccess
                  onFingerPicked: function(fingerName) { root.pickFinger(fingerName) }
                  onCancelRequested: root.cancelEnroll()
                  onDismissRequested: root.dismissEnroll()
                }
              }
            }
          }

          // ---------- Settings: per-task toggles + danger zone ----------
          //
          // Full-bleed overlay, not a sibling card: same reasoning as
          // avila.ultra-docker/Panel.qml's settingsSurface. z:90 so it paints
          // above the main content (z:0) but below the ConfirmDialogs
          // (z:100) -- a confirmation raised from in here (remove-all,
          // uninstall) still has to land on top of it.
          Rectangle {
            id: settingsSurface
            anchors.fill: parent
            z: 90
            color: Color.popups.background
            opacity: root.settingsOpen ? 1 : 0
            visible: opacity > 0
            Behavior on opacity { NumberAnimation { duration: 120 } }

            // An opaque surface that still lets clicks/wheel through to the
            // list underneath is worse than no overlay at all.
            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.AllButtons
              onWheel: function(wheel) { wheel.accepted = true }
            }

            Flickable {
              id: settingsFlick
              anchors.fill: parent
              clip: true
              contentWidth: width
              contentHeight: settingsColumn.implicitHeight
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentHeight > height

              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              Column {
                id: settingsColumn
                width: settingsFlick.width
                spacing: Style.space(14)

                Item {
                  width: parent.width
                  height: Math.max(settingsTitle.implicitHeight, settingsClose.implicitHeight)

                  Text {
                    id: settingsTitle
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Settings"
                    color: Color.popups.text
                    font.family: Style.font.family
                    font.pixelSize: Style.font.title
                    font.bold: true
                  }

                  PanelActionButton {
                    id: settingsClose
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    iconText: "󰅖"
                    tooltipText: "Close"
                    foreground: Color.popups.text
                    hoverColor: Color.popups.text
                    fontFamily: Style.font.family
                    onClicked: root.settingsOpen = false
                  }
                }

                PanelSectionHeader {
                  text: "USE FINGERPRINT FOR"
                  foreground: Color.popups.text
                  fontFamily: Style.font.family
                }

                Column {
                  width: parent.width
                  spacing: Style.space(6)

                  TaskToggleRow {
                    width: parent.width
                    label: "Sudo"
                    foreground: Color.popups.text
                    fontFamily: Style.font.family
                    checked: root.toggleState.sudo
                    busy: !!root.busyToggles.sudo
                    onTogglePressed: root.requestToggle("sudo")
                  }
                  TaskToggleRow {
                    width: parent.width
                    label: "Polkit"
                    description: "System prompts (installs, settings, etc.)"
                    foreground: Color.popups.text
                    fontFamily: Style.font.family
                    checked: root.toggleState.polkit
                    busy: !!root.busyToggles.polkit
                    onTogglePressed: root.requestToggle("polkit")
                  }
                  TaskToggleRow {
                    width: parent.width
                    label: "Lock screen"
                    foreground: Color.popups.text
                    fontFamily: Style.font.family
                    checked: root.toggleState.lock
                    busy: !!root.busyToggles.lock
                    onTogglePressed: root.requestToggle("lock")
                  }
                }

                PanelSeparator { foreground: Color.popups.text }

                Column {
                  width: parent.width
                  spacing: Style.space(6)

                  PanelSectionHeader {
                    text: "DANGER ZONE"
                    foreground: Color.urgent
                    fontFamily: Style.font.family
                  }

                  Text {
                    visible: root.handoffPolling
                    text: "Uninstall is running in a terminal window..."
                    color: Color.muted
                    font.family: Style.font.family
                    font.pixelSize: Style.font.bodySmall
                  }

                  Button {
                    visible: !root.handoffPolling
                    text: "Uninstall fingerprint support"
                    foreground: Color.urgent
                    fontFamily: Style.font.family
                    bordered: true
                    onClicked: root.requestUninstall()
                  }
                }
              }
            }
          }

          ConfirmDialog {
            anchors.fill: parent
            z: 100
            opened: root.confirmRemoveAllOpen
            message: "Remove all fingerprints? There is no per-finger delete — this clears every enrolled finger for your account. You can re-enroll afterward."
            confirmText: "Remove all"
            foreground: Color.popups.text
            onCanceled: root.confirmRemoveAllOpen = false
            onConfirmed: root.confirmRemoveAll()
          }

          ConfirmDialog {
            anchors.fill: parent
            z: 100
            opened: root.confirmUninstallOpen
            message: "Uninstall fingerprint support? This runs the removal wizard in a terminal, undoing sudo/polkit/lock-screen wiring and dropping the packages Omarchy installed."
            confirmText: "Uninstall"
            foreground: Color.popups.text
            onCanceled: root.confirmUninstallOpen = false
            onConfirmed: root.confirmUninstall()
          }
        }
      }
    }
  }
}
