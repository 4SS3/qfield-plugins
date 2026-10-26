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
    // Föräldern för det plugin ritar på kartan: som barn till kartan hamnar det
    // under QFields egna menyer och dialoger
    readonly property var mapLayer: mapCanvas ? mapCanvas : mainWindow.contentItem

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
    property var geom: null            // tolkad linje/polygon i projektets CRS
    property var target: null          // vald målpunkt {x, y, z} (punkt eller brytpunkt)
    property string pickMode: "normal" // "normal" eller "vertex"
    readonly property bool hasSelection: geom !== null || target !== null
    property string featureLabel: ""
    property var result: null
    property string featureKey: ""    // identifierar den valda geometrin (lager#id)
    property var lockedSeg: null      // {pathIndex, segIndex} i riktningen A -> B, null = automatiskt
    property var position: null       // {x, y, z} i projektets CRS
    property string status: ""
    property bool dialActive: false   // precisionsvyn visas
    property var fix: null            // {text, level, ...} från GNSS-kvalitet, se fixInfo()

    // Avstånd längs referensen. Med låst segment är segmentet referensen (A = dess
    // start, B = dess slut), annars hela linjen. Negativt = utanför ändpunkten.
    // För en målpunkt visas i stället östlig/nordlig förskjutning (positivt = målet ligger åt öster/norr).
    readonly property bool isPoint: result !== null && result.kind === "point"
    readonly property real abA: !result ? NaN : (isPoint ? result.dE : (lockedSeg ? result.segFromStart : result.fromStart))
    readonly property real abB: !result ? NaN : (isPoint ? result.dN : (lockedSeg ? result.segToEnd : result.toEnd))
    // Negativt längs linjen = utanför ändpunkten (rött); för en målpunkt är tecknet bara riktning
    function abColor(v) {
        return !isPoint && v < -0.0005 ? "#d32f2f" : "#111111"
    }

    property bool moveMode: false        // true medan knappen flyttas

    readonly property bool landscape: !!(mapCanvas && mapCanvas.width > mapCanvas.height)
    readonly property real fracX: landscape ? settings.landX : settings.portX
    readonly property real fracY: landscape ? settings.landY : settings.portY
    readonly property bool useFloat: fracX >= 0 && fracY >= 0
    readonly property var activeButton: useFloat ? floatButton : pluginButton
    onUseFloatChanged: applyFloatPos()
    onLandscapeChanged: applyFloatPos()

    // Engelska är källspråk och reserv. Andra språk läggs till som en egen post
    // i translations (språkkoden är de två första tecknen i Qt.locale().name).
    readonly property string lang: String(Qt.locale().name).substring(0, 2)
    readonly property var translations: ({
      "sv": {
        "⌖ Pick": "⌖ Välj",
        "⇅ Reverse line": "⇅ Vänd linje",
        "Clear selection": "Rensa val",
        "Settings": "Inställningar",
        "Automatic segment": "Automatiskt segment",
        "Move button": "Flytta knapp",
        "Button position reset": "Knappens plats återställd",
        "Drag the button, tap it when done. Long press resets.": "Dra knappen, tryck på den när du är klar. Långt tryck återställer.",
        "Segment locked": "Segment låst",
        "Segment": "Segment",
        "locked": "låst",
        "From A, m": "Från A, m",
        "To B, m": "Till B, m",
        "Offset, m": "Offset, m",
        "To edge, m": "Till kant, m",
        "inside": "innanför",
        "outside": "utanför",
        "on the line": "på linjen",
        "right →": "höger →",
        "← left": "← vänster",
        "Cut/Fill, m": "Kap/Fyll, m",
        "Cut, m": "Kap, m",
        "Fill, m": "Fyll, m",
        "remove material": "ta bort material",
        "add material": "fyll på",
        "at level": "i nivå",
        "Waiting for GNSS position …": "Väntar på GNSS-position …",
        "Could not find the map click handler": "Kunde inte hitta kartans klick-hanterare",
        "Tap a line, polygon or point on the map": "Peka på en linje, polygon eller punkt i kartan",
        "Tap a vertex or point on the map": "Peka på en brytpunkt eller punkt i kartan",
        "Nothing to select near where you tapped": "Inget att välja nära där du pekade",
        "⌖ Pick vertex": "⌖ Välj brytpunkt",
        "Distance, m": "Avstånd, m",
        "East, m": "Öst, m",
        "North, m": "Nord, m",
        "at the point": "på punkten",
        "Point": "Punkt",
        "Vertex": "Brytpunkt",
        "Height offset (m), added to the correct height": "Höjdoffset (m), läggs till den korrekta höjden",
        "Height offset": "Höjdoffset",
        "Precise view": "Precisionsvy",
        "Auto": "Auto",
        "Always": "Alltid",
        "Off": "Av",
        "Show precise view within (m)": "Visa precisionsvy inom (m)",
        "Arrival tolerance (m)": "Ankomsttolerans (m)",
        "Line": "Linje",
        "No fix": "Ingen fix",
        "RTK fixed": "RTK fix",
        "RTK float": "RTK float"
      }
    })
    function t(s) {
        const dict = translations[lang]
        return (dict !== undefined && dict[s] !== undefined) ? dict[s] : s
    }

    // ------------------------------------------------------------ inställningar

    Settings {
        id: settings
        category: "LineDistancePlugin"
        property real heightOffset: 0.0   // läggs till GNSS-höjden (t.ex. ellipsoid -> RH2000)
        property string dialMode: "auto"  // precisionsvy: "auto" (nära målet), "always" eller "off"
        property real dialThreshold: 3.0  // m: visa precisionsvyn när målet är närmare än så
        property real arrivalTol: 0.05    // m: målet räknas som nått inom detta avstånd
        // Knappens egen placering på kartan som andel av kartans storlek (-1 = i verktygsfältet)
        property real portX: -1
        property real portY: -1
        property real landX: -1
        property real landY: -1
    }

    Dialog {
        id: settingsDialog
        parent: mainWindow.contentItem
        anchors.centerIn: parent
        modal: true
        title: t("Settings")
        // Smal dialog som alltid ryms på skärmen; innehållet fyller bredden och
        // går att rulla när skärmen är för låg (liggande)
        width: Math.min(parent.width - 48, 400)
        height: Math.min(implicitHeight, parent.height - 24)

        standardButtons: Dialog.Ok | Dialog.Cancel

        readonly property var dialModes: ["auto", "always", "off"]

        contentItem: Flickable {
            id: settingsFlick
            implicitHeight: settingsCol.implicitHeight
            contentHeight: settingsCol.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            ScrollBar.vertical: ScrollBar {}

            ColumnLayout {
                id: settingsCol
                width: settingsFlick.width
                spacing: 12

                Label {
                    visible: plugin.hasSelection
                    text: (plugin.target ? t("Point") : t("Line")) + ": " + plugin.featureLabel
                    elide: Text.ElideMiddle
                    Layout.fillWidth: true
                }
                Label {
                    visible: plugin.geom !== null
                    text: plugin.segmentInfo()
                    color: "#555555"
                    Layout.fillWidth: true
                }
                Label {
                    text: t("Height offset (m), added to the correct height")
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
                    text: t("Precise view")
                    Layout.fillWidth: true
                }
                ComboBox {
                    id: dialModeBox
                    Layout.fillWidth: true
                    model: [t("Auto"), t("Always"), t("Off")]
                }
                Label {
                    text: t("Show precise view within (m)")
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }
                TextField {
                    id: thresholdField
                    Layout.fillWidth: true
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                }
                Label {
                    text: t("Arrival tolerance (m)")
                    wrapMode: Text.WordWrap
                    Layout.fillWidth: true
                }
                TextField {
                    id: toleranceField
                    Layout.fillWidth: true
                    inputMethodHints: Qt.ImhFormattedNumbersOnly
                }
                Button {
                    text: t("Move button")
                    Layout.fillWidth: true
                    onClicked: {
                        settingsDialog.close()
                        plugin.startMove()
                    }
                }
            }
        }

        onAboutToShow: {
            offsetField.text = Geo.fmt(settings.heightOffset, 3)
            dialModeBox.currentIndex = Math.max(0, dialModes.indexOf(settings.dialMode))
            thresholdField.text = Geo.fmt(settings.dialThreshold, 2)
            toleranceField.text = Geo.fmt(settings.arrivalTol, 3)
        }
        onAccepted: {
            const num = (text, fallback, minimum) => {
                const v = parseFloat(text.replace(",", "."))
                return (isNaN(v) || v < minimum) ? fallback : v
            }
            settings.heightOffset = num(offsetField.text, 0.0, -1e9)
            settings.dialMode = dialModes[dialModeBox.currentIndex]
            settings.dialThreshold = num(thresholdField.text, 3.0, 0.01)
            settings.arrivalTol = num(toleranceField.text, 0.05, 0.001)
            plugin.update()
        }
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

        // Höjd: använd QFields projicerade position när den finns. Den har redan
        // gått genom projektets höjdtransformering (geoidnät/svara-modell) och
        // antennhöjden är redan räknad av – rå elevation är annars ellipsoidisk
        // (WGS84) och ger fel nivå mot ett projekt i ett nationellt höjdsystem.
        let z = NaN
        try {
            const pp = positioning.projectedPosition
            if (pp && info.elevationValid) {
                const zz = (typeof pp.z === 'number') ? pp.z : pp.z()
                if (typeof zz === 'number' && isFinite(zz))
                    z = zz
            }
        } catch (e) {}
        if (isNaN(z) && info.elevationValid)
            z = info.elevation

        return {
            "x": pt.x,
            "y": pt.y,
            "z": z + settings.heightOffset,
            "fix": fixInfo(info)
        }
    }

    // Noggrannhet i cm under 1 m, annars i m
    function fmtAccuracy(v) {
        if (typeof v !== 'number' || !isFinite(v) || v <= 0)
            return ""
        return v < 1 ? (v * 100).toFixed(1).replace(".", ",") + " cm" : v.toFixed(2).replace(".", ",") + " m"
    }

    // Kvalitet på GNSS-fixen: text, nivå (2 = bra, 1 = måttlig, 0 = dålig, -1 = okänd)
    // och noggrannhet. Egenskaperna kan saknas i äldre QField, därför försiktig läsning.
    function fixInfo(info) {
        let q = NaN
        try { q = Number(info.quality) } catch (e) {}
        let desc = ""
        try { desc = String(info.qualityDescription || "") } catch (e) {}

        const names = { 0: "No fix", 1: "GPS", 2: "DGPS", 3: "PPS", 4: "RTK fixed", 5: "RTK float" }
        let name = isFinite(q) && names[q] !== undefined ? t(names[q]) : desc
        let level = -1
        if (isFinite(q))
            level = q === 4 ? 2 : ((q === 2 || q === 3 || q === 5) ? 1 : 0)
        else if (desc !== "")
            level = /fixed/i.test(desc) ? 2 : (/float|dgps|differential/i.test(desc) ? 1 : 0)

        let hacc = NaN, vacc = NaN
        try { if (info.horizontalAccuracyValid !== false) hacc = Number(info.horizontalAccuracy) } catch (e) {}
        try { if (info.verticalAccuracyValid !== false) vacc = Number(info.verticalAccuracy) } catch (e) {}

        const lines = []
        if (fmtAccuracy(hacc) !== "")
            lines.push("H ±" + fmtAccuracy(hacc))
        if (fmtAccuracy(vacc) !== "")
            lines.push("V ±" + fmtAccuracy(vacc))
        if (name === "" && !lines.length)
            return null
        // detail = en rad (liggande), detailLines = en rad per värde (stående)
        return { "name": name, "level": level, "hacc": hacc, "detail": lines.join(" · "), "detailLines": lines.join("\n") }
    }

    // 1 cm största avvikelse mellan båge och rak sekant, i projektets enhet
    function arcTolerance() {
        return qgisProject.crs.isGeographic === true ? 0.01 / 111320 : 0.01
    }

    function analysisOptions() {
        const opts = {
            "reverse": plugin.reversed,
            "geographic": qgisProject.crs.isGeographic === true
        }
        // Standard: närmaste segment väljs automatiskt. Ett låst segment är
        // numrerat i riktningen A -> B; vid bakvänd riktning mappas indexet.
        const locked = plugin.lockedSeg
        if (locked && plugin.geom) {
            const path = plugin.geom.paths[locked.pathIndex]
            if (path) {
                const segIndex = plugin.reversed ? (path.coords.length - 2) - locked.segIndex : locked.segIndex
                if (segIndex >= 0)
                    opts.chosen = { "pathIndex": locked.pathIndex, "segIndex": segIndex }
            }
        }
        return opts
    }

    // Precisionsvyn: alltid / av, eller automatiskt när målet är närmare än tröskeln
    // (med lite hysteres så att den inte blinkar vid gränsen)
    function updateDialState() {
        const r = plugin.result
        if (!r || settings.dialMode === "off") {
            plugin.dialActive = false
        } else if (settings.dialMode === "always") {
            plugin.dialActive = true
        } else if (!plugin.dialActive && r.dist <= settings.dialThreshold) {
            plugin.dialActive = true
        } else if (plugin.dialActive && r.dist > settings.dialThreshold * 1.15) {
            plugin.dialActive = false
        }
    }

    function update() {
        plugin.position = currentPosition()
        plugin.fix = plugin.position ? plugin.position.fix : null
        if (!plugin.hasSelection) {
            plugin.result = null
            plugin.status = t("Tap a line, polygon or point on the map")
        } else if (!plugin.position) {
            plugin.result = null
            plugin.status = t("Waiting for GNSS position …")
        } else {
            plugin.result = plugin.target
                ? Geo.analyzePoint(plugin.target, plugin.position, { "geographic": qgisProject.crs.isGeographic === true })
                : Geo.analyze(plugin.geom, plugin.position, analysisOptions())
            plugin.status = ""
        }
        updateDialState()
        overlay.requestPaint()
        dial.requestPaint()
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
        const ms = mapCanvas.mapSettings
        const rendered = ms.layers
        const out = []
        if (rendered !== undefined && rendered !== null) {
            for (let i = 0; i < rendered.length; i++) {
                const layer = rendered[i]
                // Lagret kan vara på i lagerträdet men ligga utanför sin
                // synliga skala – då ritar QField det inte och det ska inte
                // heller gå att plocka.
                if (layerInScaleRange(layer, ms.scale))
                    out.push(layer)
            }
            return out
        }
        const all = projectUtils.mapLayers(qgisProject)
        for (const id in all) {
            const layer = all[id]
            if (layerInScaleRange(layer, ms.scale))
                out.push(layer)
        }
        return out
    }

    function layerInScaleRange(layer, scale) {
        try {
            if (scale === undefined || scale === null || scale <= 0)
                return true
            if (typeof layer.hasScaleBasedVisibility === 'function' && layer.hasScaleBasedVisibility()) {
                // Som i QgsMapLayer::isInScaleRange: minimumScale är gränsen
                // när man zoomar in, maximumScale när man zoomar ut.
                return scale >= layer.minimumScale() && scale < layer.maximumScale()
            }
        } catch (e) {}
        return true
    }

    // Plockar vid en punkt på skärmen. mode "normal": punkter och linjesegment,
    // "vertex": närmaste brytpunkt/punkt i linjer, polygoner och punktlager.
    function pickAt(screenPoint, mode) {
        const ms = mapCanvas.mapSettings
        const tol = plugin.pickTolerancePx
        const tl = ms.screenToCoordinate(Qt.point(screenPoint.x - tol, screenPoint.y - tol))
        const br = ms.screenToCoordinate(Qt.point(screenPoint.x + tol, screenPoint.y + tol))
        const centre = ms.screenToCoordinate(Qt.point(screenPoint.x, screenPoint.y))
        const rect = geoUtils.createRectangleFromPoints(tl, br)
        const geographic = qgisProject.crs.isGeographic === true
        const probe = {
            "x": centre.x,
            "y": centre.y,
            "z": NaN
        }
        const opts = {
            "reverse": false,
            "geographic": geographic
        }
        // Avstånden räknas i samma enhet som analysen (meter för grader)
        const sf = Geo.scaleFactors(probe, geographic)
        const tolUnits = Math.hypot((centre.x - tl.x) * sf.kx, (centre.y - tl.y) * sf.ky)
        opts.collect = { "maxDist": tolUnits, "out": [], "cap": 40 }

        const cands = []
        function addTarget(key, label, c) {
            const a = Geo.analyzePoint(c, probe, opts)
            if (a.dist <= tolUnits)
                cands.push({ "type": "target", "key": key, "dist": a.dist, "label": label, "target": { "x": c.x, "y": c.y, "z": c.z } })
        }
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
                    const label = displayName(layer, feature)
                    const key = layer.id + "#" + feature.id
                    if (parsed.kind === "point") {
                        parsed.points.forEach((c, i) => addTarget(key + "@" + i,
                            parsed.points.length > 1 ? label + " · " + t("Point") + " " + (i + 1) : label, c))
                    } else if (mode === "vertex") {
                        parsed.paths.forEach((path, pi) => path.coords.forEach((c, vi) =>
                            addTarget(key + "@" + pi + ":" + vi, label + " · " + t("Vertex") + " " + (vi + 1), c)))
                    } else {
                        opts.collect.out.length = 0
                        if (!Geo.analyze(parsed, probe, opts))
                            continue
                        for (const seg of opts.collect.out)
                            cands.push({
                                "type": "line",
                                "key": key,
                                "dist": seg.dist,
                                "pathIndex": seg.pathIndex,
                                "segIndex": seg.segIndex,
                                "geom": parsed,
                                "label": label
                            })
                    }
                }
                it.close()
            } catch (e) {
                // rasterlager, lager utan geometri m.m. hoppas över
            }
        }
        if (!cands.length)
            return null
        cands.sort((a, b) => a.dist - b.dist)
        return { "candidates": cands.slice(0, 200) }
    }

    // Hanterar ett plock. Är en linje redan aktiv och plockas den igen låses
    // det valda segmentet som referens. Annars aktiveras det närmaste: en målpunkt
    // eller en linje med automatiskt segmentbyte.
    function applyPick(cands) {
        if (plugin.geom !== null && plugin.featureKey !== "") {
            for (const c of cands) {
                if (c.type === "line" && c.key === plugin.featureKey) {
                    plugin.geom = c.geom
                    plugin.lockedSeg = { "pathIndex": c.pathIndex, "segIndex": c.segIndex }
                    mainWindow.displayToast(t("Segment locked"))
                    update()
                    return
                }
            }
        }
        const first = cands[0]
        plugin.featureLabel = first.label
        plugin.featureKey = first.key
        plugin.lockedSeg = null
        plugin.reversed = false
        if (first.type === "target") {
            plugin.geom = null
            plugin.target = first.target
        } else {
            plugin.target = null
            plugin.geom = first.geom
        }
        update()
    }

    function startPicking(mode) {
        const handler = iface.findItemByObjectName("pointHandler")
        if (!handler) {
            mainWindow.displayToast(t("Could not find the map click handler"))
            return
        }
        plugin.pickMode = mode === "vertex" ? "vertex" : "normal"
        plugin.picking = true
        mainWindow.displayToast(plugin.pickMode === "vertex" ? t("Tap a vertex or point on the map") : t("Tap a line, polygon or point on the map"))
        handler.registerHandler(plugin.handlerName, function (point, type, interactionType) {
            if (interactionType !== "clicked")
                return false
            stopPicking()
            const hit = pickAt(point, plugin.pickMode)
            if (hit) {
                applyPick(hit.candidates)
            } else {
                mainWindow.displayToast(t("Nothing to select near where you tapped"))
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
        plugin.target = null
        plugin.featureLabel = ""
        plugin.featureKey = ""
        plugin.lockedSeg = null
        plugin.reversed = false
        update()
    }

    // ---- värden som visas på panelen
    readonly property bool hasHeight: result !== null && isFinite(result.z)

    function offsetLabel() {
        if (isPoint)
            return t("Distance, m")
        return result && result.kind === "polygon" ? t("To edge, m") : t("Offset, m")
    }

    function offsetValue() {
        return result ? Geo.fmt(Math.abs(result.offset)) : "–"
    }

    // Riktning mot en målpunkt: pil åt åttondelen och kompassgrader
    function bearingHint(deg) {
        const arrows = ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"]
        return arrows[Math.round(deg / 45) % 8] + "\u00A0" + (Math.round(deg) % 360) + "°"
    }

    function offsetHint() {
        const r = result
        if (!r)
            return ""
        if (r.kind === "point")
            return r.dist < 0.0005 ? t("at the point") : bearingHint(r.bearing)
        if (r.kind === "polygon")
            return r.inside ? t("inside") : t("outside")
        if (r.dist < 0.0005)
            return t("on the line")
        // Hårt mellanslag så att pilen och texten alltid hålls på samma rad
        return (r.offset > 0 ? t("right →") : t("← left")).replace(/ /g, "\u00A0")
    }

    // "cut" = marken ligger över linjens höjd, "fill" = under, "level" = i nivå, "" = okänt
    function cutState() {
        const r = result
        if (!r || !isFinite(r.dz))
            return ""
        return r.dz > 0.0005 ? "cut" : (r.dz < -0.0005 ? "fill" : "level")
    }

    function cutLabel() {
        const k = cutState()
        return k === "cut" ? t("Cut, m") : (k === "fill" ? t("Fill, m") : t("Cut/Fill, m"))
    }

    function cutValue() {
        return cutState() !== "" ? Geo.fmt(Math.abs(result.dz)) : "–"
    }

    function cutHint() {
        const k = cutState()
        return k === "cut" ? t("remove material") : (k === "fill" ? t("add material") : (k === "level" ? t("at level") : ""))
    }

    readonly property bool showOffsetPill: settings.heightOffset !== 0 && hasHeight
    readonly property string offsetPillText: (settings.heightOffset > 0 ? "+" : "") + Geo.fmt(settings.heightOffset, 3) + " m"

    // Text för inställningsdialogen: aktivt segment
    function segmentInfo() {
        const r = plugin.result
        if (!plugin.geom || !r)
            return ""
        const path = plugin.geom.paths[r.pathIndex]
        if (!path)
            return ""
        const n = path.coords.length - 1
        // result.segIndex räknas i aktuell riktning; visa som A -> B
        const idx = plugin.reversed ? n - r.segIndex : r.segIndex + 1
        let s = t("Segment") + " " + idx + "/" + n
        if (plugin.lockedSeg)
            s += " (" + t("locked") + ")"
        return s
    }

    // Menyn placeras bredvid knappen och hålls helt inom skärmen, under statusraden.
    // Ligger knappen i nedre halvan växer menyn uppåt. Efter att menyn öppnats
    // justeras läget en gång till med de verkliga måtten.
    property real menuMaxHeight: 10000

    function menuTopLimit() {
        const content = mainWindow.contentItem
        let topLimit = 48
        const sb = iface.findItemByObjectName("statusBar")
        if (sb && sb.visible && sb.height > 0) {
            const sp = sb.mapToItem(content, 0, 0)
            if (sp.y < content.height / 2)
                topLimit = Math.max(topLimit, sp.y + sb.height + 8)
        }
        return topLimit
    }

    function placeMenu(gx, gy, w, h) {
        const content = mainWindow.contentItem
        const margin = 8
        const pos = plugin.activeButton.mapToItem(content, 0, 0)
        const x = Math.max(margin, Math.min(gx, content.width - w - margin))
        const y = Math.max(menuTopLimit(), Math.min(gy, content.height - h - margin))
        pluginMenu.x = x - pos.x
        pluginMenu.y = y - pos.y
    }

    function showMenu() {
        const content = mainWindow.contentItem
        const margin = 8
        const btn = plugin.activeButton
        const pos = btn.mapToItem(content, 0, 0)
        plugin.menuMaxHeight = content.height - menuTopLimit() - margin
        const w = pluginMenu.width
        const h = Math.min(pluginMenu.implicitHeight, plugin.menuMaxHeight)

        // Helst till vänster om knappen, annars till höger
        let gx = pos.x - w - margin
        if (gx < margin)
            gx = pos.x + btn.width + margin
        // Nedre halvan: menyns underkant i höjd med knappens underkant
        const gy = pos.y + btn.height / 2 > content.height / 2 ? pos.y + btn.height - h : pos.y
        pluginMenu.popup(gx - pos.x, gy - pos.y)
        Qt.callLater(function () {
            placeMenu(gx, gy, pluginMenu.width, pluginMenu.height)
        })
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

    // Gemensam knapp: kort tryck och långt tryck skickas som signaler
    component PluginBtn: QfToolButton {
        iconSource: 'icon.svg'
        iconColor: Theme.mainColor
        bgcolor: Theme.darkGray
        round: true

        signal shortTap
        signal longPress

        property bool longPressFired: false

        Timer {
            id: pressTimer
            interval: 600
            onTriggered: {
                parent.longPressFired = true
                parent.longPress()
            }
        }

        onPressed: {
            longPressFired = false
            pressTimer.restart()
        }
        onReleased: pressTimer.stop()
        onCanceled: pressTimer.stop()
        onClicked: {
            if (!longPressFired)
                shortTap()
        }
    }

    function buttonTapped() {
        if (plugin.panelOpen && (plugin.hasSelection || plugin.picking))
            plugin.closePanel()
        else {
            plugin.openPanel()
            if (!plugin.hasSelection && !plugin.picking)
                plugin.startPicking()
        }
    }

    function buttonLongPressed() {
        plugin.startPicking()
        plugin.showMenu()
    }

    // Knappen i QFields verktygsfält (standard)
    PluginBtn {
        id: pluginButton
        visible: !plugin.useFloat
        onShortTap: plugin.buttonTapped()
        onLongPress: plugin.buttonLongPressed()
    }

    // Egen knapp på kartan när användaren har flyttat den
    Item {
        id: floatHolder
        parent: plugin.mapLayer
        z: 3
        visible: plugin.useFloat
        width: floatButton.width
        height: floatButton.height

        PluginBtn {
            id: floatButton
            onShortTap: plugin.buttonTapped()
            onLongPress: plugin.buttonLongPressed()
        }

        Rectangle {
            anchors.fill: parent
            anchors.margins: -4
            radius: width / 2
            color: "transparent"
            border.color: "#e53935"
            border.width: 3
            visible: plugin.moveMode
        }

        MouseArea {
            anchors.fill: parent
            z: 1
            enabled: plugin.moveMode
            drag.target: floatHolder
            drag.minimumX: 0
            drag.minimumY: 0
            drag.maximumX: floatHolder.parent.width - floatHolder.width
            drag.maximumY: floatHolder.parent.height - floatHolder.height
            onReleased: plugin.saveFloatPos()
            onClicked: {
                plugin.saveFloatPos()
                plugin.moveMode = false
            }
            // Långt tryck i flyttläget: tillbaka till standardplatsen i verktygsfältet
            onPressAndHold: {
                plugin.resetButtonPosition()
                mainWindow.displayToast(t("Button position reset"))
            }
        }
    }

    Connections {
        target: plugin.mapCanvas
        ignoreUnknownSignals: true
        function onWidthChanged() { plugin.applyFloatPos() }
        function onHeightChanged() { plugin.applyFloatPos() }
    }

    function applyFloatPos() {
        const c = floatHolder.parent
        if (!plugin.useFloat || !c || c.width <= 0)
            return
        floatHolder.x = Math.max(0, Math.min(plugin.fracX * c.width, c.width - floatHolder.width))
        floatHolder.y = Math.max(0, Math.min(plugin.fracY * c.height, c.height - floatHolder.height))
    }

    function storeFrac(x, y) {
        const c = floatHolder.parent
        if (!c || c.width <= 0 || c.height <= 0)
            return
        const fx = Math.max(0, Math.min(1, x / c.width))
        const fy = Math.max(0, Math.min(1, y / c.height))
        if (plugin.landscape) {
            settings.landX = fx
            settings.landY = fy
        } else {
            settings.portX = fx
            settings.portY = fy
        }
    }

    function saveFloatPos() {
        if (!plugin.moveMode)
            return
        storeFrac(floatHolder.x, floatHolder.y)
    }

    function startMove() {
        // Börja från verktygsfältsknappens nuvarande plats
        if (!plugin.useFloat) {
            const p = pluginButton.mapToItem(floatHolder.parent, 0, 0)
            storeFrac(p.x, p.y)
        }
        plugin.moveMode = true
        applyFloatPos()
        mainWindow.displayToast(t("Drag the button, tap it when done. Long press resets."))
    }

    function resetButtonPosition() {
        plugin.moveMode = false
        settings.portX = -1
        settings.portY = -1
        settings.landX = -1
        settings.landY = -1
    }

    Menu {
        id: pluginMenu
        parent: plugin.activeButton
        z: 1000
        // Långa lagernamn kortas av i stället för att göra menyn bred
        width: Math.min(implicitWidth, 300)
        // Rymmer inte menyn på skärmen blir den rullbar
        height: Math.min(implicitHeight, plugin.menuMaxHeight)

        MenuItem {
            text: t("⌖ Pick")
            visible: !plugin.picking
            height: visible ? implicitHeight : 0
            onTriggered: plugin.startPicking()
        }
        MenuItem {
            text: t("⌖ Pick vertex")
            visible: !plugin.picking
            height: visible ? implicitHeight : 0
            onTriggered: plugin.startPicking("vertex")
        }
        MenuItem {
            text: t("⇅ Reverse line")
            visible: plugin.geom !== null
            height: visible ? implicitHeight : 0
            onTriggered: {
                plugin.reversed = !plugin.reversed
                plugin.update()
            }
        }
        MenuItem {
            text: t("Automatic segment")
            visible: plugin.lockedSeg !== null
            height: visible ? implicitHeight : 0
            onTriggered: {
                plugin.lockedSeg = null
                plugin.update()
            }
        }
        MenuItem {
            text: t("Clear selection")
            visible: plugin.hasSelection
            height: visible ? implicitHeight : 0
            onTriggered: plugin.clearSelection()
        }
        MenuItem {
            text: t("Settings")
            onTriggered: settingsDialog.open()
        }
    }

    // ------------------------------------------------------------ kartöverlägg

    // Streckad linje från positionen till närmaste punkt på linjen
    Canvas {
        id: overlay
        parent: plugin.mapLayer
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

            // Aktivt segment: markerat med tjock blå linje
            const r = plugin.result
            if (r.segStart && r.segEnd) {
                const s0 = ms.coordinateToScreen(geoUtils.point(r.segStart.x, r.segStart.y))
                const s1 = ms.coordinateToScreen(geoUtils.point(r.segEnd.x, r.segEnd.y))
                ctx.setLineDash([])
                ctx.strokeStyle = "#1e88e5"
                ctx.lineWidth = 7
                ctx.lineCap = "round"
                ctx.globalAlpha = 0.75
                ctx.beginPath()
                ctx.moveTo(s0.x, s0.y)
                ctx.lineTo(s1.x, s1.y)
                ctx.stroke()
                ctx.globalAlpha = 1
            }

            // Förlängning förbi start/slut: tunn linje från ändpunkten genom
            // fotpunkten, förlängd en bit till, med värdet vid foten.
            if (r.ext && r.foot && r.segStart && r.segEnd) {
                const ep = ms.coordinateToScreen(geoUtils.point(
                    r.ext === 'start' ? r.segStart.x : r.segEnd.x,
                    r.ext === 'start' ? r.segStart.y : r.segEnd.y))
                const fp = ms.coordinateToScreen(geoUtils.point(r.foot.x, r.foot.y))
                let vx = fp.x - ep.x, vy = fp.y - ep.y
                const vl = Math.hypot(vx, vy)
                if (vl > 0.5) {
                    vx /= vl; vy /= vl
                    const over = 30   // förlängd bit förbi foten, i px
                    const endX = fp.x + vx * over, endY = fp.y + vy * over
                    ctx.strokeStyle = "#e53935"
                    ctx.lineWidth = 1.5
                    ctx.setLineDash([6, 5])
                    ctx.beginPath()
                    ctx.moveTo(ep.x, ep.y)
                    ctx.lineTo(endX, endY)
                    ctx.stroke()
                    ctx.setLineDash([])
                    // liten cirkel vid foten på förlängningen
                    ctx.beginPath()
                    ctx.arc(fp.x, fp.y, 5, 0, 2 * Math.PI)
                    ctx.fillStyle = "#e53935"
                    ctx.fill()
                    ctx.lineWidth = 1.5
                    ctx.strokeStyle = "white"
                    ctx.stroke()
                }
            }
        }
    }

    // ------------------------------------------------------------ precisionsvy

    // Cirkulär vy som zoomar in när du närmar dig. Målpunkt: norr uppåt, målet i mitten
    // och din position som en prick. Linje: linjen går lodrätt genom mitten (riktning
    // A -> B uppåt), pricken visar sidoavståndet och markeringar längs linjen rullar
    // när du går. Prickens halo visar GNSS-noggrannheten.
    Rectangle {
        id: dialCard
        parent: plugin.mapLayer
        z: 2
        visible: plugin.panelOpen && plugin.dialActive && plugin.result !== null
        readonly property int diameter: plugin.landscape ? 130 : 176
        width: diameter
        height: diameter
        radius: diameter / 2
        anchors.top: panel.bottom
        anchors.topMargin: 6
        anchors.horizontalCenter: plugin.landscape ? undefined : parent.horizontalCenter
        anchors.right: plugin.landscape ? panel.right : undefined
        color: Qt.rgba(1, 1, 1, 0.5)
        border.color: Qt.rgba(0, 0, 0, 0.25)

        Canvas {
            id: dial
            anchors.fill: parent

            onPaint: {
                const ctx = getContext("2d")
                const W = width, H = height
                ctx.clearRect(0, 0, W, H)
                const r = plugin.result, pos = plugin.position
                if (!r || !pos)
                    return
                const cx = W / 2, cy = H / 2, R = Math.min(W, H) / 2 - 4
                const isPoint = r.kind === "point"
                const tol = settings.arrivalTol

                // Positionen relativt målet i meter: x åt höger, yUp uppåt i vyn
                let x, yUp
                if (isPoint) {
                    x = -r.dE
                    yUp = -r.dN
                } else {
                    const o = Geo.localOffset(pos, r.foot, qgisProject.crs.isGeographic === true)
                    const b = r.bearing * Math.PI / 180
                    x = o.e * Math.cos(b) - o.n * Math.sin(b)
                    yUp = o.e * Math.sin(b) + o.n * Math.cos(b)
                }
                const d = Math.hypot(x, yUp)

                // Skalan: minsta steg som rymmer avståndet med lite marginal
                const ladder = [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 25, 50, 100, 250, 500, 1000]
                let range = ladder[ladder.length - 1]
                for (const v of ladder) {
                    if (v >= d * 1.2) {
                        range = v
                        break
                    }
                }
                const scale = R / range
                const arrived = isPoint ? d <= tol : Math.abs(x) <= tol

                // Skiva och ringar
                ctx.setLineDash([])
                ctx.beginPath()
                ctx.arc(cx, cy, R, 0, 2 * Math.PI)
                ctx.fillStyle = arrived ? "rgba(76,175,80,0.35)" : "rgba(255,255,255,0.35)"
                ctx.fill()
                ctx.strokeStyle = "rgba(0,0,0,0.35)"
                ctx.lineWidth = 1
                ctx.stroke()
                ctx.beginPath()
                ctx.arc(cx, cy, R / 2, 0, 2 * Math.PI)
                ctx.stroke()
                ctx.beginPath()
                ctx.moveTo(cx - R, cy)
                ctx.lineTo(cx + R, cy)
                ctx.moveTo(cx, cy - R)
                ctx.lineTo(cx, cy + R)
                ctx.strokeStyle = "rgba(0,0,0,0.12)"
                ctx.stroke()

                ctx.fillStyle = "#555555"
                ctx.textAlign = "center"
                ctx.font = "bold 11px sans-serif"
                if (isPoint)
                    ctx.fillText("N", cx, cy - R + 13)
                ctx.font = "10px sans-serif"
                ctx.fillText(range < 1 ? Math.round(range * 100) + " cm" : String(range).replace(".", ",") + " m", cx, cy + R - 6)

                if (!isPoint) {
                    // Linjen med riktningspil och markeringar som rullar med färdriktningen
                    ctx.strokeStyle = arrived ? "#2e7d32" : "#1e88e5"
                    ctx.lineWidth = 3
                    ctx.lineCap = "round"
                    ctx.beginPath()
                    ctx.moveTo(cx, cy + R)
                    ctx.lineTo(cx, cy - R)
                    ctx.stroke()
                    ctx.fillStyle = ctx.strokeStyle
                    ctx.beginPath()
                    ctx.moveTo(cx, cy - R + 1)
                    ctx.lineTo(cx - 6, cy - R + 12)
                    ctx.lineTo(cx + 6, cy - R + 12)
                    ctx.closePath()
                    ctx.fill()
                    const tickStep = range / 2
                    ctx.lineWidth = 1.5
                    for (let c = Math.floor((r.fromStart - range) / tickStep) * tickStep; c <= r.fromStart + range; c += tickStep) {
                        const ty = cy - (c - r.fromStart) * scale
                        if (Math.abs(ty - cy) < R - 14) {
                            ctx.beginPath()
                            ctx.moveTo(cx - 7, ty)
                            ctx.lineTo(cx + 7, ty)
                            ctx.stroke()
                        }
                    }
                } else {
                    // Målet: ring med kors, grön när du är framme
                    ctx.strokeStyle = arrived ? "#2e7d32" : "#e53935"
                    ctx.lineWidth = 2.5
                    ctx.beginPath()
                    ctx.arc(cx, cy, 8, 0, 2 * Math.PI)
                    ctx.moveTo(cx - 13, cy)
                    ctx.lineTo(cx + 13, cy)
                    ctx.moveTo(cx, cy - 13)
                    ctx.lineTo(cx, cy + 13)
                    ctx.stroke()
                }

                // Position: prick i färg efter fixkvalitet, halo = horisontell noggrannhet
                const level = plugin.fix ? plugin.fix.level : -1
                const rgb = level === 2 ? "46,125,50" : (level === 1 ? "255,152,0" : (level === 0 ? "211,47,47" : "30,136,229"))
                const px = cx + x * scale, py = cy - yUp * scale
                const hacc = plugin.fix ? plugin.fix.hacc : NaN
                if (isFinite(hacc) && hacc > 0) {
                    ctx.beginPath()
                    ctx.arc(px, py, Math.min(hacc * scale, R), 0, 2 * Math.PI)
                    ctx.fillStyle = "rgba(" + rgb + ",0.2)"
                    ctx.fill()
                }
                if (isPoint) {
                    ctx.setLineDash([5, 4])
                    ctx.strokeStyle = "rgba(229,57,53,0.8)"
                    ctx.lineWidth = 1.5
                    ctx.beginPath()
                    ctx.moveTo(px, py)
                    ctx.lineTo(cx, cy)
                    ctx.stroke()
                    ctx.setLineDash([])
                }
                ctx.beginPath()
                ctx.arc(px, py, 6, 0, 2 * Math.PI)
                ctx.fillStyle = "rgb(" + rgb + ")"
                ctx.fill()
                ctx.lineWidth = 2
                ctx.strokeStyle = "white"
                ctx.stroke()
            }
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
        onTriggered: {
            overlay.requestPaint()
            dial.requestPaint()
        }
    }

    // ------------------------------------------------------------ panel

    component Tile: ColumnLayout {
        property string label
        property string value
        property string hint
        property int valueSize: 30
        property int hintSize: 13
        property bool hintBold: false
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
            font.pixelSize: parent.hintSize
            font.bold: parent.hintBold
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignHCenter
        }
    }

    // GNSS-kvalitet (färgad punkt, fixtyp, noggrannhet) och höjdoffset-etikett.
    // Får bara värden utifrån och känner inte till pluginet.
    component InfoBlock: ColumnLayout {
        id: info
        property bool alignRight: false
        property bool showFix: false
        property string fixName
        property int fixLevel: -1
        property string fixDetail
        property bool showOffset: false
        property string offsetTitle
        property string offsetText
        visible: showFix || showOffset
        spacing: 2

        RowLayout {
            visible: info.showFix
            spacing: 6
            Layout.alignment: info.alignRight ? Qt.AlignRight : Qt.AlignLeft
            Rectangle {
                width: 10
                height: 10
                radius: 5
                color: info.fixLevel === 2 ? "#2e7d32" : (info.fixLevel === 1 ? "#ff9800" : (info.fixLevel === 0 ? "#d32f2f" : "#9e9e9e"))
            }
            Label {
                text: info.fixName
                color: "#444444"
                font.pixelSize: 13
                font.bold: true
            }
        }
        Label {
            visible: info.showFix && info.fixDetail !== ""
            text: info.fixDetail
            color: "#444444"
            font.pixelSize: 12
            horizontalAlignment: info.alignRight ? Text.AlignRight : Text.AlignLeft
            Layout.alignment: info.alignRight ? Qt.AlignRight : Qt.AlignLeft
        }
        Rectangle {
            visible: info.showOffset
            Layout.alignment: info.alignRight ? Qt.AlignRight : Qt.AlignLeft
            implicitWidth: pillText.implicitWidth + 16
            implicitHeight: pillText.implicitHeight + 6
            radius: 9
            color: "#ff9800"
            ColumnLayout {
                id: pillText
                anchors.centerIn: parent
                spacing: 0
                Label {
                    text: info.offsetTitle
                    color: "#111111"
                    font.pixelSize: 12
                    font.bold: true
                    Layout.alignment: Qt.AlignHCenter
                }
                Label {
                    text: info.offsetText
                    color: "#111111"
                    font.pixelSize: 12
                    font.bold: true
                    Layout.alignment: Qt.AlignHCenter
                }
            }
        }
    }

    Rectangle {
        id: panel
        parent: plugin.mapLayer
        visible: plugin.panelOpen
        z: 2
        // Mellan sidoknapparna (72 px per sida). Liggande: smalare, centrerad panel
        // så att kartan och knapparna inte täcks i onödan.
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: 23
        width: Math.min(parent.width - 2 * 72, plugin.landscape ? 520 : parent.width)
        height: content.implicitHeight + 16
        radius: 12
        color: Qt.rgba(1, 1, 1, 0.5)
        border.color: Qt.rgba(0, 0, 0, 0.25)

        ColumnLayout {
            id: content
            anchors.fill: parent
            anchors.margins: 8
            spacing: 6

            // ---- stående: Offset och Cut/Fill till vänster, A/B + GNSS/offset till höger
            RowLayout {
                Layout.fillWidth: true
                visible: plugin.result !== null && !plugin.landscape
                spacing: 8

                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 2

                    Tile {
                        label: plugin.offsetLabel()
                        value: plugin.offsetValue()
                        hint: plugin.offsetHint()
                        hintSize: 18
                        hintBold: true
                    }
                    Tile {
                        visible: plugin.hasHeight
                        label: plugin.cutLabel()
                        value: plugin.cutValue()
                        hint: plugin.cutHint()
                    }
                }

                ColumnLayout {
                    Layout.alignment: Qt.AlignRight | Qt.AlignTop
                    Layout.preferredWidth: 110
                    spacing: 0

                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: plugin.isPoint ? t("East, m") : t("From A, m")
                        color: "#555555"
                        font.pixelSize: 12
                    }
                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: plugin.result ? Geo.fmt(plugin.abA, 2) : "–"
                        color: plugin.result ? plugin.abColor(plugin.abA) : "#111111"
                        font.pixelSize: 18
                        font.bold: true
                    }
                    Item { height: 4 }
                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: plugin.isPoint ? t("North, m") : t("To B, m")
                        color: "#555555"
                        font.pixelSize: 12
                    }
                    Label {
                        Layout.alignment: Qt.AlignRight
                        text: plugin.result ? Geo.fmt(plugin.abB, 2) : "–"
                        color: plugin.result ? plugin.abColor(plugin.abB) : "#111111"
                        font.pixelSize: 18
                        font.bold: true
                    }
                    Item { height: 10 }
                    InfoBlock {
                        alignRight: true
                        Layout.alignment: Qt.AlignRight
                        showFix: plugin.fix !== null
                        fixName: plugin.fix ? plugin.fix.name : ""
                        fixLevel: plugin.fix ? plugin.fix.level : -1
                        fixDetail: plugin.fix ? plugin.fix.detailLines : ""
                        showOffset: plugin.showOffsetPill
                        offsetTitle: t("Height offset")
                        offsetText: plugin.offsetPillText
                    }
                }
            }

            // ---- liggande: [GNSS/offset] | Cut/Fill | Offset | A/B i en rad
            RowLayout {
                Layout.fillWidth: true
                visible: plugin.result !== null && plugin.landscape
                spacing: 10

                InfoBlock {
                    id: landscapeInfo
                    Layout.alignment: Qt.AlignVCenter
                    showFix: plugin.fix !== null
                    fixName: plugin.fix ? plugin.fix.name : ""
                    fixLevel: plugin.fix ? plugin.fix.level : -1
                    fixDetail: plugin.fix ? plugin.fix.detail : ""
                    showOffset: plugin.showOffsetPill
                    offsetTitle: t("Height offset")
                    offsetText: plugin.offsetPillText
                }
                Rectangle {
                    visible: landscapeInfo.visible
                    Layout.preferredWidth: 1
                    Layout.fillHeight: true
                    Layout.topMargin: 4
                    Layout.bottomMargin: 4
                    color: Qt.rgba(0, 0, 0, 0.2)
                }
                Tile {
                    visible: plugin.hasHeight
                    label: plugin.cutLabel()
                    value: plugin.cutValue()
                    hint: plugin.cutHint()
                }
                Tile {
                    label: plugin.offsetLabel()
                    value: plugin.offsetValue()
                    hint: plugin.offsetHint()
                    hintSize: 18
                    hintBold: true
                }
                GridLayout {
                    Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                    columns: 2
                    columnSpacing: 6
                    rowSpacing: 6

                    Label {
                        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                        text: plugin.isPoint ? t("East, m") : t("From A, m")
                        color: "#555555"
                        font.pixelSize: 12
                    }
                    Label {
                        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                        text: plugin.result ? Geo.fmt(plugin.abA, 2) : "–"
                        color: plugin.result ? plugin.abColor(plugin.abA) : "#111111"
                        font.pixelSize: 18
                        font.bold: true
                    }
                    Label {
                        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                        text: plugin.isPoint ? t("North, m") : t("To B, m")
                        color: "#555555"
                        font.pixelSize: 12
                    }
                    Label {
                        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                        text: plugin.result ? Geo.fmt(plugin.abB, 2) : "–"
                        color: plugin.result ? plugin.abColor(plugin.abB) : "#111111"
                        font.pixelSize: 18
                        font.bold: true
                    }
                }
            }

            Label {
                Layout.fillWidth: true
                text: plugin.status
                visible: plugin.status !== ""
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                color: "#555555"
            }
        }
    }

    Component.onCompleted: {
        iface.addItemToPluginsToolbar(pluginButton)
        applyFloatPos()
    }

    Component.onDestruction: {
        stopPicking()
    }
}
