# Linjeavstånd – QField-plugin

Visar live (från GNSS) avståndet till en vald linje eller polygon, ungefär som
linjeutsättning i Emlid Flow och SurPad:

| Ruta | Betydelse |
|---|---|
| **Från A / Till B** | avstånd längs linjen från start (A) till närmaste punkt, och därifrån till slutet (B) |
| **Segment** | avstånd från närmaste punkt till start/slut på det närmaste segmentet, samt segmentnummer |
| **Offset** | vinkelrätt avstånd till linjen, med sida (höger/vänster om A→B) |
| **Höjd** | GNSS-höjd minus linjens (interpolerade) Z – över/under; kräver Z-linje. Båda höjderna visas som siffror under |
| Polygon | avstånd till närmaste kant + innanför/utanför |

En streckad röd linje ritas i kartan från din position till närmaste punkt på linjen.

## Användning
1. Installera zip-filen via QFields plugin-hanterare (*Installera plugin från URL/fil*) och aktivera den.
2. Tryck på plugin-knappen i verktygsfältet → panelen öppnas.
3. **⌖ Välj**, peka sedan på en linje/polygon i kartan (närmaste inom ~30 px, alla vektorlager).
4. **⇅ Vänd** byter A/B. **Rensa** tar bort valet.

## Begränsningar
- Rak linjesegmentgeometri; kurvor (CircularString/CompoundCurve) stöds inte än.
- Höjden är den som QField rapporterar (`positionInformation.elevation`); stativ-/antennhöjd räknas inte av.
- Avstånd i projektets enhet (meter för projicerade CRS); för geografiska CRS räknas grader om lokalt.
- Val görs bland alla vektorlager, även dolda.

## Utveckling
- `geometry.js` är ren JS utan QField-beroenden: `node tests/test_geometry.js`.
- Bygg zip: `python3 build.py` → `dist/line-distance-v<version>.zip`.
- Nästa steg i rq.md: utsättning av väglinjer (klotoider/övergångskurvor) – kräver egen geometrimodell.
