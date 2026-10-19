# Journal - Howard J (Part 1)

> AI development session journal
> Started: 2026-10-14

---



## Session 1: Redesign the torrent list rows

**Date**: 2026-10-18
**Task**: Redesign the torrent list rows
**Branch**: `main`

### Summary

Torrent row redesign: state dot + 2-line name, full-width 7pt progress bar with monospaced percentage, one detail line built from the new pure TorrentSummary.infoSegments (zero speeds omitted, both directions shown when both move, state-word fallback), localized state words in both tables, and a --preview-panel fixture render mode for light/dark screenshots.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `c5d9be7` | (see git log) |
| `9178b2f` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 2: qBittorrent 5.2 login fix

**Date**: 2026-10-19
**Task**: qBittorrent 5.2 login fix
**Branch**: `main`

### Summary

qBittorrent 5.2 moved the login verdict to the status code (204 success / 401 failure); loginFailure() only knew the <=5.1 200 "Ok."/"Fails." bodies, so every login against a 5.2 server failed with HTTP 204. Parser now accepts both generations, selftest covers 204/401/blank-200, the stub WebUI speaks 5.2 via WEBAPI=5.2, and spec 4.1 documents the version table.

### Main Changes

- Detailed change bullets were not supplied; see the summary above.

### Git Commits

| Hash | Message |
|------|---------|
| `37cfe6b` | (see git log) |

### Testing

- Validation was not recorded for this session.

### Status

[OK] **Completed**

### Next Steps

- None - task complete
