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
                items.push(group())
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

// Returnerar { kind: 'line'|'polygon', paths: [{coords, closed, poly, hole}] } eller null
function parseWkt(wkt) {
    if (!wkt) return null
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
    if (name === 'LINESTRING') {
        paths.push({ coords: toCoords(tree, dim), closed: false, poly: -1, hole: false })
        return finish('line', paths)
    }
    if (name === 'MULTILINESTRING') {
        for (var a = 0; a < tree.length; a++)
            if (Array.isArray(tree[a])) paths.push({ coords: toCoords(tree[a], dim), closed: false, poly: -1, hole: false })
        return finish('line', paths)
    }
    if (name === 'POLYGON') {
        addPolygon(paths, tree, 0, dim)
        return finish('polygon', paths)
    }
    if (name === 'MULTIPOLYGON') {
        for (var p = 0; p < tree.length; p++)
            if (Array.isArray(tree[p])) addPolygon(paths, tree[p], p, dim)
        return finish('polygon', paths)
    }
    return null
}

function addPolygon(paths, rings, polyIndex, dim) {
    for (var r = 0; r < rings.length; r++) {
        if (!Array.isArray(rings[r])) continue
        paths.push({ coords: toCoords(rings[r], dim), closed: true, poly: polyIndex, hole: r > 0 })
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

// p = {x, y, z}. opts = {reverse, geographic}
// Positivt `offset` = punkten ligger till HÖGER om linjens färdriktning (A -> B).
// För polygoner är `offset` positiv utanför och negativ innanför.
function analyze(geom, p, opts) {
    opts = opts || {}
    if (!geom || !p) return null
    var kx = 1, ky = 1
    if (opts.geographic) {
        kx = 111320 * Math.cos(p.y * Math.PI / 180)
        ky = 110574
    }
    var best = null
    var local = []   // lokala koordinater per path (för inside-test)

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
            var t = (-ax * dx + -ay * dy) / len2
            if (t < 0) t = 0
            if (t > 1) t = 1
            var fx = ax + t * dx, fy = ay + t * dy
            var dist = Math.hypot(fx, fy)
            if (best === null || dist < best.dist) {
                var cross = dx * (-ay) - dy * (-ax)   // >0: punkten är vänster om riktningen
                var segLen = Math.sqrt(len2)
                var z = (isFinite(Z[s]) && isFinite(Z[s + 1])) ? Z[s] + t * (Z[s + 1] - Z[s]) : NaN
                best = {
                    pathIndex: pi, segIndex: s, t: t, dist: dist,
                    offset: dist === 0 ? 0 : (cross > 0 ? -dist : dist),
                    segLength: segLen,
                    segFromStart: t * segLen,
                    segToEnd: (1 - t) * segLen,
                    fromStart: cum[s] + t * segLen,
                    length: total,
                    toEnd: total - (cum[s] + t * segLen),
                    z: z,
                    dz: (isFinite(p.z) && isFinite(z)) ? p.z - z : NaN,
                    bearing: (Math.atan2(dx, dy) * 180 / Math.PI + 360) % 360,
                    foot: { x: p.x + fx / kx, y: p.y + fy / ky },
                    beforeStart: !path.closed && s === 0 && t === 0,
                    afterEnd: !path.closed && s === c.length - 2 && t === 1
                }
            }
        }
    }
    if (best === null) return null
    best.kind = geom.kind
    best.inside = false
    if (geom.kind === 'polygon') {
        var inPoly = {}
        for (var i = 0; i < geom.paths.length; i++) {
            var gp = geom.paths[i]
            var hit = pointInRing(0, 0, local[i].X, local[i].Y)
            if (!hit) continue
            if (gp.hole) inPoly[gp.poly] = false
            else if (inPoly[gp.poly] !== false) inPoly[gp.poly] = true
        }
        for (var key in inPoly) if (inPoly[key]) best.inside = true
        best.offset = best.inside ? -best.dist : best.dist
    }
    return best
}

function fmt(v, decimals) {
    if (v === null || v === undefined || !isFinite(v)) return '–'
    return v.toFixed(decimals === undefined ? 3 : decimals).replace('.', ',')
}
