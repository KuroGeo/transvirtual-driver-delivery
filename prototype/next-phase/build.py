"""Build the isolated, disposable next-phase interaction prototype."""
import csv
import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
source = (HERE.parent / "index.html").read_text()
rows = list(csv.DictReader((ROOT / "app/assets/deliveries.csv").open()))
for index, row in enumerate(rows, 1):
    row.update(latitude=float(row["latitude"]), longitude=float(row["longitude"]), index=index)
# Fictional business labels for the four scripted stops, using public demo coordinates.
labels = {"TV-300016": "Banksia Medical", "TV-300021": "Wattle Corner Store",
          "TV-300022": "Paperbark Studio", "TV-300017": "Acacia Supplies"}
for row in rows:
    if row["status"] == "pending" and row["reference"] not in labels:
        row["time_window"] = "12:00-18:00"
    if row["reference"] in labels:
        row["customer_name"] = labels[row["reference"]]
        row["address"] = {"TV-300016": "16 Banksia Lane, Sydney NSW",
                          "TV-300021": "21 Wattle Street, Sydney NSW",
                          "TV-300022": "22 Paperbark Road, Sydney NSW",
                          "TV-300017": "17 Acacia Avenue, Sydney NSW"}[row["reference"]]
        if row["reference"] != "TV-300021":
            row["time_window"] = "10:00-12:00"
source = re.sub(r"window.DELIVERIES=\[.*?\];", "window.DELIVERIES=" + json.dumps(rows) + ";", source, count=1)
source = re.sub(r'(href|src)="(assets/|vendor/)', r'\1="../\2', source)
source = source.replace("</head>", '<link rel="stylesheet" href="next.css"><script src="next.js"></script></head>')
source = source.replace('src="../assets/app.js"', 'src="base-app.js"')
source = source.replace('data-variant="a"', 'data-variant="next-phase"')
source = source.replace('<title>ocean delivery · Delivery map</title>', '<title>Ocean Delivery · Next phase prototype</title>')
source = source.replace('x-show="detailOpen"', 'x-show="detailOpen && !nextPanel"')
source = source.replace('x-show="toast && !failureOpen', 'x-show="toast && !nextPanel && !failureOpen')
source = source.replace('<span>9:41</span>', '<span>9:42</span>')
source = source.replace('<p>Sydney <span aria-hidden="true">·</span> <span x-text="stops.length">30</span> stops</p>',
                        '<p><span x-text="sessionName"></span> <span aria-hidden="true">·</span> Sydney run</p>')
source = source.replace('<div class="top-tools">', '<div class="top-tools"><button class="profile-trigger" @click="nextPanel=\'profile\'" aria-label="Your account">JD</button>', 1)
source = source.replace('<span class="nearest-caption">Nearest stop</span>', '<span class="nearest-caption" x-text="planApplied?\'Next planned stop\':\'Nearest stop\'">Nearest stop</span>')
source = source.replace('<footer class="stop-card-actions">', '<footer class="stop-card-actions"><button class="navigate-stop" @click="previewNavigation()" aria-label="Navigate to this stop"><span class="navigation-arrow" aria-hidden="true">↗</span> Navigate to this stop <span class="nav-meta" x-text="selected.reference===urgentId?\'12 min · 6.3 km\':\'View route\'"></span></button>')
source = source.replace('<span class="home-indicator map-home-indicator"',
                        (HERE / "panels.html").read_text() + '\n<span class="home-indicator map-home-indicator"')
(HERE / "phone.html").write_text(source)
base = (HERE.parent / "assets/app.js").read_text()
base = base.replace("Alpine.data('deliveryApp',()=>({", "Alpine.data('deliveryApp',()=>{const base={", 1)
assert base.rstrip().endswith("}));\n});")
base = base.rstrip()[:-len("}));\n});")] + "};return window.enhanceDeliveryPrototype(base);});\n});\n"
(HERE / "base-app.js").write_text(base)
print("Built next-phase/phone.html from the existing map prototype and public demo data.")
