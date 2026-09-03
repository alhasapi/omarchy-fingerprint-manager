import QtQuick
import qs.Ui
import qs.Commons
import "../Model.js" as Model

// In-panel add-finger flow: pick an unenrolled finger, then watch live
// per-stage progress streamed from bin/omarchy-fprintd-enroll. Panel.qml
// owns the actual Process and passes state down; this component is
// presentational plus the picker/cancel/done click wiring.
Column {
  id: root

  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family

  property var availableFingers: []
  property string selectedFinger: ""
  property bool enrolling: false
  property int stage: 0
  property int totalStages: 0
  property string hintText: ""
  property bool terminal: false
  property bool success: false

  signal fingerPicked(string fingerName)
  signal cancelRequested()
  signal dismissRequested()

  spacing: Style.space(14)
  width: parent ? parent.width : implicitWidth

  // ---------- Picker: choose which finger to enroll ----------
  Column {
    visible: root.selectedFinger === ""
    width: parent.width
    spacing: Style.space(8)

    PanelSectionHeader {
      text: "ADD A FINGER"
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Text {
      visible: root.availableFingers.length === 0
      text: "All ten fingers are already enrolled."
      color: Qt.darker(root.foreground, 1.5)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
      width: parent.width
    }

    Flow {
      width: parent.width
      spacing: Style.space(6)

      Repeater {
        model: root.availableFingers

        Button {
          required property string modelData
          text: Model.humanLabel(modelData)
          fontSize: Style.font.bodySmall
          foreground: root.foreground
          accent: root.accent
          fontFamily: root.fontFamily
          bordered: true
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          onClicked: root.fingerPicked(modelData)
        }
      }
    }
  }

  // ---------- In-progress / terminal: scan feedback ----------
  Column {
    visible: root.selectedFinger !== ""
    width: parent.width
    spacing: Style.space(14)

    Text {
      text: Model.humanLabel(root.selectedFinger)
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
    }

    StagesIndicator {
      total: root.totalStages
      stage: root.stage
      foreground: root.foreground
      accent: root.accent
      failed: root.terminal && !root.success
    }

    Text {
      text: root.hintText
      color: root.terminal && !root.success ? Color.urgent : root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
      width: parent.width
    }

    Row {
      spacing: Style.space(8)

      Button {
        visible: !root.terminal
        text: "Cancel"
        fontSize: Style.font.bodySmall
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        bordered: true
        onClicked: root.cancelRequested()
      }

      Button {
        visible: root.terminal
        text: root.success ? "Done" : "Try again"
        fontSize: Style.font.bodySmall
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        bordered: true
        onClicked: root.dismissRequested()
      }
    }
  }
}
