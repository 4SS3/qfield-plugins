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

// Returnerar { kind: 'line'|'polygon', paths: [{coords, closed, poly, hole}] } eller null.
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
