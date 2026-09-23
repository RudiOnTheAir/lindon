# tools/

Station-side Python tooling for Radio Ostfriesland / Radio Rudi, built to
replace the legacy Rivendell v3 cron scripts around import and log/playlist
handling. Kept in this repo alongside `lindon-install.sh` since it's the
same station infrastructure, just the operational side rather than the
system setup side.

Planned/upcoming:

- `rdreadm3u.py` -- imports M3U playlists (e.g. from Station Playlist
  Creator) into Rivendell: dedupes by content hash, runs audio through
  StereoTool when configured, and writes Artist/Title via Rivendell's own
  proprietary WAV `list` chunk (the only metadata rdimport actually reads
  for WAV sources -- not ID3, not standard RIFF INFO).
- `slotswap.py` -- VP slot management.
- A future log-writer tool that writes Rivendell `LOG_LINES` directly via
  SQL, replacing the last piece of the old v3 cron pipeline.

Each script is meant to stay self-contained (no shared modules) and
console/cron-friendly -- no WebUI, minimal dependencies, copy-pasteable
commands.
