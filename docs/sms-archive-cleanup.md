# SMS archival and modem storage cleanup (fork)

Incoming, fully assembled SMS messages are committed to the Mac's existing
`CellDock/messages.json` before notifications, forwarding or modem cleanup.
The atomic file replacement is synchronized before returning a cleanup receipt.
If saving fails, no receipt is returned; the modem copy remains and subsequent
polls retry. Errors are recorded in the macOS log without SMS contents.

Cleanup does **not** delete Mac conversations. It runs only while the modem is
idle, checks at most one slot per timer tick and uses `AT+CMGD=<index>,0`, never
a bulk-delete flag. Immediately before deletion it reads that storage/index
using `CMGR` and requires the exact archived PDU. A replaced or absent entry
is left alone; unreadable entries and ambiguous delete results are rechecked
after a 30-second cooldown. Receipts from a previous connection are rejected.

The archive is scoped to the app's existing module identifier. A fresh poll can
recognize already archived raw PDUs, including surviving long-message fragments
after a partial cleanup and restart. Outgoing messages, unknown fragments and
messages excluded by the existing deleted-message registry do not authorize
cleanup. The cleanup queue is bounded to 1,024 references; further entries can
be rediscovered by later polls.

## Deliberate first-version limit

An incomplete long SMS is **not** cleared or archived as a complete message.
Its fragments remain on the modem until assembly succeeds. An accumulation of
orphan fragments can therefore still fill storage and needs explicit review;
this version does not silently expire them. It does not change firmware, USB
configuration, SIM storage preferences or the installed app.

## Validation

Run `./scripts/run_tests.sh` (macOS audio tests require access outside an app
sandbox) and `swift build --disable-sandbox -Xswiftc -disable-sandbox`.
Tests cover failed and repeated saves, reload, cross-module isolation,
incomplete/complete multipart messages, cleanup after restart, recycled slots,
backoff and stale/disconnected sessions. Real modem behavior still requires a
separate installed-app test: send a uniquely labeled SMS, confirm local history,
confirm storage is reclaimed, then restart the app and confirm history remains.
