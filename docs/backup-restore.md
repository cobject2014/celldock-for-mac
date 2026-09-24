# Encrypted backup and restore

In **Settings → Backup & Restore**, choose maintenance mode, quit, then reopen
CellDock. Communications are stopped in maintenance mode; no modem services or
business stores are constructed. Choose **Done, return to CellDock** (or close the
maintenance window) to resume normal use in the same process; no manual restart
is needed. The same safety checks block both actions during active operations or
unfinished recovery. After a successful restore, acknowledge migration settings
before returning; business stores then load the restored data for the first time.

## Create a backup

Enter and confirm a password of at least 12 characters. Choose a local folder or
an iCloud Drive folder using the folder picker. Each backup has a unique name and
never overwrites an earlier backup. **Saved locally does not mean uploaded to
iCloud**: wait for Finder to finish syncing before moving to another Mac.

The password is not saved in preferences or the Keychain. Keep it separately.
There is no password recovery. The archive contains sensitive messages and
forwarding/proxy credentials: do not share it.

## Restore on another Mac

Install this fork/version of CellDock, enter maintenance mode, select the backup,
enter its password, and inspect the counts and creation date. The app requests
download of iCloud placeholders (up to two minutes; retry after Finder finishes
if necessary), then validates a private local copy. Confirm **Replace & Restore**
only after checking that it is the intended backup. This is replacement, not merge.

The archive includes SMS/read state/deletion tombstones, call history and
automatic-answer markers, recordings with original channels unchanged, custom
sounds, portable preferences and explicitly scoped CellDock Keychain credentials.
See [the inventory](backup-data-inventory.md) for the exact whitelist.

macOS permissions, login startup, USB/network-service bindings, SIM/eSIM profiles,
and modem firmware are not transferred. Review permissions on the target Mac.
Microphone access is not requested by backup/restore. Automation and proxies are
disabled on leaving restored maintenance mode; re-enable desired features in
settings and reassess their consent requirements. Module network routes must be
set up again. Existing history is loaded before communication resumes and is not
itself submitted for forwarding.

## Failure and recovery

Before changing any managed file, preference or credential, restore creates and
decrypt-verifies an encrypted before-image at:

`~/Library/Application Support/CellDock/BackupRecovery/rollback.celldockbackup`

Older rollback archives are retained with UUID suffixes. They use the same password
as the backup being restored. The maintenance window has a Finder button for this
folder. Keep these files until you are satisfied with the restore.

The journal progresses through `prepared → filesApplying → settingsApplying →
credentialsApplying → committed`. On failure it rolls back the full before-image,
including absence of credentials newly introduced by the incoming backup. If
rollback fails or the process exits, the journal remains and the next launch opens
only the recovery screen. Enter the same password to recover the old state. Wrong
passwords and missing/corrupt rollback packages do not enable communications.
Do not delete the journal to bypass recovery. If the rollback file is missing,
recover that exact file from your filesystem backup before continuing.

## Format and limits

Format 1 is specific to this fork; upstream CellDock cannot import it. Future
unknown format versions are rejected. PBKDF2-HMAC-SHA256 (600,000 iterations and a
random 16-byte salt) derives an AES-256-GCM key. Frames authenticate the header,
sequence, file index and offset. A final authenticated frame prevents accepting a
truncated valid prefix. Filenames and credentials are inside the encrypted body.
Audio is streamed in 1 MiB chunks, not loaded as one recording. Metadata is limited
to 64 MiB per file, the manifest to 16 MiB, 100,000 entries and 1 TiB total payload.
Local plaintext staging is private (directory 0700, files 0600) and removed on
normal completion or cancellation. Force-kill can leave private temporary staging;
it is not an encrypted secure-erasure mechanism. Only encrypted bytes are copied
to the chosen destination, via a checked temporary file before publication.

## Verification

`./scripts/run_tests.sh` includes isolated backup tests with fake credentials:
wrong password, truncation/tamper/reorder/duplicate frames, path rejection,
symlink rejection, multi-frame audio preservation, cancellation, cross-environment
migration, every managed write boundary, and separate-process forced exits at
durable transaction phases followed by password-gated recovery. Other existing
tests cover actual stereo M4A creation and playback.

Real iCloud synchronization timing, a second physical Mac, and live Keychain prompts
require a user-selected destination and password and are not simulated by these
tests. Never exercise destructive restore tests against the installed app's data.

Measured streaming regression: 8 MiB and 128 MiB archives used approximately
15 MiB and 16.5 MiB maximum resident memory respectively after adding per-chunk
autorelease pools. The isolated App-model test migrates two modules, Chinese SMS,
read state, automatic-answer call/recording markers and a real two-channel CAF.

The Debug-only `app.celldock.backup-ui-test` identity always enters isolated
maintenance, even when LaunchServices omits environment variables. This prevents
the test wrapper from accidentally starting normal hardware/permission flows.
Its backup and restore actions are disabled internally; file panels alone can be
exercised. The production app does not contain this test mode.

Restore completion is recorded durably, separately from the recovery journal.
Only a committed migration requires disabling imported automation and clearing
machine-specific network choices. A failed import or successful rollback keeps
the original machine's settings intact.

Retained encrypted rollback archives may also be selected for manual restoration.
Their supplemental absent-credential inventory is used for automatic rollback;
manual import normalizes it to the accounts referenced by the archived settings.
The encrypted original is not modified. Call history whose recording was already
deleted remains valid and can be backed up; indexed recordings must still have
their audio files.

The integrated build also backs up ASR settings, transcription history/delivery
progress, and TTS greeting settings with their cached audio. Credentials within
those configuration files are protected by the same encrypted archive. After
successful migration, ASR and greeting playback are disabled until explicitly
enabled on the destination Mac; rollback does not alter their original switches.
