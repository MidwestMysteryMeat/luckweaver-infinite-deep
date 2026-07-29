# Audio removed — licensing

The music/SFX that lived in this folder were curated from purchased packs
licensed to the project owner only, so they are **not in the repo**.
audio_mgr.gd expects the files at these same paths; fresh clones run
silent. Originals live on the owner's dev machine (audio/ packs, also
gitignored) and ship inside the exported exe.

To supply your own sounds, see `ASSETS_NEEDED.md` at the repo root — it
lists every expected file name, the event that triggers it, and format
notes. Drop matching `.wav` files into this folder and they are picked up
automatically (no code changes needed).
