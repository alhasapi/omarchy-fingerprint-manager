import QtQuick
import qs.Commons

// One enrolled finger, read-only. No per-row delete: the fprintd D-Bus API
// (DeleteEnrolledFingers/DeleteEnrolledFingers2) only supports deleting every
// enrolled finger for a user at once -- confirmed from openfprintd's and
// python-validity's own source this session -- so the panel offers a single
// "Remove all fingerprints" action instead of a delete button per row.
Item {
  id: root

  property color foreground: Color.foreground
  property string fontFamily: Style.font.family
  property string label: ""

  implicitHeight: row.implicitHeight + Style.space(14)
  width: parent ? parent.width : implicitWidth

  // Fill on hover, not a border -- same reasoning as ultra-docker's Chip:
  // a static flat row reads as inert, a subtle tint on hover reads as a
  // real row even though there's nothing to click here yet.
  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius > 0 ? Style.space(4) : 0
    color: mouse.containsMouse
      ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
      : "transparent"
    Behavior on color { ColorAnimation { duration: 120 } }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
  }

  Row {
    id: row
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter
    anchors.leftMargin: Style.space(6)
    anchors.rightMargin: Style.space(6)
    spacing: Style.space(10)

    Text {
      text: "󰈷"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.heading
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      text: root.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      anchors.verticalCenter: parent.verticalCenter
    }
  }
}
