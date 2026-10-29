# Portable library backups — 0.12 source candidate

Back up Notes, Snippets or Quicklinks individually as a lossless JSON file. This is a local transfer tool for moving a library to another Mac. It does not back up the whole app, clipboard history, preferences or other libraries, and it is not cloud sync. The candidate's native GUI checks remain pending for the nightly session.

## Export

Open the library's page and use its backup controls. Notes and Snippets must finish saving first; a failed/invalid draft or damaged library blocks backup and import. Choose a destination. Orbit creates a new private `Orbit Library Backup …` folder and file; it does not replace an existing backup. Notes include Recently Deleted, pins and dates. Snippets preserve keywords and template text, including unfinished templates. Quicklinks preserve URL templates and pins.

The backup contains your full text in plain JSON, without encryption. Store it privately. Folder permissions are 700 and file permissions 600 where supported; the source library and selected parent folder are not modified.

## Preview and merge

Choose a backup from the matching library page. Orbit validates it and shows how many entries would be added and how many identical entries already exist. Preview does not save, flush drafts or modify the library. Apply is a separate explicit action.

- An identical entry with the same ID is skipped, so importing the same backup twice does not create copies.
- A different entry with the same ID is a conflict, including NFC/NFD text representations with different UTF-8 bytes. A Snippet keyword used by a different entry is also a conflict, ignoring case and surrounding whitespace. A conflict refuses the whole import; no existing entry is overwritten or silently discarded.
- If the combined library would exceed its limits, the whole import is refused. No truncation or partial merge occurs.
- Changes to the library or draft after preview invalidate the plan. Preview again before applying.
- Apply saves the entire resulting library once. A failed save preserves the previous library and draft. Cancel changes nothing. Imported deleted notes remain deleted; existing notes are never restored, deleted or unpinned by import.

An unreadable library needs the existing explicit damaged-data backup/reset flow. The transfer tool will not export a misleading empty backup over damaged source bytes.

## Format v1

Each UTF-8 JSON document has exactly one library kind:

```json
{
  "format": "utuvo.orbit.library",
  "version": 1,
  "kind": "notes",
  "records": [
    {
      "id": "11111111-1111-4111-8111-111111111111",
      "title": "A saved note",
      "body": "Hello Orbit",
      "pinned": true,
      "modified": 12345.125
    }
  ]
}
```

`kind` is `notes`, `snippets` or `quicklinks`. Records follow their existing Codable shape:

- Note: `id`, `title`, `body`, `pinned`, `modified`, optional `deleted`.
- Snippet: `id`, `title`, `keyword`, `body`, `pinned`, `modified`.
- Quicklink: `id`, `title`, `template`, `pinned`.

Date numbers use Foundation's default representation: seconds since 2001-01-01 00:00:00 UTC, preserving the Double value instead of truncating to formatted milliseconds. IDs and all text are preserved. Unknown format/version, wrong library kind, invalid or duplicate records, and non-finite dates are refused. Snippet template syntax is validated when expanded, not as a condition for backing up unfinished editing content.

Maximum encoded input/output is 16 MiB, with JSON structural nesting limited to 32 outside quoted strings. Record limits remain 100 Notes/Snippets, 64 KiB per body, 2,000,000 combined body bytes; 50 Quicklinks with existing title/template validation. Both the source backup and the merged result are validated. Input files must be regular files; symbolic links, folders, FIFOs and files changing during the read are refused.

## Development boundary

Default preview mode disables file pickers and exports. Debug-only `--tools-qa-file-actions` permits explicitly selected temporary fixtures while models remain in memory and hardware/clipboard stay fake. Use disposable fixture roots for tests. No native app or picker was launched during daytime verification.
