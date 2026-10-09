# Third-party resources

- Carbon icons by IBM: https://github.com/carbon-design-system/carbon — Apache-2.0. Icons sourced through Iconify's Carbon collection: https://github.com/iconify/icon-sets/blob/master/json/carbon.json . Cached locally in `icons.json`, embedded in the generated HTML. No Carbon brand logo is used. License in `CARBON-LICENSE`.
- Alpine.js: https://github.com/alpinejs/alpine — MIT. Vendored from the installed Oil UI skill's `assets/vendor/alpine.min.js`; license in `../vendor/ALPINE-LICENSE`.
- Oil UI comparison-page generator: https://github.com/oil-oil/oil-ui — MIT. Generates `style-explorer.html` from `manifest.json`; locally adjusted default mobile viewport and scheme-number text contrast. License in `../vendor/OIL-UI-LICENSE`.

- Inter Variable by Rasmus Andersson: https://github.com/rsms/inter — SIL Open Font License 1.1. The font is vendored from Google Fonts; license in `Inter-OFL.txt`. Used by the round-two layout, served locally and embedded in the comparison artifact.

No network-loaded fonts, tracking, or external paid asset service is used. The ocean delivery App icon is generated with the built-in image-generation tool and served locally; source and selection are documented in `app-icon-design.md`.

- Leaflet 1.9.4: https://leafletjs.com/ and https://github.com/Leaflet/Leaflet — BSD-2-Clause. JavaScript, styles and standard marker assets served locally from `vendor/leaflet/`; license in `vendor/leaflet/LICENSE`.
- Leaflet.markercluster 1.5.3: https://github.com/Leaflet/Leaflet.markercluster — MIT. JavaScript and cluster base styles served locally; license in `vendor/leaflet/MARKERCLUSTER-LICENSE`. Status rings are custom to this prototype.
- OpenStreetMap: https://www.openstreetmap.org/copyright — map data © OpenStreetMap contributors, ODbL. The live standard raster tile layer uses `https://tile.openstreetmap.org/{z}/{x}/{y}.png` with visible attribution, browser referrer and ordinary cache behaviour. No tile prefetch, scraping or offline map bundle. Policy: https://operations.osmfoundation.org/policies/tiles/ . Tiles need an internet connection; the stop data and offline delivery workflow remain available when the background fails.
