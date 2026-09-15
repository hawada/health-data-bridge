# Usage

## Sleep and heart rate

Connect your own WHOOP account, grant the relevant Apple Health read/write access and run the first synchronization manually. The initial lookback is seven days. Later runs use confirmed checkpoints and revision windows. Existing health coverage is checked before writing; unreadable/ambiguous visibility can stop a run rather than assume absence.

After initial setup, add the Sync WHOOP App Shortcut to your own personal automation if desired. The app has no autonomous background scheduler. Locked-device access can fail safely without advancing checkpoints.

## Optional recovery HRV

A supporting iOS 27 device is required. Recovery **RMSSD in milliseconds** is distinct from the WHOOP recovery score (%) and Apple Health's SDNN type. The import does not convert RMSSD to SDNN.

1. Open Options → Configure recovery HRV.
2. Choose when you actually began using WHOOP. The initial date shown is only a default; change it for your account.
3. Request HRV authorization.
4. Review native WHOOP export coexistence and the visible read-access status. Select an actually observed native exporter if applicable. Where access remains unknown, an explicit personal confirmation is required; do not confirm full access unless it is true.
5. Confirm the existing account binding if requested, then enable recovery HRV.
6. Import the indicated period. Inspect progress, pending items and manual-review messages. Cancel if necessary and resume later.

The original WHOOP account session is reused. Recovery setup does not require a new login merely because this optional feature was added. An account mismatch blocks use of another account's progress. There is no archive-state selector for switching between accounts.

History windows are bounded and rate limiting is respected. An empty page is not taken as proof of absolute historical exhaustion. The UI reports completion of the indicated scope rather than claiming all provider history was verified.

If read permissions change, revisit authorization/configuration. A previous manual full-access confirmation cannot detect hidden later revocations. Limited historical visibility and uncertain native coexistence can leave records pending; do not assume an empty result means there are no existing records.
