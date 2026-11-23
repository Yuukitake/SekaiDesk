import QtQuick

// Leaning ("italic") rounded rectangle ported cleanly from SekaiPop Slant.qml.
// The shear moves top edge right and bottom edge left around the middle line
// while keeping the overall bounding box exactly [0, width].
Item {
    id: root

    property real skew: 0.2
    property real radius: 12
    property color color: "transparent"
    property color borderColor: "transparent"
    property real borderWidth: 0
    property Gradient gradient: null
    property bool useGradient: false
    property color gradFrom: "transparent"
    property color gradTo: "transparent"

    readonly property real lean: skew * height

    Rectangle {
        x: root.lean / 2
        width: Math.max(0, root.width - root.lean)
        height: root.height
        radius: Math.min(root.radius, height / 2)
        color: root.color
        gradient: root.useGradient ? slantGrad : root.gradient
        border.width: root.borderWidth
        border.color: root.borderColor
        antialiasing: true

        Gradient {
            id: slantGrad
            orientation: Gradient.Horizontal
            GradientStop { position: 0.0; color: root.gradFrom }
            GradientStop { position: 1.0; color: root.gradTo }
        }

        transform: Matrix4x4 {
            matrix: Qt.matrix4x4(1, -root.skew, 0, root.skew * root.height / 2,
                                 0, 1, 0, 0,
                                 0, 0, 1, 0,
                                 0, 0, 0, 1)
        }
    }
}
