# Automatic answer retry repair

Approved scope: three attempts per incoming call, three seconds between failures;
listen-only audio and automatic recording remain unchanged. No automatic killing
of external processes. Work on codex/auto-answer-retry.

1. Add deterministic retry, suppression, stale-result and success tests. RED:
   current gate lacks completion handling (compiler failure observed).
2. Track in-flight attempts and terminal suppression per call UUID. Connect actual
   answer results to the gate. Display persistent errors in both incoming views.
3. Preserve a readable ADB ownership error, reject unavailable media before ATA,
   and avoid answering while media cleanup is pending.
4. Run full tests, fresh review, signed build. Release the confirmed sole ADB
   device as previously authorized, and restore the locally installed app.

Verification ledger: focused tests and full scripts/run_tests.sh passed. Fresh
review identified missing cleanup guards and stale cancellation text; both fixed,
then full suite rerun successfully. RING clears lastError, so unavailable-media
preflight now also checks the persistent interface ownership flag.

Signed universal build 120 passed archive verification and was installed locally.
The sole ADB server was released. After restart the native module UI reports
supported QDC507 injected voice (not yet call-verified). Actual incoming call and
recording verification was initially pending. On 2026-11-06 the user confirmed
that the real-call validation succeeded and requested committing the repair.
