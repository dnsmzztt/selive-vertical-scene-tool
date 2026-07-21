# SE.Live Vertical Scene Tool

Duplicate (and rename) scenes on **SE.Live multistreaming canvases** (vertical canvas for TikTok, YouTube Shorts, etc.) — something the SE.Live dock currently can't do.

## The problem

If you multistream with SE.Live you've probably hit these walls:

- **No "duplicate scene"** on the vertical canvas: every new scene must be rebuilt from scratch — webcam, logo, overlays, positions, all of it.
- **Renaming doesn't stick**: you rename a scene in the dock, and the old name comes back.

## What we found (the short version)

SE.Live does **not** store canvas scenes in the OBS scene collection. Each canvas lives in its own "composition" JSON file:

```
%AppData%\obs-studio\plugin_config\obs-streamelements-core\scoped_config_storage\streamelements_multi-streaming\compositions\
```

SE.Live reads that file on startup and rewrites it on shutdown. Editing it with OBS closed works — that's what this tool automates, **surgically**: it never rewrites the file, it only splices in the duplicated scene (every other byte stays 100% identical, verified).

**But there's a second actor.** SE.Live also keeps a hidden scene registry of its own (dock/web-app state), and reconciles it with the file at startup. In our testing this registry:

- forces the **first scene of the canvas** to be named "Scene 1" (renames revert, deleting it makes it respawn);
- can **remove or re-label scenes** whose identity conflicts with it (we lost a scene this way — recovered from backups).

Scenes created with **brand-new names survive reliably**. That's the foundation of the golden rules below. A detailed bug report for the SE.Live developers is included in this repo (`bug-report.md`).

## Golden rules (read before using)

1. **Treat the first scene as sacrificial.** SE.Live wants it to be "Scene 1" and will enforce it. Keep it empty, never put real content in it, never link it, never go live on it. If it respawns after a duplication: ignore it or empty it, don't fight it.
2. **Always duplicate using brand-new names** — names never used before on that canvas.
3. **Avoid renaming scenes OBS has already seen.** The rename feature works at file level, but the hidden registry may revert it. If you got a name wrong, duplicate with the right name instead.
4. **Go easy on deletions.** Deleting scenes from the dock is what triggered the scene loss in our testing. When you must delete, do it, close OBS, and make a manual copy of the `compositions` folder before doing anything else.
5. The tool makes a **timestamped backup before every change** — that's your safety net. Keep recent ones.

## What the tool does

1. Gracefully closes OBS if it's running (SE.Live saves its state on shutdown)
2. Auto-detects your composition files (or lets you browse to one — portable setups included)
3. Lets you pick a scene from a dropdown and **Duplicate** it (same sources, positions, crops, filters) or **Rename** it (see rule 3)
4. Validates the result before writing — if anything looks wrong, the file is not touched
5. Creates a timestamped backup next to the file before every change
6. Reopens OBS for you

Duplicated scenes share the same underlying sources as the original (webcam, browser sources, logos...), so you only need to swap the game capture and you're done.

## Requirements

- Windows 10/11
- OBS Studio with SE.Live installed and at least one canvas created
- PowerShell (built into Windows — nothing to install)

## How to use

1. Download **both files** into the same folder (Desktop is fine):
   - `SELive Scene Tool.bat`
   - `SELive-Vertical-Scene-Tool.ps1`
2. Double-click **`SELive Scene Tool.bat`**.
   - If Windows SmartScreen warns you, click *More info → Run anyway*. Both files are plain-text scripts — feel free to read the source.
3. If OBS is open, the tool asks permission to close it (answer any OBS confirmation dialog on screen if one appears).
4. In the window: choose **Duplicate**, pick the canvas and the scene, type a brand-new name, click the button.
5. OBS reopens — check the canvas dock.

### Command line (optional, e.g. for Stream Deck)

```
powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -Scene "FF8 - Vertical" -NewName "Apex - Vertical"
powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -Rename -Scene "Old Name" -NewName "New Name"
```

Extra switches: `-File <path>` to target a specific composition file, `-NoRestart`, `-Force` (skip the OBS-running check — not recommended).

## Backups and how to restore

Every operation creates a copy like `<file>.json.bak_20260721_0852...` next to the composition file. To roll back: close OBS, delete (or move away) the current `.json`, copy the backup and rename it to the original filename, reopen OBS.

## Disclaimer

Unofficial community tool, **not affiliated with StreamElements or the OBS Project**. The composition file format and the reconciliation behavior were reverse-engineered (SE.Live as of July 2026) and may change in future updates. A backup is always created before writing, but use at your own risk. License: MIT.

And please upvote the official feature request for native duplicate/clone — that, plus a fix for the registry behavior described in `bug-report.md`, is the real solution. This tool fills the gap until then.
