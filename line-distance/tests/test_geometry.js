// Kör: node tests/test_geometry.js
const fs = require('fs'), path = require('path'), assert = require('assert')
const src = fs.readFileSync(path.join(__dirname, '..', 'geometry.js'), 'utf8').replace(/^\.pragma library\s*$/m, '')
const G = new Function(src + '; return {parseWkt, analyze, fmt}')()
const near = (a, b, m) => assert.ok(Math.abs(a - b) < 1e-9, `${m}: ${a} != ${b}`)

// Rak linje A(0,0) -> B(10,0), punkt 2 m söder (höger om riktningen)
let g = G.parseWkt('LineString (0 0, 10 0)')
let r = G.analyze(g, { x: 4, y: -2, z: NaN })
near(r.offset, 2, 'offset höger'); near(r.fromStart, 4, 'från A'); near(r.toEnd, 6, 'till B'); near(r.length, 10, 'längd')
assert.ok(isNaN(r.dz), 'ingen Z -> NaN')

// 2 m norr = vänster => negativt tecken
r = G.analyze(g, { x: 4, y: 2, z: NaN })
near(r.offset, -2, 'offset vänster')

// Vänd riktning: höger blir vänster, A/B byter plats
r = G.analyze(g, { x: 4, y: -2, z: NaN }, { reverse: true })
near(r.offset, -2, 'reverse offset'); near(r.fromStart, 6, 'reverse från A'); near(r.toEnd, 4, 'reverse till B')

// Segmentmått: andra segmentet i en knäckt linje, 3 m in på segmentet
const gSeg = G.parseWkt('LineString (0 0, 10 0, 10 10)')
r = G.analyze(gSeg, { x: 11, y: 3, z: NaN })
assert.strictEqual(r.segIndex, 1); near(r.segLength, 10, 'segmentlängd'); near(r.segFromStart, 3, 'segment från start'); near(r.segToEnd, 7, 'segment till slut')

// Bortom slutet: klampas till ändpunkten, flagga afterEnd
r = G.analyze(g, { x: 13, y: 4, z: NaN })
near(r.dist, 5, 'dist till ändpunkt'); assert.ok(r.afterEnd); assert.ok(!r.beforeStart); near(r.toEnd, 0, 'toEnd=0')

// 3D-linje: Z interpoleras, dz = GNSS - linje
g = G.parseWkt('LineStringZ (0 0 100, 10 0 110)')
r = G.analyze(g, { x: 5, y: 1, z: 107.5 })
near(r.z, 105, 'interpolerad z'); near(r.dz, 2.5, 'dz över'); 
g = G.parseWkt('LineString Z (0 0 100, 10 0 110)')
assert.ok(isFinite(G.analyze(g, { x: 5, y: 1, z: 100 }).z), 'mellanslag före Z')
g = G.parseWkt('LineStringM (0 0 5, 10 0 9)')
assert.ok(isNaN(G.analyze(g, { x: 5, y: 1, z: 100 }).z), 'M är inte Z')

// Flerdelad linje: närmaste del väljs, längd/kedja per del
g = G.parseWkt('MultiLineString ((0 0, 10 0),(0 10, 10 10))')
r = G.analyze(g, { x: 5, y: 9, z: NaN })
assert.strictEqual(r.pathIndex, 1); near(r.dist, 1, 'närmaste del')

// Polylinje med knäck: kedja ackumuleras
g = G.parseWkt('LineString (0 0, 10 0, 10 10)')
r = G.analyze(g, { x: 12, y: 5, z: NaN })
near(r.fromStart, 15, 'kedja över knäck'); near(r.toEnd, 5, 'rest'); near(r.offset, 2, 'offset höger (nedåt->svänger höger)')

// Polygon: inne/ute, hål
g = G.parseWkt('Polygon ((0 0, 10 0, 10 10, 0 10, 0 0))')
r = G.analyze(g, { x: 1, y: 5, z: NaN }); assert.ok(r.inside); near(r.offset, -1, 'innanför negativ')
r = G.analyze(g, { x: -3, y: 5, z: NaN }); assert.ok(!r.inside); near(r.offset, 3, 'utanför positiv')
g = G.parseWkt('Polygon ((0 0, 10 0, 10 10, 0 10, 0 0),(4 4, 6 4, 6 6, 4 6, 4 4))')
r = G.analyze(g, { x: 5, y: 5, z: NaN }); assert.ok(!r.inside, 'i hålet = utanför'); near(r.dist, 1, 'avstånd till hålkant')
g = G.parseWkt('MultiPolygon (((0 0, 4 0, 4 4, 0 4, 0 0)),((10 0, 14 0, 14 4, 10 4, 10 0)))')
r = G.analyze(g, { x: 12, y: 2, z: NaN }); assert.ok(r.inside)

// Geografiska grader: 0.001 grader lat ≈ 110.6 m
g = G.parseWkt('LineString (18 59, 18.01 59)')
r = G.analyze(g, { x: 18.005, y: 59.001, z: NaN }, { geographic: true })
assert.ok(Math.abs(r.dist - 110.574) < 0.01, 'grader -> meter: ' + r.dist)

// Ogiltigt / ej stödda
assert.strictEqual(G.parseWkt('Point (1 2)'), null)
assert.strictEqual(G.parseWkt('LineString EMPTY'), null)
assert.strictEqual(G.parseWkt(''), null)
assert.strictEqual(G.fmt(NaN), '–'); assert.strictEqual(G.fmt(1.2555, 3), '1,256')
console.log('Alla tester ok')
