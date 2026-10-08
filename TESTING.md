# Checks

Run `./scripts/test.sh` for the local checks. The test transport writes to temporary folders and deliberately slows or corrupts copies to exercise failure handling.

| Area | Cases |
| --- | --- |
| Names and paths | Spaces, quotes, emoji, newlines, leading hyphens, shell metacharacters, wrong parents, protected roots |
| Copying | Both directions, duplicate requests, empty files and folders, cancellation, timeouts, incomplete manifests, replacement rollback |
| Progress | Byte updates, speed and time estimates, incomplete samples, totals above 2 GB, a 7 GB sparse-file check |
| Merge/Update | Missing files, partial folders, identical files, same-size files with different hashes, destination-only files, nested folders, all-identical copies with zero transferred bytes |
| Merge failures | File/folder collisions, corrupt copies, failure after a completed update, retrying a partial merge, cancellation, temporary-folder cleanup |
| Deletion | Confirmation cancellation, duplicate approval, empty selection, active-transfer protection, quoted file names, folders, permission errors, disconnected phone |

To check the real Mac Trash API and restore the test file, run `GLASSBRIDGE_TEST_TRASH=1 ./scripts/test.sh`. The test moves only its own generated file.

The live phone checks use a temporary folder under Download. They cover a folder round trip, duplicate names, merge in both directions, same-size hash changes, unchanged-file skipping, and deletion of a test file. Set `GLASSBRIDGE_TEST_SERIAL` and `GLASSBRIDGE_TEST_ADB` as shown in the README.

The latest local checks and Mac Trash round trip passed. The Mac deletion dialog and Cancel button were checked in the running app. The phone was disconnected before the latest live checks could run. Physical trackpad gestures and folder hover feedback still need a manual check.
