.pragma library

// Ren geometrimodul utan QField-beroenden (testas med node, se tests/).
// All indata är koordinater i projektets CRS; om `geographic` är sant (grader)
// räknas avstånd om till meter med en lokal ekvirektangulär approximation.

function parseNested(s) {
    var i = s.indexOf('(')
    if (i < 0) return null
    function group() {
        i++
        var items = []
        var buf = ''
        while (i < s.length) {
            var c = s[i]
            if (c === '(') {
                var g = group()
                if (buf.trim()) g.tag = buf.trim()   // t.ex. "CircularString" inuti CompoundCurve
                items.push(g)
                buf = ''
                continue
            }
            if (c === ')') {
                if (buf.trim()) items.push(buf.trim())
                i++
                return items
            }
            if (c === ',') {
                if (buf.trim()) items.push(buf.trim())
                buf = ''
                i++
                continue
            }
            buf += c
            i++
        }
        return items
    }
    return group()
}

function toCoords(strings, dim) {
    var out = []
    for (var k = 0; k < strings.length; k++) {
        if (typeof strings[k] !== 'string') continue
        var n = strings[k].split(/\s+/).map(Number)
        if (n.length < 2 || isNaN(n[0]) || isNaN(n[1])) continue
        var z = NaN
        if (dim === 'Z' || dim === 'ZM' || (dim === '' && n.length >= 3)) z = n.length >= 3 ? n[2] : NaN
        out.push({ x: n[0], y: n[1], z: z })
    }
    return out
}

// Punkter längs cirkelbågen p0 -> p1 -> p2 (utan p0, med exakt p2 sist).
// `tol` = största tillåtna avvikelse (kartenheter) mellan båge och rak sekant.
function arcPoints(p0, p1, p2, tol) {
    var bx = p1.x - p0.x, by = p1.y - p0.y
    var cx = p2.x - p0.x, cy = p2.y - p0.y
    var scale = Math.max(Math.abs(bx), Math.abs(by), Math.abs(cx), Math.abs(cy))
    if (scale === 0) return [p2]
    var ux, uy, sweep
    var closed = Math.abs(cx) < 1e-12 * scale && Math.abs(cy) < 1e-12 * scale
    if (closed) {
        // hel cirkel: p0 == p2, medelpunkt mitt emellan p0 och p1
        ux = bx / 2; uy = by / 2
        sweep = 2 * Math.PI
    } else {
        var d = 2 * (bx * cy - by * cx)
        if (Math.abs(d) < 1e-9 * scale * scale) return [p1, p2]   // kollinjära => rak
        var b2 = bx * bx + by * by, c2 = cx * cx + cy * cy
        ux = (cy * b2 - by * c2) / d
        uy = (bx * c2 - cx * b2) / d
        var a0 = Math.atan2(-uy, -ux), a2 = Math.atan2(cy - uy, cx - ux)
        var TWO = 2 * Math.PI
        if (d > 0) {   // moturs
            sweep = ((a2 - a0) % TWO + TWO) % TWO
        } else {
            sweep = -(((a0 - a2) % TWO + TWO) % TWO)
        }
    }
    var r = Math.hypot(ux, uy)
    var step = tol > 0 && r > tol ? 2 * Math.acos(1 - tol / r) : Math.PI / 2
    var n = Math.max(1, Math.min(2000, Math.ceil(Math.abs(sweep) / step)))
    var start = Math.atan2(-uy, -ux)
    var out = []
    for (var k = 1; k <= n; k++) {
        if (k === n) { out.push({ x: p2.x, y: p2.y, z: p2.z }); break }
        var f = k / n, ang = start + sweep * f
        out.push({
            x: p0.x + ux + r * Math.cos(ang),
            y: p0.y + uy + r * Math.sin(ang),
            z: (isFinite(p0.z) && isFinite(p2.z)) ? p0.z + f * (p2.z - p0.z) : NaN
        })
    }
    return out
}

function arcsToCoords(c, tol) {
    if (c.length < 3) return c
    var out = [c[0]]
    for (var i = 0; i + 2 < c.length; i += 2)
        out = out.concat(arcPoints(c[i], c[i + 1], c[i + 2], tol))
    return out
}

function tagInfo(node, outerDim) {
    if (!node.tag) return { name: '', dim: outerDim }
    var t = node.tag.toUpperCase().replace(/\s+/g, '')
    var m = /(ZM|Z|M)$/.exec(t)
    return { name: m ? t.slice(0, t.length - m[1].length) : t, dim: m ? m[1] : outerDim }
}

// Lista av barn (CompoundCurve) -> sammanhängande koordinatlista
function compoundToCoords(children, dim, tol) {
    var out = []
    for (var i = 0; i < children.length; i++) {
        if (!Array.isArray(children[i])) continue
        var c = nodeToCoords(children[i], dim, tol)
        if (out.length && c.length && Math.hypot(out[out.length - 1].x - c[0].x, out[out.length - 1].y - c[0].y) < 1e-9)
            c = c.slice(1)
        out = out.concat(c)
    }
    return out
}

// Ett (ev. taggat) kurvelement -> koordinater
function nodeToCoords(node, outerDim, tol) {
    var t = tagInfo(node, outerDim)
    if (t.name === 'COMPOUNDCURVE') return compoundToCoords(node, t.dim, tol)
    if (t.name === 'CIRCULARSTRING') return arcsToCoords(toCoords(node, t.dim), tol)
    return toCoords(node, t.dim)   // LineString eller otaggad rak sträcka
}

// Returnerar { kind: 'line'|'polygon', paths: [{coords, closed, poly, hole}] } eller
// { kind: 'point', points: [{x, y, z}] } eller null.
// opts.tolerance: största avvikelse (kartenheter) när cirkelbågar delas i raka segment.
function parseWkt(wkt, opts) {
    if (!wkt) return null
    var tol = opts && opts.tolerance > 0 ? opts.tolerance : 0.01
    var m = /^\s*([A-Za-z]+)\s*(ZM|Z|M)?\s*\(/i.exec(wkt)
    if (!m) return null
    var name = m[1].toUpperCase()
    var dim = (m[2] || '').toUpperCase()
    var suffix = /(ZM|Z|M)$/.exec(name)
    if (suffix && !dim) {   // "LineStringZ (...)" i stället för "LineString Z (...)"
        dim = suffix[1]
        name = name.slice(0, name.length - suffix[1].length)
    }
    var tree = parseNested(wkt)
    if (!tree) return null
    var paths = []
    var a, c

    switch (name) {
    case 'POINT':
    case 'MULTIPOINT':
        // POINT Z (x y z), MULTIPOINT ((x y), (x y)) eller MULTIPOINT (x y, x y)
        var pts = []
        for (a = 0; a < tree.length; a++)
            pts = pts.concat(Array.isArray(tree[a]) ? toCoords(tree[a], dim) : toCoords([tree[a]], dim))
        return pts.length ? { kind: 'point', points: pts } : null
    case 'LINESTRING':
    case 'CIRCULARSTRING':
    case 'COMPOUNDCURVE':
        c = name === 'LINESTRING' ? toCoords(tree, dim)
          : name === 'CIRCULARSTRING' ? arcsToCoords(toCoords(tree, dim), tol)
          : compoundToCoords(tree, dim, tol)
        paths.push({ coords: c, closed: false, poly: -1, hole: false })
        return finish('line', paths)
    case 'MULTILINESTRING':
    case 'MULTICURVE':
        for (a = 0; a < tree.length; a++)
            if (Array.isArray(tree[a]))
                paths.push({ coords: nodeToCoords(tree[a], dim, tol), closed: false, poly: -1, hole: false })
        return finish('line', paths)
    case 'POLYGON':
    case 'CURVEPOLYGON':
        addPolygon(paths, tree, 0, dim, tol)
        return finish('polygon', paths)
    case 'MULTIPOLYGON':
    case 'MULTISURFACE':
        for (a = 0; a < tree.length; a++)
            if (Array.isArray(tree[a])) addPolygon(paths, tree[a], a, tagInfo(tree[a], dim).dim, tol)
        return finish('polygon', paths)
    }
    return null
}

function addPolygon(paths, rings, polyIndex, dim, tol) {
    for (var r = 0; r < rings.length; r++) {
        if (!Array.isArray(rings[r])) continue
        paths.push({ coords: nodeToCoords(rings[r], dim, tol), closed: true, poly: polyIndex, hole: r > 0 })
    }
}

function finish(kind, paths) {
    paths = paths.filter(function (p) { return p.coords.length >= 2 })
    return paths.length ? { kind: kind, paths: paths } : null
}

function pointInRing(x, y, X, Y) {
    var inside = false
    for (var i = 0, j = X.length - 1; i < X.length; j = i++) {
        if ((Y[i] > y) !== (Y[j] > y) && x < (X[j] - X[i]) * (y - Y[i]) / (Y[j] - Y[i]) + X[i])
            inside = !inside
    }
    return inside
}

// Omräkning från kartenheter till meter runt punkten p. Projicerade koordinater
// används som de är; grader omvandlas med en lokal ekvirektangulär approximation.
function scaleFactors(p, geographic) {
    if (geographic)
        return { kx: 111320 * Math.cos(p.y * Math.PI / 180), ky: 110574 }
    return { kx: 1, ky: 1 }
}

// Hur långt punkten p ligger åt öster (e) och norr (n) om q, i meter.
function localOffset(p, q, geographic) {
    var sf = scaleFactors(q, geographic)
    return { e: (p.x - q.x) * sf.kx, n: (p.y - q.y) * sf.ky }
}

// Avstånd, riktning och höjdskillnad från positionen p till en målpunkt.
// target = {x, y, z}, p = {x, y, z}, opts = {geographic}.
// dE/dN: hur långt målet ligger åt öster/norr om p (positivt = gå åt öster/norr).
// dz = p.z - target.z, alltså samma tecken som för linjer (positivt = kap).
function analyzePoint(target, p, opts) {
    opts = opts || {}
    if (!target || !p) return null
    var sf = scaleFactors(p, opts.geographic)
    var dx = (target.x - p.x) * sf.kx
    var dy = (target.y - p.y) * sf.ky
    var dist = Math.hypot(dx, dy)
    var zt = target.z
    return {
        kind: 'point', dist: dist, offset: dist, dE: dx, dN: dy,
        bearing: (Math.atan2(dx, dy) * 180 / Math.PI + 360) % 360,
        z: isFinite(zt) ? zt : NaN,
        dz: isFinite(p.z) && isFinite(zt) ? p.z - zt : NaN,
        foot: { x: target.x, y: target.y },
        inside: false
    }
}

// p = {x, y, z}.
// opts.reverse:    analysera linjen i omvänd riktning (B -> A)
// opts.geographic: koordinaterna är grader; avstånd räknas om till meter
// opts.chosen:     {pathIndex, segIndex} – redovisa det segmentet (förlängt åt båda håll)
//                  i stället för det närmaste
// opts.collect:    {maxDist, out, cap} – samla information för alla segment med
//                  avstånd <= maxDist (max cap stycken) i out
// Positivt `offset` = punkten ligger till HÖGER om linjens färdriktning (A -> B).
// För polygoner är `offset` positiv utanför och negativ innanför.
function analyze(geom, p, opts) {
    opts = opts || {}
    if (!geom || !p) return null
    var sf = scaleFactors(p, opts.geographic)
    var kx = sf.kx, ky = sf.ky
    var best = null
    var chosen = null
    var local = []   // lokala koordinater per path (för inside-test)

    var collect = opts.collect || null
    if (collect && !collect.out) collect.out = []

    function buildInfo(pi, s, X, Y, Z, cum, total, t, dist, dx, dy, fx, fy, segLen, ext) {
        var cross = dx * (-Y[s]) - dy * (-X[s])   // >0: punkten är vänster om riktningen
        var zLo = Z[s], zHi = Z[s + 1]
        if (ext === 'start') zHi = zLo  // förlängningen ärver ändpunktens höjd
        else if (ext === 'end') zLo = zHi
        var interpZ = zLo + t * (zHi - zLo)
        return {
            pathIndex: pi, segIndex: s, t: t, dist: dist,
            offset: dist === 0 ? 0 : (cross > 0 ? -dist : dist),
            segLength: segLen,
            segFromStart: t * segLen,
            segToEnd: (1 - t) * segLen,
            fromStart: cum[s] + t * segLen,
            length: total,
            toEnd: total - (cum[s] + t * segLen),
            ext: ext ? ext : null,                       // 'start' | 'end' | null
            extDist: ext ? (ext === 'start' ? -(cum[s] + t * segLen)
                                            : (cum[s] + t * segLen) - total) : 0,
            z: isFinite(interpZ) ? interpZ : NaN,
            dz: isFinite(p.z) && isFinite(interpZ) ? p.z - interpZ : NaN,
            bearing: (Math.atan2(dx, dy) * 180 / Math.PI + 360) % 360,
            foot: { x: p.x + fx / kx, y: p.y + fy / ky },
            // aktivt segments ändpunkter i globala koordinater (för utkastning)
            segStart: { x: p.x + X[s] / kx, y: p.y + Y[s] / ky },
            segEnd: { x: p.x + X[s + 1] / kx, y: p.y + Y[s + 1] / ky },
            beforeStart: ext === 'start',
            afterEnd: ext === 'end'
        }
    }

    for (var pi = 0; pi < geom.paths.length; pi++) {
        var path = geom.paths[pi]
        var c = path.coords.slice()
        if (opts.reverse) c.reverse()
        var X = [], Y = [], Z = [], cum = [0]
        for (var k = 0; k < c.length; k++) {
            X.push((c[k].x - p.x) * kx)
            Y.push((c[k].y - p.y) * ky)
            Z.push(c[k].z)
            if (k > 0) cum.push(cum[k - 1] + Math.hypot(X[k] - X[k - 1], Y[k] - Y[k - 1]))
        }
        local.push({ X: X, Y: Y })
        var total = cum[cum.length - 1]

        for (var s = 0; s < c.length - 1; s++) {
            var ax = X[s], ay = Y[s]
            var dx = X[s + 1] - ax, dy = Y[s + 1] - ay
            var len2 = dx * dx + dy * dy
            if (len2 === 0) continue
            // punkten är origo => vektor a->p = (-ax, -ay)
            var t0 = (-ax * dx + -ay * dy) / len2
            // förlängning förbi start/slut (ej för slutna ringar)
            // Ett låst (valt) segment förlängs åt båda håll, även mitt på linjen
            // och i polygoner, så att det beter sig som en linje med ett segment.
            var isChosen = !!(opts.chosen && opts.chosen.pathIndex === pi && opts.chosen.segIndex === s)
            var ext = null
            if (isChosen) {
                if (t0 < 0) ext = 'start'
                else if (t0 > 1) ext = 'end'
            } else if (!path.closed) {
                if (s === 0 && t0 < 0) ext = 'start'
                else if (s === c.length - 2 && t0 > 1) ext = 'end'
            }
            var t = t0
            if (t < 0) t = 0
            if (t > 1) t = 1
            if (ext) t = t0
            var fx = ax + t * dx, fy = ay + t * dy
            var dist = Math.hypot(fx, fy)
            var info = buildInfo(pi, s, X, Y, Z, cum, total, t, dist, dx, dy, fx, fy, Math.sqrt(len2), ext)
            if (best === null || dist < best.dist)
                best = info
            if (isChosen)
                chosen = info
            if (collect && dist <= collect.maxDist && collect.out.length < collect.cap)
                collect.out.push(info)
        }
    }
    var res = chosen || best
    if (res === null) return null
    res.kind = geom.kind
    res.inside = false
    if (geom.kind === 'polygon') {
        var inPoly = {}
        for (var i = 0; i < geom.paths.length; i++) {
            var gp = geom.paths[i]
            var hit = pointInRing(0, 0, local[i].X, local[i].Y)
            if (!hit) continue
            if (gp.hole) inPoly[gp.poly] = false
            else if (inPoly[gp.poly] !== false) inPoly[gp.poly] = true
        }
        for (var key in inPoly) if (inPoly[key]) res.inside = true
        res.offset = res.inside ? -res.dist : res.dist
    }
    return res
}

function fmt(v, decimals) {
    if (v === null || v === undefined || !isFinite(v)) return '–'
    return v.toFixed(decimals === undefined ? 3 : decimals).replace('.', ',')
}
