# SE.Live Vertical Scene Tool

Duplicate (and rename) scenes on **SE.Live multistreaming canvases** (vertical canvas for TikTok, YouTube Shorts, etc.) — something the SE.Live dock still can't do.

**v3.0** — updated for **SE.Live core 26.9.4 / OBS Studio 33.0** (October 2026).

## The problem

If you multistream with SE.Live you've probably hit these walls:

- **No "duplicate scene"** on the vertical canvas: every new scene must be rebuilt from scratch — webcam, logo, overlays, positions, all of it.
- **Renaming doesn't stick**: you rename a scene in the dock, and the old name comes back.

## What we found (the short version)

SE.Live does **not** store canvas scenes in the OBS scene collection. Each canvas lives in its own "composition" JSON file:

```
%AppData%\obs-studio\plugin_config\obs-streamelements-core\scoped_config_storage\streamelements_multi-streaming\compositions\
```

SE.Live reads that file on startup and rewrites it while OBS runs and on shutdown. Editing it with OBS closed works — that's what this tool automates, **surgically**: it never rewrites the file, it only splices in the duplicated scene (every other byte stays 100% identical, verified on every run).

Since SE.Live 26.x the canvas is also registered as a native OBS 33 canvas (you'll see `🚀 SE.Live: Vertical` in the scene collection), but its scenes still live only in the composition file. The current format links every scene entry back to its scene (`sceneId`) and canvas (`videoCompositionId`), and filters carry ids too. v3 gives the copy a fresh scene id and fresh entry ids and keeps filter ids as they are: filters belong to the shared source, so SE.Live itself writes the same filter id in every scene that uses that source.

**But there's a second actor.** SE.Live also keeps scene state of its own (dock/web-app state), and reconciles it with the file at startup. In our testing (July 2026 build) this:

- forces the **first scene of the canvas** to be named "Scene 1" (renames revert, deleting it makes it respawn);
- can **remove or re-label scenes** whose identity conflicts with it (we lost a scene this way — recovered from backups).

Scenes created with **brand-new names survive reliably**. That's the foundation of the golden rules below. A detailed bug report for the SE.Live developers is included in this repo (`bug-report.md`).

**On 26.9.4 (October 2026, five OBS restarts):**

- Duplicated scenes load in the dock, keep their position in the list and survive SE.Live re-saving the file. Scenes deleted with the tool stay deleted.
- Copies may reuse a name that also exists on the main canvas, even as the active scene: a vertical "Fortnite" next to the horizontal "Fortnite" stays "Fortnite".
- **The first scene of the canvas is the exception.** Its name in the file "Valorant" was shown as "Valorant 1" after a restart, and renaming it back in the file never sticks. If the file already says "Valorant 1", it stays like that. SE.Live decides that name itself (same reconciliation as above, now adding " 1" instead of forcing "Scene 1"). The tool warns you, and you should rename the first scene from the dock.
- Nothing about these names is stored on disk outside the composition file. SE.Live works them out again at every startup.

The `ptr(...)` ids in the file are just memory addresses of the last session: SE.Live reassigns all of them at every startup. The tool only has to keep them unique inside the file, which it does.

## Golden rules (read before using)

1. **Leave the first scene's name to SE.Live.** It may show up as "Scene 1" or "<name> 1" and renames of it don't stick. Use it like any other scene, but rename it only from the dock, and never link it.
2. **Always duplicate using brand-new names** — names never used before on that canvas (names from the main canvas are fine).
3. **Avoid renaming scenes OBS has already seen.** The rename feature works at file level, but SE.Live may revert it. If you got a name wrong, duplicate with the right name instead and delete the old one.
4. **Delete with the tool rather than from the dock.** Deleting scenes from the dock is what triggered the scene loss in our July testing. The tool's Delete (with OBS closed) cuts exactly that scene out of the file, after a backup, and refuses to delete the canvas's active scene.
5. The tool makes a **timestamped backup before every change** — and can restore any of them in one click.

## What the tool does

1. Gracefully closes OBS if it's running (it also tries a graceful close when OBS is minimized to the tray; if OBS runs as administrator it asks you to close it) and waits until SE.Live has finished saving
2. Auto-detects your composition files (or lets you browse to one — portable setups included)
3. Four operations:
   - **Duplicate** — pick a scene and type one or more new names (one per line) to make several copies at once. Same sources, positions, crops, filters. The copies go right after the original, in the order you typed them (untick the box to append them at the end instead).
   - **Rename** — see rules 1 and 3.
   - **Delete** — removes one scene from the canvas (its sources stay in OBS). Not allowed on the active scene.
   - **Restore backup** — pick a backup by date (it shows which scenes it contains) and put it back. The current state is backed up first, so a restore can be undone too.
4. Validates the result before writing — if anything looks wrong, the file is not touched:
   - all bytes outside the scene being added/removed/renamed are identical to the original,
   - a copy is identical to the original scene apart from name and ids,
   - scene and entry ids stay unique and every entry points to the right scene and canvas.
5. Refuses to work on a file whose format it doesn't recognize (in case a future SE.Live update changes it again), and refuses to write if OBS was reopened or the file changed in the meantime
6. Writes atomically (temp file + swap), reads the result back, and reopens OBS for you

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
   - If OBS is set to **run as administrator** (common for game capture), Windows doesn't let a normal program close it: the tool tells you, you close OBS yourself (File → Exit) and press OK. When the tool reopens OBS, Windows asks for the usual admin confirmation.
4. In the window: choose **Duplicate**, pick the canvas and the scene, type one or more brand-new names (one per line), click the button. (Delete, Rename and Restore backup work the same way.)
5. OBS reopens — check the canvas dock.

### Command line (optional, e.g. for Stream Deck)

```
powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -List
powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -Scene "Valorant" -NewName "Apex"
powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -Scene "Valorant" -NewName "Apex|Fortnite|Variety"
powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -Rename -Scene "Old Name" -NewName "New Name"
powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -Delete -Scene "Old test"
powershell -ExecutionPolicy Bypass -File .\SELive-Vertical-Scene-Tool.ps1 -NoGui -RestoreFrom "<path to a .bak_ file>"
```

- `-List` prints canvases, scenes (`*` = active) and backup count; read-only, works with OBS open.
- `-NewName "A|B|C"` makes several copies in one go (one backup for the whole batch); they go right after the original, or at the end with `-AtEnd`.
- `-Canvas <name>` or `-File <path>` picks the canvas when you have more than one.
- `-Force` lets the command line close OBS gracefully for you (otherwise it stops if OBS is running).
- `-NoRestart` doesn't reopen OBS afterwards.

## Backups and how to restore

Every operation creates a copy like `<file>.json.bak_20261028_112035305` next to the composition file. Easiest way back: run the tool, choose **Restore backup**, pick the date. By hand: close OBS, copy the backup over the `.json` (same filename), reopen OBS.

Backups are never deleted by the tool; clean up old ones yourself when the folder gets crowded.

## Disclaimer

Unofficial community tool, **not affiliated with StreamElements or the OBS Project**. The composition file format and the reconciliation behavior were reverse-engineered (SE.Live core 26.9.4 / OBS 33.0, October 2026) and may change in future updates — the tool checks the format and stops if it doesn't recognize it. A backup is always created before writing, but use at your own risk. License: MIT.

And please upvote the official feature request for native duplicate/clone — that, plus a fix for the behavior described in `bug-report.md`, is the real solution. This tool fills the gap until then.
