import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore

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

    // ------------------------------------------------------------ inställningar

    Settings {
        id: settings
        category: "LineDistancePlugin"
        property real heightOffset: 0.0   // läggs till GNSS-höjden (t.ex. ellipsoid -> RH2000)
        property bool cutFill: false      // visa höjd som Cut/Fill i stället för över/under
    }

    Dialog {
        id: settingsDialog
        parent: mainWindow.contentItem
        anchors.centerIn: parent
        modal: true
        title: qsTr("Inställningar")
        standardButtons: Dialog.Ok | Dialog.Cancel

        ColumnLayout {
            width: 300
            spacing: 12

            Label {
                text: qsTr("Höjdoffset (m), läggs till GNSS-höjden")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            TextField {
                id: offsetField
                Layout.fillWidth: true
                inputMethodHints: Qt.ImhFormattedNumbersOnly
                placeholderText: "0,000"
            }
            Label {
                id: antennaLabel
                wrapMode: Text.WordWrap
                color: "#555555"
                font.pixelSize: 13
                Layout.fillWidth: true
            }
            RowLayout {
                Layout.fillWidth: true
                Label {
                    text: qsTr("Visa som Cut/Fill")
                    Layout.fillWidth: true
                }
                Switch {
                    id: cutFillSwitch
                }
            }
        }

        onAboutToShow: {
            antennaLabel.text = plugin.antennaInfo()
            offsetField.text = Geo.fmt(settings.heightOffset, 3)
            cutFillSwitch.checked = settings.cutFill
        }
        onAccepted: {
            const v = parseFloat(offsetField.text.replace(",", "."))
            settings.heightOffset = isNaN(v) ? 0.0 : v
            settings.cutFill = cutFillSwitch.checked
            plugin.update()
        }
    }

    // Antennhöjden ställs in i QFields egna positioneringsinställningar och dras
    // redan av från elevation – pluginet gör ingen egen avdragning.
    function antennaHeightApplied() {
        const positioning = getPositioning()
        const h = positioning ? positioning.antennaHeight : undefined
        return (typeof h === 'number' && isFinite(h)) ? h : 0.0
    }

    function antennaInfo() {
        const h = antennaHeightApplied()
        return h !== 0
            ? qsTr("Antennhöjd ") + Geo.fmt(h, 3) + qsTr(" m dras redan av av QField (positioneringsinställningar).")
            : qsTr("Ingen antennhöjd avdragen. Ställ in den i QFields positioneringsinställningar om GNSS-höjden gäller antennen.")
    }

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
            "z": info.elevationValid ? info.elevation + settings.heightOffset : NaN
        }
    }

    // 1 cm största avvikelse mellan båge och rak sekant, i projektets enhet
    function arcTolerance() {
        return qgisProject.crs.isGeographic === true ? 0.01 / 111320 : 0.01
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

    // Lagren som ritas i kartan just nu (alltså synliga i lagerträdet)
    function visibleLayers() {
        const rendered = mapCanvas.mapSettings.layers
        const out = []
        if (rendered !== undefined && rendered !== null) {
            for (let i = 0; i < rendered.length; i++)
                out.push(rendered[i])
            return out
        }
        const all = projectUtils.mapLayers(qgisProject)
        for (const id in all)
            out.push(all[id])
        return out
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

        let best = null
        for (const layer of visibleLayers()) {
            try {
                const layerRect = geoUtils.reprojectRectangle(rect, qgisProject.crs, layer.crs)
                const it = layerUtils.createFeatureIteratorFromRectangle(layer, layerRect)
                while (it.hasNext()) {
                    const feature = it.next()
                    const projected = geoUtils.reprojectGeometry(feature.geometry, layer.crs, qgisProject.crs)
                    const parsed = Geo.parseWkt(projected.asWkt(9), { "tolerance": arcTolerance() })
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
        property int valueSize: 30
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
            font.pixelSize: parent.valueSize
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
                    text: "⚙"
                    onClicked: settingsDialog.open()
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
                    readonly property bool known: r !== null && isFinite(r.dz)
                    readonly property bool cut: known && r.dz > 0.0005
                    readonly property bool fill: known && r.dz < -0.0005
                    label: settings.cutFill ? (cut ? qsTr("Cut, m") : (fill ? qsTr("Fill, m") : qsTr("Cut/Fill, m"))) : qsTr("Höjd, m")
                    value: {
                        if (!known)
                            return "–"
                        if (settings.cutFill)
                            return Geo.fmt(Math.abs(r.dz))
                        return (r.dz > 0 ? "+" : "") + Geo.fmt(r.dz)
                    }
                    hint: {
                        if (!r)
                            return ""
                        if (!isFinite(r.z))
                            return qsTr("linjen saknar Z")
                        if (!known)
                            return qsTr("ingen GNSS-höjd")
                        if (settings.cutFill)
                            return cut ? qsTr("ta bort material") : (fill ? qsTr("fyll på") : qsTr("i nivå"))
                        return cut ? qsTr("över linjen") : (fill ? qsTr("under linjen") : qsTr("i nivå"))
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                visible: plugin.result !== null
                spacing: 4

                Tile {
                    readonly property var r: plugin.result
                    label: qsTr("Från A, m")
                    value: r ? Geo.fmt(r.fromStart) : "–"
                    hint: r && r.beforeStart ? qsTr("före A") : ""
                    valueSize: 24
                }
                Tile {
                    readonly property var r: plugin.result
                    label: qsTr("Till B, m")
                    value: r ? Geo.fmt(r.toEnd) : "–"
                    hint: r && r.afterEnd ? qsTr("bortom B") : ""
                    valueSize: 24
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
                wrapMode: Text.WordWrap
                color: "#555555"
                font.pixelSize: 13
                text: {
                    const r = plugin.result
                    if (!r)
                        return ""
                    let lines = [qsTr("Segment ") + (r.segIndex + 1) + ": " + Geo.fmt(r.segFromStart, 2) + qsTr(" m från start, ") + Geo.fmt(r.segToEnd, 2) + qsTr(" m till slut")]
                    lines.push(qsTr("Längd ") + Geo.fmt(r.length, 2) + " m   •   " + qsTr("kurs ") + Geo.fmt(r.bearing, 1) + "°")
                    const gz = plugin.position ? plugin.position.z : NaN
                    if (isFinite(gz) || isFinite(r.z))
                        lines.push(qsTr("Höjd: GNSS ") + Geo.fmt(gz, 3) + qsTr(" m, linje ") + Geo.fmt(r.z, 3) + " m")
                    const ah = plugin.antennaHeightApplied()
                    if (ah !== 0 || settings.heightOffset !== 0)
                        lines.push(qsTr("antenn ") + Geo.fmt(ah, 3) + qsTr(" m (QField), offset ") + Geo.fmt(settings.heightOffset, 3) + " m")
                    return lines.join("\n")
                }
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
