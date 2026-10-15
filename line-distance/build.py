import configparser, os, zipfile
here = os.path.dirname(os.path.abspath(__file__))
cfg = configparser.ConfigParser(); cfg.read(os.path.join(here, 'metadata.txt'))
version = cfg['general']['version']
os.makedirs(os.path.join(here, 'dist'), exist_ok=True)
out = os.path.join(here, 'dist', f'line-distance-v{version}.zip')
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for f in ('main.qml', 'geometry.js', 'metadata.txt', 'icon.svg'):
        z.write(os.path.join(here, f), f)
print(out)
