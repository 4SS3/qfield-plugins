import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import org.qfield
import org.qgis
import Theme

import "geometry.js" as Geo

// Linjeavstånd – visar vinkelrätt avstånd, avstånd längs linjen och höjdskillnad
// till en vald linje eller polygon, uppdaterat live från GNSS-positionen.
Item {
    id: plugin

    readonly property string handlerName: "line_distance_picker"
    readonly property int pickTolerancePx: 30

    property var mainWindow: iface.mainWindow()
    property var mapCanvas: iface.mapCanvas()

    // Klass-namn skiljer sig mellan QField-versioner (Qf-prefix på nyare)
    readonly property var geoUtils: typeof QfGeometryUtils !== 'undefined' ? QfGeometryUtils : GeometryUtils
    readonly property var crsUtils: typeof QfCoordinateReferenceSystemUtils !== 'undefined' ? QfCoordinateReferenceSystemUtils : CoordinateReferenceSystemUtils
    readonly property var layerUtils: typeof QfLayerUtils !== 'undefined' ? QfLayerUtils : LayerUtils
    readonly property var projectUtils: typeof QfProjectUtils !== 'undefined' ? QfProjectUtils : ProjectUtils
    readonly property var featureUtils: typeof QfFeatureUtils !== 'undefined' ? QfFeatureUtils : FeatureUtils

    // Tillstånd
    property bool panelOpen: false
    property bool picking: false
    property bool reversed: false
    property var geom: null            // tolkad geometri i projektets CRS
    property string featureLabel: ""
    property var result: null
    property var position: null        // {x, y, z} i projektets CRS
    property string status: ""

    // ------------------------------------------------------------ position

    function getPositioning() {
        if (typeof iface.positioning === 'function')
            return iface.positioning()
        return iface.findItemByObjectName('positionSource')
    }

    function currentPosition() {
        const positioning = getPositioning()
        if (!positioning || !positioning.active)
            return null
        const info = positioning.positionInformation
        if (!info || !info.latitudeValid || !info.longitudeValid)
            return null
        const pt = geoUtils.reprojectPoint(geoUtils.point(info.longitude, info.latitude), crsUtils.wgs84Crs(), qgisProject.crs)
        return {
            "x": pt.x,
            "y": pt.y,
            "z": info.elevationValid ? info.elevation : NaN
        }
    }

    function analysisOptions() {
        return {
            "reverse": plugin.reversed,
            "geographic": qgisProject.crs.isGeographic === true
        }
    }

    function update() {
        plugin.position = currentPosition()
        if (!plugin.geom) {
            plugin.result = null
            plugin.status = qsTr("Tryck på ⌖ och peka på en linje eller polygon i kartan.")
        } else if (!plugin.position) {
            plugin.result = null
            plugin.status = qsTr("Väntar på GNSS-position …")
        } else {
            plugin.result = Geo.analyze(plugin.geom, plugin.position, analysisOptions())
            plugin.status = ""
        }
        overlay.requestPaint()
    }

    Connections {
        target: getPositioning()
        ignoreUnknownSignals: true
        function onPositionInformationChanged() {
            if (plugin.panelOpen)
                plugin.update()
        }
    }

    // ------------------------------------------------------------ val av linje

    function displayName(layer, feature) {
        try {
            const n = featureUtils.displayName(layer, feature)
            if (n)
                return layer.name + " – " + n
        } catch (e) {}
        return layer.name + " #" + feature.id
    }

    function pickAt(screenPoint) {
        const ms = mapCanvas.mapSettings
        const tol = plugin.pickTolerancePx
        const tl = ms.screenToCoordinate(Qt.point(screenPoint.x - tol, screenPoint.y - tol))
        const br = ms.screenToCoordinate(Qt.point(screenPoint.x + tol, screenPoint.y + tol))
        const centre = ms.screenToCoordinate(Qt.point(screenPoint.x, screenPoint.y))
        const rect = geoUtils.createRectangleFromPoints(tl, br)
        const probe = {
            "x": centre.x,
            "y": centre.y,
            "z": NaN
        }
        const opts = {
            "reverse": false,
            "geographic": qgisProject.crs.isGeographic === true
        }

        const layers = projectUtils.mapLayers(qgisProject)
        let best = null
        for (const id in layers) {
            const layer = layers[id]
            try {
                const layerRect = geoUtils.reprojectRectangle(rect, qgisProject.crs, layer.crs)
                const it = layerUtils.createFeatureIteratorFromRectangle(layer, layerRect)
                while (it.hasNext()) {
                    const feature = it.next()
                    const projected = geoUtils.reprojectGeometry(feature.geometry, layer.crs, qgisProject.crs)
                    const parsed = Geo.parseWkt(projected.asWkt(9))
                    if (!parsed)
                        continue
                    const a = Geo.analyze(parsed, probe, opts)
                    if (a && (best === null || a.dist < best.dist))
                        best = {
                            "dist": a.dist,
                            "geom": parsed,
                            "label": displayName(layer, feature)
                        }
                }
                it.close()
            } catch (e) {
                // rasterlager, lager utan geometri m.m. hoppas över
            }
        }
        return best
    }

    function startPicking() {
        const handler = iface.findItemByObjectName("pointHandler")
        if (!handler) {
            mainWindow.displayToast(qsTr("Kunde inte hitta kartans klick-hanterare"))
            return
        }
        plugin.picking = true
        mainWindow.displayToast(qsTr("Peka på en linje eller polygon i kartan"))
        handler.registerHandler(plugin.handlerName, function (point, type, interactionType) {
            if (interactionType !== "clicked")
                return false
            stopPicking()
            const hit = pickAt(point)
            if (hit) {
                plugin.geom = hit.geom
                plugin.featureLabel = hit.label
                plugin.reversed = false
                plugin.update()
            } else {
                mainWindow.displayToast(qsTr("Ingen linje eller polygon nära där du pekade"))
            }
            return true
        }, 100)
    }

    function stopPicking() {
        plugin.picking = false
        const handler = iface.findItemByObjectName("pointHandler")
        if (handler)
            handler.deregisterHandler(plugin.handlerName)
    }

    function clearSelection() {
        plugin.geom = null
        plugin.featureLabel = ""
        plugin.reversed = false
        update()
    }

    function openPanel() {
        plugin.panelOpen = true
        update()
    }

    function closePanel() {
        stopPicking()
        plugin.panelOpen = false
        overlay.requestPaint()
    }

    // ------------------------------------------------------------ verktygsknapp

    QfToolButton {
        id: pluginButton
        iconSource: 'icon.svg'
        iconColor: Theme.mainColor
        bgcolor: Theme.darkGray
        round: true
        onClicked: plugin.panelOpen ? plugin.closePanel() : plugin.openPanel()
    }

    // ------------------------------------------------------------ kartöverlägg

    // Streckad linje från positionen till närmaste punkt på linjen
    Canvas {
        id: overlay
        parent: mainWindow.contentItem
        anchors.fill: parent
        visible: plugin.panelOpen
        z: 1

        onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            if (!plugin.panelOpen || !plugin.result || !plugin.position)
                return
            const ms = plugin.mapCanvas.mapSettings
            const from = ms.coordinateToScreen(geoUtils.point(plugin.position.x, plugin.position.y))
            const to = ms.coordinateToScreen(geoUtils.point(plugin.result.foot.x, plugin.result.foot.y))
            ctx.strokeStyle = "#e53935"
            ctx.fillStyle = "#e53935"
            ctx.lineWidth = 3
            ctx.setLineDash([10, 8])
            ctx.beginPath()
            ctx.moveTo(from.x, from.y)
            ctx.lineTo(to.x, to.y)
            ctx.stroke()
            ctx.setLineDash([])
            ctx.beginPath()
            ctx.arc(to.x, to.y, 8, 0, 2 * Math.PI)
            ctx.fill()
            ctx.lineWidth = 2
            ctx.strokeStyle = "white"
            ctx.stroke()
        }
    }

    // Reservuppdatering om positioneringsobjektet inte fanns när pluginet laddades
    Timer {
        interval: 1000
        repeat: true
        running: plugin.panelOpen
        onTriggered: plugin.update()
    }

    // Kartan kan panoreras/zoomas utan att positionen ändras
    Timer {
        interval: 250
        repeat: true
        running: plugin.panelOpen && plugin.result !== null
        onTriggered: overlay.requestPaint()
    }

    // ------------------------------------------------------------ panel

    component Tile: ColumnLayout {
        property string label
        property string value
        property string hint
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        spacing: 0
        Label {
            text: parent.label
            color: "#555555"
            font.pixelSize: 14
            Layout.alignment: Qt.AlignHCenter
        }
        Label {
            text: parent.value
            color: "#111111"
            font.pixelSize: 30
            font.bold: true
            Layout.alignment: Qt.AlignHCenter
        }
        Label {
            text: parent.hint
            color: "#555555"
            font.pixelSize: 13
            Layout.alignment: Qt.AlignHCenter
        }
    }

    Rectangle {
        id: panel
        parent: mainWindow.contentItem
        visible: plugin.panelOpen
        z: 2
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 8
        anchors.topMargin: 64
        height: content.implicitHeight + 16
        radius: 12
        color: "white"
        border.color: "#cccccc"

        ColumnLayout {
            id: content
            anchors.fill: parent
            anchors.margins: 8
            spacing: 6

            RowLayout {
                Layout.fillWidth: true
                Button {
                    text: plugin.picking ? qsTr("Avbryt val") : qsTr("⌖ Välj")
                    onClicked: plugin.picking ? plugin.stopPicking() : plugin.startPicking()
                }
                Button {
                    text: qsTr("⇅ Vänd")
                    enabled: plugin.geom !== null
                    onClicked: {
                        plugin.reversed = !plugin.reversed
                        plugin.update()
                    }
                }
                Button {
                    text: qsTr("Rensa")
                    enabled: plugin.geom !== null
                    onClicked: plugin.clearSelection()
                }
                Item {
                    Layout.fillWidth: true
                }
                Button {
                    text: "✕"
                    onClicked: plugin.closePanel()
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: plugin.result !== null
                spacing: 4

                Tile {
                    readonly property var r: plugin.result
                    label: qsTr("Till B, m")
                    value: r ? Geo.fmt(r.toEnd) : "–"
                    hint: r && r.afterEnd ? qsTr("bortom B") : qsTr("från A: ") + (r ? Geo.fmt(r.fromStart, 2) : "–")
                }
                Tile {
                    readonly property var r: plugin.result
                    label: r && r.kind === "polygon" ? qsTr("Till kant, m") : qsTr("Offset, m")
                    value: r ? Geo.fmt(Math.abs(r.offset)) : "–"
                    hint: {
                        if (!r)
                            return ""
                        if (r.kind === "polygon")
                            return r.inside ? qsTr("innanför") : qsTr("utanför")
                        if (r.dist < 0.0005)
                            return qsTr("på linjen")
                        return r.offset > 0 ? qsTr("höger →") : qsTr("← vänster")
                    }
                }
                Tile {
                    readonly property var r: plugin.result
                    label: qsTr("Höjd, m")
                    value: r && isFinite(r.dz) ? (r.dz > 0 ? "+" : "") + Geo.fmt(r.dz) : "–"
                    hint: {
                        if (!r || !isFinite(r.dz))
                            return r && !isFinite(r.z) ? qsTr("linjen saknar Z") : qsTr("ingen höjd")
                        return r.dz > 0.0005 ? qsTr("över") : (r.dz < -0.0005 ? qsTr("under") : qsTr("i nivå"))
                    }
                }
            }

            Label {
                Layout.fillWidth: true
                text: plugin.featureLabel
                visible: plugin.featureLabel !== ""
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideMiddle
                color: "#111111"
                font.pixelSize: 16
                font.bold: true
            }

            Label {
                Layout.fillWidth: true
                text: plugin.status
                visible: plugin.status !== ""
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                color: "#555555"
            }

            Label {
                Layout.fillWidth: true
                visible: plugin.result !== null
                horizontalAlignment: Text.AlignHCenter
                color: "#555555"
                font.pixelSize: 13
                text: plugin.result ? qsTr("Längd ") + Geo.fmt(plugin.result.length, 2) + " m   •   " + qsTr("kurs ") + Geo.fmt(plugin.result.bearing, 1) + "°" : ""
            }
        }
    }

    Component.onCompleted: {
        iface.addItemToPluginsToolbar(pluginButton)
    }

    Component.onDestruction: {
        stopPicking()
    }
}
