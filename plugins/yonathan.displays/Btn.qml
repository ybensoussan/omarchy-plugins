import QtQuick
import qs.Commons
import qs.Ui as Ui

// Omarchy's kit button with this plugin's shorthand: `primary` for the main action, `checked` for
// a toggled/segment-on state (both use the theme's selected fill), `danger` for destructive
// actions (urgent colour), `compact` for inline use. Fills, borders, hover and press all come from
// the theme ([controls] in shell.toml), like every Omarchy panel.
Ui.Button {
  id: button

  property string icon: ""
  property bool primary: false
  property bool danger: false
  property bool checked: false
  property bool compact: false
  property string tooltip: ""

  iconText: icon
  tooltipText: tooltip
  selected: checked || primary
  bordered: true
  foreground: danger ? Color.urgent : Color.menu.text
  accent: danger ? Color.urgent : Color.accent
  fontSize: compact ? Style.font.bodySmall : Style.font.body
  iconSize: compact ? Style.font.body : Style.font.icon
  horizontalPadding: compact ? Style.spacing.md : Style.spacing.controlPaddingX
  verticalPadding: compact ? Style.spacing.xs : Style.spacing.controlPaddingY
  opacity: enabled ? 1 : 0.4
}
