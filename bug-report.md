# [Bug] Multistreaming canvas: hidden scene-state reconciliation forces "Scene 1", reverts renames, and can remove scenes

## Environment

- OBS Studio: latest stable as of July 2026 (64-bit, Windows 11)
- SE.Live / obs-streamelements-core: latest available as of July 2026
- Canvas: vertical 1080x1920, `isObsNativeComposition: false`, `view: "custom"`
- Dual streaming Twitch (horizontal) + TikTok (vertical)

## Summary

The vertical canvas scenes are persisted in
`%AppData%\obs-studio\plugin_config\obs-streamelements-core\scoped_config_storage\streamelements_multi-streaming\compositions\<id>.json`,
but the plugin also appears to keep a separate scene-state store (dock web-app state) and reconciles the two at startup. This reconciliation:

1. **Reverts renames of the canvas's first/default scene.** Renaming "Scene 1" (via the dock or by editing the composition file with OBS closed) does not stick: on a later startup the scene at the head of the list is forcibly re-labeled "Scene 1".
2. **Respawns "Scene 1"** as a new empty scene if the user deletes it, whenever the composition file is modified externally between sessions.
3. **Can remove scenes.** In one reproducible sequence (details below), a scene that had originally been created as "Scene 1" and later renamed was silently removed during a session in which the user deleted the respawned empty "Scene 1" from the dock — as if the deletion was applied to the scene *identity* rather than to the empty scene shown in the UI.

This looks closely related to #46 (scenes/sources randomly duplicated with a "1" suffix after restart) — same reconciliation machinery, different symptom.

## Steps to reproduce

**A. Rename revert (simple):**
1. Create a vertical canvas; it starts with "Scene 1".
2. Rename "Scene 1" from the dock. Restart OBS.
3. The old name is back (sometimes immediately, sometimes after the next composition change).

**B. Forced re-label of the head scene (file-level evidence):**
1. Close OBS. In the composition JSON, the first scene is (e.g.) "FF8 - Vertical"; there is no scene named "Scene 1".
2. Append a new valid scene object to the `scenes` array (new name, fresh ids) without touching anything else — byte-identical splice.
3. Start OBS: the dock shows the appended scene correctly, **but the first scene has been renamed to "Scene 1"** (same sources, same transforms — verified by diffing the re-saved file; only the name changed).

**C. Scene removal:**
1. Scene S was originally the canvas default ("Scene 1") and was renamed to "Valorant - Vertical" months/days earlier (name persisted across several sessions in the file).
2. In a dock session, the user deletes the *empty, respawned* "Scene 1" entry and another test scene, then closes OBS.
3. The composition file saved at shutdown no longer contains "Valorant - Vertical" — the renamed original was removed, not the entities the user deleted. (Timestamped file snapshots available for the whole sequence.)

## Expected behavior

The composition file (or at least the dock UI actions) should be authoritative: renames should persist, deleting a scene should delete exactly that scene, and externally added scenes shouldn't cause other scenes to be re-labeled or removed.

## Evidence available

Timestamped snapshots of the composition file across the whole sequence (before/after each step), showing: the byte-identical external splice, the forced re-label (identical source fingerprints under a different name), and the scene removal occurring in a dock-only session. Happy to share sanitized copies (overlay URLs redacted).

## Impact

Users cannot reliably rename vertical scenes, "Scene 1" keeps respawning, and in the worst case fully-configured scenes are silently lost. Workarounds exist (duplicate with brand-new names, treat the head scene as untouchable), but they shouldn't be necessary.
