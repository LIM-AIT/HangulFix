# Raw directory-entry normalization fix

HangulFix must distinguish the Unicode spelling actually stored by APFS from the canonically equivalent spelling that Foundation file URL/path APIs may present.

For normalization decisions, directory-entry names are now read with POSIX `readdir(3)` and compared by their UTF-8 code units. Foundation URLs remain useful for UI and package enumeration, but are no longer the source of truth for a selected item's stored NFC/NFD spelling.

Regression scenario covered:

1. Create an NFD Korean filename using POSIX file APIs.
2. Select it through a canonically equivalent NFC alias.
3. Detect it as NFD and convert it to NFC.
4. Verify the raw directory entry is NFC.
5. Select the same file again through the stale NFD alias.
6. Confirm that no second normalization candidate is produced.
7. Confirm verified ZIP creation still succeeds.
