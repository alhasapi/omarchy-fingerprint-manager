import QtQuick
import qs.Commons

// N-dot progress row for an enrollment's num-enroll-stages. `stage` counts
// stages already passed (0..total); dots below that index are filled.
Row {
  id: root

  property int total: 0
  property int stage: 0
  property color foreground: Color.foreground
  property color accent: Color.accent
  property bool failed: false

  spacing: Style.space(8)

  Repeater {
    model: root.total

    Rectangle {
      required property int index
      readonly property bool filled: index < root.stage

      width: Style.space(14)
      height: width
      radius: width / 2
      color: root.failed ? Qt.rgba(Color.urgent.r, Color.urgent.g, Color.urgent.b, filled ? 1.0 : 0.25)
        : filled ? root.accent
        : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

      Behavior on color { ColorAnimation { duration: 150 } }
    }
  }
}
