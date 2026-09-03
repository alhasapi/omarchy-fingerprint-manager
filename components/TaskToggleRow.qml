import QtQuick
import qs.Ui
import qs.Commons

// Thin wrapper around Ui/Toggle.qml for one PAM-gated task (sudo, polkit,
// lock screen). `checked` always reflects real PAM-file state, never an
// optimistic guess -- a pkexec prompt can be cancelled, so Panel.qml only
// flips this after re-reading omarchy-fingerprint-toggle-status. `busy`
// dims the row and swallows clicks while a toggle round-trip is in flight.
Toggle {
  id: root

  property bool busy: false

  signal togglePressed()

  opacity: busy ? 0.55 : 1.0
  Behavior on opacity { NumberAnimation { duration: 120 } }

  onClicked: {
    if (!root.busy) root.togglePressed()
  }
}
