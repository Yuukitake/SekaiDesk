import QtQuick

// SekaiPop-faithful leaning keycap tile for Landscape Settings Hub:
// hard drop shadow -> navy outline -> white inner ring -> idle surface +
// left-to-right active-band accent wipe on hover -> OutBack spring press.
Item {
    id: root

    property color wipeFrom: "#00FFCB"
    property color wipeTo: "#04FEEE"
    property bool darkMode: false

    readonly property color surfaceColor: darkMode ? "#1C2136" : "#FFFFFF"
    readonly property color tileBorderColor: darkMode ? "#384166" : "#1A1B2E"
    readonly property color titleColor: darkMode ? "#F1F5F9" : "#1A1B2E"
    readonly property color subColor: darkMode ? "#94A3B8" : "#475569"

    property string num: "01"
    property string title: ""
    property string subtitle: ""
    property string iconSource: ""
    property color accent: "#06B6D4"
    property var stripeColors: ["#F43F5E", "#F59E0B", "#8B5CF6"]

    property real tileW: 404
    property real tileH: 271
    property real skew: 0.08

    signal clicked()

    readonly property bool hovered: hitArea.containsMouse
    readonly property bool pressed: hitArea.pressed

    property real litP: hovered ? 1.0 : 0.0
    Behavior on litP {
        NumberAnimation {
            duration: 220
            easing.type: Easing.OutCubic
        }
    }

    readonly property real borderW: 4.0 + 0.5 * litP
    readonly property real ringInset: borderW + 7.0 * litP
    readonly property real shadowDx: 6.0 + 3.0 * litP
    readonly property real shadowDy: 5.0 + 2.0 * litP

    function insetX(t) {
        return t * (1.02 + root.skew)
    }

    implicitWidth: tileW + 10
    implicitHeight: tileH + 8
    width: tileW
    height: tileH

    // 1. Hard slanted drop shadow
    SekaiSlant {
        x: root.shadowDx
        y: root.shadowDy
        width: root.tileW
        height: root.tileH
        skew: root.skew
        radius: 38
        color: "#1A1B2E"
    }

    // 2. Lifting / pressing cap surface
    Item {
        id: surface

        width: root.tileW
        height: root.tileH
        x: root.pressed ? root.shadowDx : (-1.5 * root.litP)
        y: root.pressed ? root.shadowDy : (-1.5 * root.litP)

        Behavior on x {
            NumberAnimation {
                duration: root.pressed ? 75 : 260
                easing.type: root.pressed ? Easing.OutQuad : Easing.OutBack
                easing.overshoot: root.pressed ? 0 : 2.2
            }
        }
        Behavior on y {
            NumberAnimation {
                duration: root.pressed ? 75 : 260
                easing.type: root.pressed ? Easing.OutQuad : Easing.OutBack
                easing.overshoot: root.pressed ? 0 : 2.2
            }
        }

        // Navy outline + inner ring
        SekaiSlant {
            anchors.fill: parent
            skew: root.skew
            radius: 38
            color: root.surfaceColor
            borderColor: root.litP > 0.5 ? (root.darkMode ? "#FB923C" : "#EA580C") : root.tileBorderColor
            borderWidth: root.borderW
        }

        // Idle fill inside ring
        SekaiSlant {
            readonly property real fx: root.insetX(root.ringInset)
            x: fx
            y: root.ringInset
            width: Math.max(0, root.tileW - 2 * fx)
            height: Math.max(0, root.tileH - 2 * root.ringInset)
            skew: root.skew
            radius: Math.max(0, 38 - root.ringInset)
            color: root.surfaceColor
        }

        // Left-to-right warm highlight wipe on hover
        SekaiSlant {
            readonly property real fx: root.insetX(root.ringInset)
            visible: root.litP > 0.01
            x: fx
            y: root.ringInset
            width: Math.max(0, (root.tileW - 2 * fx) * root.litP)
            height: Math.max(0, root.tileH - 2 * root.ringInset)
            skew: root.skew
            radius: Math.max(0, 38 - root.ringInset)
            color: root.darkMode
                ? Qt.rgba(251 / 255, 146 / 255, 60 / 255, 0.14)
                : Qt.rgba(249 / 255, 115 / 255, 22 / 255, 0.12)
        }

        // Sheared content matching plate lean
        Item {
            width: root.tileW
            height: root.tileH

            transform: Matrix4x4 {
                matrix: Qt.matrix4x4(1, -root.skew, 0, root.skew * root.tileH / 2,
                                     0, 1, 0, 0,
                                     0, 0, 1, 0,
                                     0, 0, 0, 1)
            }

            // Big corner number watermark
            Text {
                x: root.tileW - implicitWidth - 40
                y: 14
                text: root.num
                font.family: "Segoe UI"
                font.pixelSize: 66
                font.weight: Font.Black
                color: root.litP > 0.5
                    ? Qt.rgba(251 / 255, 146 / 255, 60 / 255, 0.30)
                    : (root.darkMode
                        ? Qt.rgba(241 / 255, 245 / 255, 249 / 255, 0.14)
                        : Qt.rgba(26 / 255, 27 / 255, 46 / 255, 0.14))
            }

            // 45-deg colored diamond badge
            Rectangle {
                x: 52
                y: 54
                width: 64
                height: 64
                radius: 18
                rotation: 45
                scale: 1.0 + 0.08 * root.litP
                color: root.accent
                border.width: 4
                border.color: "#1A1B2E"
                antialiasing: true
            }

            // Upright SVG icon centered on diamond (84, 86)
            Image {
                x: 84 - width * 0.5
                y: 86 - height * 0.5
                width: 34
                height: 34
                sourceSize.width: 68
                sourceSize.height: 68
                scale: 1.0 + 0.08 * root.litP
                source: root.iconSource
                fillMode: Image.PreserveAspectFit
                smooth: true
            }

            // 3 slanted color stripes
            Repeater {
                model: 3
                delegate: SekaiSlant {
                    required property int index
                    x: root.tileW - 126 + index * 24
                    y: 112
                    width: 28
                    height: 24
                    skew: 0.55
                    radius: 3
                    color: root.stripeColors && root.stripeColors.length > 0
                           ? root.stripeColors[index % root.stripeColors.length]
                           : root.accent
                }
            }

            // Title & subtitle
            Text {
                x: 38
                y: root.tileH - 104
                width: root.tileW - 76
                elide: Text.ElideRight
                text: root.title
                font.family: "Segoe UI"
                font.pixelSize: 34
                font.weight: Font.Black
                color: root.litP > 0.5 ? (root.darkMode ? "#FB923C" : "#EA580C") : root.titleColor
            }

            Text {
                x: 38
                y: root.tileH - 56
                width: root.tileW - 76
                elide: Text.ElideRight
                text: root.subtitle
                font.family: "Segoe UI"
                font.pixelSize: 18
                font.weight: Font.DemiBold
                color: root.litP > 0.5 ? (root.darkMode ? "#FDBA74" : "#C2410C") : root.subColor
            }
        }
    }

    MouseArea {
        id: hitArea
        x: 0
        y: 0
        width: root.tileW
        height: root.tileH
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.clicked()
    }
}
