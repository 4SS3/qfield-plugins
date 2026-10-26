#!/usr/bin/env python3
"""Build dist/line-distance-v<version>.zip from the files in this folder."""
import os, re, sys, zipfile

here = os.path.dirname(os.path.abspath(__file__))
files = ["main.qml", "geometry.js", "metadata.txt", "icon.svg"]
missing = [f for f in files if not os.path.exists(os.path.join(here, f))]
if missing:
    sys.exit("Missing files: " + ", ".join(missing))

meta = open(os.path.join(here, "metadata.txt"), encoding="utf-8").read()
version = re.search(r"^version=(.+)$", meta, re.M).group(1).strip()

os.makedirs(os.path.join(here, "dist"), exist_ok=True)
out = os.path.join(here, "dist", "line-distance-v%s.zip" % version)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in files:
        z.write(os.path.join(here, f), f)   # files at the root of the zip
print("Built", out)
