import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The idle ladder as four rows you can step through: how long until the
// screensaver, the lock, the screen going dark, and the machine sleeping.
//
// Steppers rather than dropdowns on purpose. A dropdown inside a layer-shell
// popup has to open a second popup that can outgrow the card it sits in, and
// these values are a curated ladder anyway — there is nothing to search, only
// a rung to move up or down.
//
// Changes save themselves. Each step updates a local draft immediately so the
// number moves under the cursor, then a debounce writes the whole set once
// through omarchy-shell-config; the file is the source of truth again as soon
// as the write settles.
Panel {
  id: root
  moduleName: "evansbee.power-timers"

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel, so everything the bar identifies a panel by has to be that
  // widget: the popout coordinator compares against `slot.activeItem`, and
  // switchPanelFrom looks the slot up the same way.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property bool stayAwake: hostWidget ? hostWidget.stayAwake === true : false

  // Guarded so the panel renders before the bar is injected (the bar-widget
  // contract instantiates it bare).
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property color accentColor: Color.accent
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dimForeground: Qt.darker(contentForeground, 1.45)

  readonly property var stageRows: [
    { key: "screensaver", icon: "󱄄", label: "Screensaver", hint: "dims to the screensaver" },
    { key: "lock",        icon: "",  label: "Lock",        hint: "asks for your password" },
    { key: "screenOff",   icon: "󰍹", label: "Screen off",  hint: "blanks the display" },
    { key: "suspend",     icon: "󰒲", label: "Sleep",       hint: "suspends the machine" }
  ]

  // Row index 4 is the Stay Awake switch, which sits below the ladder because
  // it governs all of it.
  readonly property int lockOnWakeIndex: stageRows.length
  readonly property int stayAwakeIndex: stageRows.length + 1
  property int selectedIndex: 0
  property bool cursorActive: false

  // ---- Draft state. Null means "whatever the file says"; non-null means a
  //      step is in flight and the panel shows the value the user just chose.
  property var draft: null

  readonly property var timers: draft
    ? draft
    : (hostWidget ? hostWidget.timers : Model.defaultTimers())

  readonly property bool orderMixed: Model.outOfOrder(timers)
  readonly property bool lockOnWake: Model.isOn(timers.lockOnWake)
  readonly property bool lockOnWakeUnusable: Model.lockOnWakeUnusable(timers)

  function toggleLockOnWake() {
    var base = timers
    var next = {}
    for (var k in base) next[k] = base[k]
    next.lockOnWake = root.lockOnWake ? 0 : 1
    root.draft = next
    writeDebounce.restart()
    settleTimer.stop()
  }

  function valueFor(key) { return Model.seconds(timers[key]) }
  function labelFor(key) { return Model.formatDuration(timers[key]) }

  function canStep(key, delta) {
    var value = valueFor(key)
    return Model.step(value, delta) !== value
  }

  function adjust(key, delta) {
    if (!canStep(key, delta)) return
    var base = timers
    var next = {}
    for (var k in base) next[k] = base[k]
    next[key] = Model.step(base[key], delta)
    root.draft = next
    writeDebounce.restart()
    settleTimer.stop()
  }

  function moveCursor(delta) {
    cursorActive = true
    var next = selectedIndex + delta
    root.selectedIndex = Math.max(0, Math.min(next, stayAwakeIndex))
  }

  function adjustCursor(delta) {
    if (selectedIndex === lockOnWakeIndex) { toggleLockOnWake(); return }
    if (selectedIndex === stayAwakeIndex) return
    var key = stageRows[selectedIndex].key
    if (key === "lock" && root.lockOnWake) return
    adjust(key, delta)
  }

  function activateCursor() {
    if (selectedIndex === lockOnWakeIndex) { toggleLockOnWake(); return }
    if (selectedIndex !== stayAwakeIndex) return
    if (hostWidget) hostWidget.toggleStayAwake()
  }

  readonly property bool restartPending: hostWidget ? hostWidget.restartPending === true : false

  onOpenedChanged: {
    if (opened) {
      root.cursorActive = false
      root.selectedIndex = 0
      return
    }
    // Closing is the commit point for anything still in flight: flush the
    // debounce, then let the widget restart the shell if Omarchy's own two
    // timeouts changed and need re-registering.
    var pending = root.draft
    writeDebounce.stop()
    if (!root.hostWidget) return
    if (pending) root.hostWidget.writeTimers(pending)
    root.hostWidget.applyPending(pending)
  }

  Timer {
    id: writeDebounce
    // Long enough that holding a stepper down is one write rather than ten,
    // short enough that letting go feels like it saved.
    interval: 450
    repeat: false
    onTriggered: {
      if (!root.draft || !root.hostWidget) return
      root.hostWidget.writeTimers(root.draft)
      settleTimer.restart()
    }
  }

  Timer {
    id: settleTimer
    // Hand authority back to the file once the write has had time to land and
    // come back through the config watcher. If the write failed, the panel
    // snaps to what is actually on disk, which is the honest answer.
    interval: 2500
    repeat: false
    onTriggered: root.draft = null
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        if (dx !== 0) root.adjustCursor(dx)
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        anchors.fill: parent
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: content
          width: scroll.width
          spacing: Style.spacing.lg

          // ---- Header. The ladder as one sentence, so the panel answers
          //      "what happens when I walk away?" before you read a single row.
          Item {
            width: parent.width
            height: titleRow.height

            Row {
              id: titleRow
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.spacing.xxl

              Text {
                anchors.baseline: titleText.baseline
                text: root.stayAwake ? "󰅶" : "󰔟"
                color: root.stayAwake ? root.urgentColor : root.contentForeground
                font.family: root.contentFontFamily
                // Decorative, and deliberately outside the Style.font.* scale:
                // sized to read at the cap height of the title beside it.
                font.pixelSize: Style.space(28)
              }

              Text {
                id: titleText
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                text: "Idle timers"
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.stayAwake
              ? "staying awake — every timer below is paused"
              : Model.summary(root.timers)
            color: root.stayAwake ? root.urgentColor : root.dimForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
          }

          PanelSeparator { foreground: root.contentForeground }

          PanelSectionHeader {
            text: "After you stop touching it"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Repeater {
            model: root.stageRows

            CursorSurface {
              id: stageRow
              required property var modelData
              required property int index

              width: content.width
              height: stageColumn.implicitHeight + Style.spacing.md * 2
              foreground: root.contentForeground
              accent: root.accentColor
              hasCursor: root.cursorActive && root.selectedIndex === stageRow.index
              // Paused rather than disabled: the values still matter, they are
              // just not counting down right now.
              opacity: root.stayAwake ? 0.5 : 1

              readonly property string stageKey: stageRow.modelData.key
              readonly property bool never: Model.isNever(root.valueFor(stageKey))

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
                onEntered: {
                  root.cursorActive = true
                  root.selectedIndex = stageRow.index
                }
                onExited: if (root.selectedIndex === stageRow.index) root.cursorActive = false
              }

              Column {
                id: stageColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.spacing.rowPaddingX
                anchors.rightMargin: Style.spacing.rowPaddingX
                spacing: Style.spacing.xxs

                Item {
                  width: parent.width
                  height: Math.max(stepper.height, nameLabel.implicitHeight)

                  Text {
                    id: stageIcon
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(22)
                    text: stageRow.modelData.icon
                    color: stageRow.never ? root.dimForeground : root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.icon
                  }

                  Text {
                    id: nameLabel
                    textFormat: Text.PlainText
                    anchors.left: stageIcon.right
                    anchors.leftMargin: Style.spacing.md
                    anchors.verticalCenter: parent.verticalCenter
                    text: stageRow.modelData.label
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  // ---- Stepper. Fixed-width value between the two buttons so
                  //      the row does not twitch as "5m" becomes "1h 30m".
                  Row {
                    id: stepper
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.spacing.xs

                    PanelActionButton {
                      iconText: "−"
                      enabled: !root.stayAwake && !(stageRow.stageKey === "lock" && root.lockOnWake)
                        && root.canStep(stageRow.stageKey, -1)
                      foreground: root.contentForeground
                      hoverColor: root.contentForeground
                      fontFamily: root.contentFontFamily
                      // This is a form, so the steppers carry the kit's control
                      // border rather than sitting as bare glyphs the eye has
                      // to be told are clickable.
                      bordered: true
                      tooltipText: "Shorter"
                      onClicked: root.adjust(stageRow.stageKey, -1)
                      onHovered: function(h) {
                        if (!h) return
                        root.cursorActive = true
                        root.selectedIndex = stageRow.index
                      }
                    }

                    Text {
                      textFormat: Text.PlainText
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(62)
                      horizontalAlignment: Text.AlignHCenter
                      text: stageRow.stageKey === "lock" && root.lockOnWake
                        ? "on wake" : root.labelFor(stageRow.stageKey)
                      color: stageRow.never ? root.dimForeground : root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }

                    PanelActionButton {
                      iconText: "+"
                      enabled: !root.stayAwake && !(stageRow.stageKey === "lock" && root.lockOnWake)
                        && root.canStep(stageRow.stageKey, 1)
                      foreground: root.contentForeground
                      hoverColor: root.contentForeground
                      fontFamily: root.contentFontFamily
                      bordered: true
                      tooltipText: "Longer"
                      onClicked: root.adjust(stageRow.stageKey, 1)
                      onHovered: function(h) {
                        if (!h) return
                        root.cursorActive = true
                        root.selectedIndex = stageRow.index
                      }
                    }
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  leftPadding: Style.space(22) + Style.spacing.md
                  elide: Text.ElideRight
                  text: stageRow.stageKey === "lock" && root.lockOnWake
                    ? "asks for your password when you come back"
                    : (stageRow.never ? "never happens" : stageRow.modelData.hint)
                  color: root.dimForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // Stages run on their own clocks from the same idle start, so a lock
          // set shorter than the screensaver simply lands first. Worth saying
          // once; not worth the panel silently rewriting what was asked for.
          Text {
            visible: root.orderMixed
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            leftPadding: Style.spacing.rowPaddingX
            rightPadding: Style.spacing.rowPaddingX
            text: "These fire in time order, not list order — a shorter stage below a longer one happens first."
            color: root.urgentColor
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---- Lock when you return. Omarchy locks on a timer, which means
          //      coming back late shows the lock screen and never the
          //      screensaver. This swaps the timer for the dismissal.
          CursorSurface {
            id: wakeRow
            width: content.width
            height: wakeBody.implicitHeight + Style.spacing.md * 2
            foreground: root.contentForeground
            accent: root.accentColor
            hasCursor: root.cursorActive && root.selectedIndex === root.lockOnWakeIndex

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: {
                root.cursorActive = true
                root.selectedIndex = root.lockOnWakeIndex
              }
              onExited: if (root.selectedIndex === root.lockOnWakeIndex) root.cursorActive = false
              onClicked: root.toggleLockOnWake()
            }

            Item {
              id: wakeBody
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.rowPaddingX
              anchors.rightMargin: Style.spacing.rowPaddingX
              implicitHeight: Math.max(wakeSwitch.height, wakeText.implicitHeight)

              Text {
                id: wakeIcon
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(22)
                text: "󰌾"
                color: root.lockOnWake ? root.contentForeground : root.dimForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.icon
              }

              Column {
                id: wakeText
                anchors.left: wakeIcon.right
                anchors.leftMargin: Style.spacing.md
                anchors.right: wakeSwitch.left
                anchors.rightMargin: Style.spacing.lg
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xxs

                Text {
                  textFormat: Text.PlainText
                  text: "Lock when I come back"
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  wrapMode: Text.WordWrap
                  text: root.lockOnWakeUnusable
                    ? "needs a screensaver — set one above"
                    : "screensaver stays up until you touch it, then asks for the password"
                  color: root.lockOnWakeUnusable ? root.urgentColor : root.dimForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              ToggleSwitch {
                id: wakeSwitch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.lockOnWake
                foreground: root.contentForeground
                accent: root.accentColor
                hasCursor: root.cursorActive && root.selectedIndex === root.lockOnWakeIndex
                onToggled: root.toggleLockOnWake()
              }
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          // ---- Stay Awake. Omarchy's own master switch, kept in the same
          //      panel as the timers it pauses rather than a menu away.
          CursorSurface {
            id: awakeRow
            width: content.width
            height: awakeColumn.implicitHeight + Style.spacing.md * 2
            foreground: root.contentForeground
            accent: root.accentColor
            hasCursor: root.cursorActive && root.selectedIndex === root.stayAwakeIndex

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: {
                root.cursorActive = true
                root.selectedIndex = root.stayAwakeIndex
              }
              onExited: if (root.selectedIndex === root.stayAwakeIndex) root.cursorActive = false
              onClicked: if (root.hostWidget) root.hostWidget.toggleStayAwake()
            }

            Item {
              id: awakeColumn
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.spacing.rowPaddingX
              anchors.rightMargin: Style.spacing.rowPaddingX
              implicitHeight: Math.max(awakeSwitch.height, awakeText.implicitHeight)

              Text {
                id: awakeIcon
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(22)
                text: "󰅶"
                color: root.stayAwake ? root.urgentColor : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.icon
              }

              Column {
                id: awakeText
                anchors.left: awakeIcon.right
                anchors.leftMargin: Style.spacing.md
                anchors.right: awakeSwitch.left
                anchors.rightMargin: Style.spacing.lg
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xxs

                Text {
                  textFormat: Text.PlainText
                  text: "Stay awake"
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  elide: Text.ElideRight
                  text: "holds off every stage above"
                  color: root.dimForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              ToggleSwitch {
                id: awakeSwitch
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                checked: root.stayAwake
                foreground: root.contentForeground
                accent: root.accentColor
                hasCursor: root.cursorActive && root.selectedIndex === root.stayAwakeIndex
                onToggled: if (root.hostWidget) root.hostWidget.toggleStayAwake()
              }
            }
          }

          PanelSeparator { foreground: root.contentForeground }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.restartPending
              ? "j/k move · h/l adjust · saved automatically\nscreensaver and lock apply when you close this panel"
              : "j/k move · h/l adjust · saved automatically\nright-click the bar icon to toggle stay awake"
            color: Qt.darker(root.contentForeground, 1.6)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }
}
