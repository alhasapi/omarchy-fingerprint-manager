// Pure helpers for the fingerprint panel: finger-name <-> label, JSON-line
// parsing, and enroll/verify result -> human hint text. Kept free of QML
// bindings so it can be unit-reasoned-about independently of Panel.qml,
// matching the Model.js convention used by the bluetooth/power panels.

// The ten canonical fprintd/libfprint finger names, confirmed live this
// session from python-validity's own finger_ids table
// (validitysensor/fingerprint_constants.py), which cites
// https://fprint.freedesktop.org/fprintd-dev/Device.html#fingerprint-names.
var FINGER_NAMES = [
  "left-thumb", "left-index-finger", "left-middle-finger",
  "left-ring-finger", "left-little-finger",
  "right-thumb", "right-index-finger", "right-middle-finger",
  "right-ring-finger", "right-little-finger"
]

var FINGER_LABELS = {
  "left-thumb": "Left Thumb",
  "left-index-finger": "Left Index Finger",
  "left-middle-finger": "Left Middle Finger",
  "left-ring-finger": "Left Ring Finger",
  "left-little-finger": "Left Little Finger",
  "right-thumb": "Right Thumb",
  "right-index-finger": "Right Index Finger",
  "right-middle-finger": "Right Middle Finger",
  "right-ring-finger": "Right Ring Finger",
  "right-little-finger": "Right Little Finger"
}

function humanLabel(fingerName) {
  return FINGER_LABELS[fingerName] || String(fingerName || "")
}

// Short instructional hint per EnrollStatus result string, shown under the
// stage dots while a finger is being added.
var ENROLL_HINTS = {
  "enroll-completed": "Done!",
  "enroll-failed": "Enrollment failed. Try again.",
  "enroll-stage-passed": "Good — keep going.",
  "enroll-retry-scan": "Scan again.",
  "enroll-swipe-too-short": "Swipe more slowly.",
  "enroll-finger-not-centered": "Center your finger on the sensor.",
  "enroll-remove-and-retry": "Lift your finger and try again.",
  "enroll-data-full": "No space left for another fingerprint.",
  "enroll-disconnected": "Reader disconnected.",
  "enroll-unknown-error": "Something went wrong."
}

function enrollHint(resultEvent) {
  return ENROLL_HINTS[resultEvent] || "Touch the sensor."
}

function isEnrollTerminal(resultEvent) {
  return resultEvent === "enroll-completed" || resultEvent === "enroll-failed"
    || resultEvent === "enroll-data-full" || resultEvent === "enroll-disconnected"
    || resultEvent === "enroll-unknown-error"
}

// Parses one JSON line from any of the plugin's bin/ scripts. Returns null
// on anything that isn't valid JSON -- callers should tolerate a torn or
// partial line rather than crash, same convention as the notifications
// panel's line parsing.
function parseLine(line) {
  var text = String(line || "").trim()
  if (text === "") return null
  try {
    return JSON.parse(text)
  } catch (e) {
    return null
  }
}

// Fingers not yet enrolled, in a fixed left-then-right, thumb-to-little
// order, for the add-finger picker.
function availableFingers(enrolledFingers) {
  var enrolled = {}
  for (var i = 0; i < enrolledFingers.length; i++) enrolled[enrolledFingers[i]] = true

  var result = []
  for (var j = 0; j < FINGER_NAMES.length; j++) {
    if (!enrolled[FINGER_NAMES[j]]) result.push(FINGER_NAMES[j])
  }
  return result
}
