# Ventana

A small tabbed web browser for [KOReader](https://github.com/koreader/koreader), made for e-ink.

Pages are fetched, cleaned of scripts, ads and chrome, then laid out with MuPDF to fit the screen. You turn them like a book.

- **Tabs** (up to 12), back/forward, bookmarks and history. They are kept across restarts.
- **Reader mode** strips a page down to the article.
- **Address bar** takes a URL or search words (DuckDuckGo Lite). Prefixes jump to Wikipedia: `w Byzantium` for English, `es …`, `fr …`, and so on.
- Lighter versions of heavy sites, e.g. Wikipedia's `action=render`.
- Images are converted to grayscale, and pages are cached on disk.
- **Hold a word** to look it up in the dictionary. Hold a link for open-in-new-tab and other options.
- Gzip support, and an honest User-Agent. Sites that require JavaScript or block bots get a clear explanation page instead of a broken one.

Pure Lua. It needs no extra binaries and uses KOReader's own LuaSocket/LuaSec and MuPDF.

## Install
Copy this folder to `koreader/plugins/ventana.koplugin/` and restart KOReader. Open it from the main menu (*Web browser*), from a gesture (*Web browser (Ventana)*), or from the Web button in Estante's dock.

## Extras
`extras/2-wifi-auto.lua` is a userpatch: copy it to `koreader/patches/`. It turns Wi-Fi on without the "Turn on Wi-Fi?" prompt when Ventana, Z-library or the AI Assistant needs the network.
