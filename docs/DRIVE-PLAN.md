# Drive plan

Hardware: 2× WD Ultrastar DC HC550 18 TB (manufacturer-recertified, ServerPartDeals, 3-yr warranty)
in a Jonsbo N6 (9 hot-swap bays). OS + Immich database on the 512 GB NVMe.

Informed by AkitaOnRails, "Disaster on my NAS: how I almost lost 90 TB of data" (Oct 2026):
a drive logged errors silently for a month; he swapped a *different* drive; the rebuild read
the sick drive end to end, it failed, and single-parity redundancy was exceeded.

## Layout

| Stage | Layout | Survives | Usable |
|---|---|---|---|
| Now | 2-way ZFS mirror | 1 drive failure | 18 TB |
| Grow (simple) | add mirror pairs: `zpool add tank mirror X Y` | 1 per pair | +18 TB per pair |
| Grow (safer, ~6 drives) | new RAIDZ2 pool, migrate | any 2 drives | ~4× drive size |

A mirror cannot be converted to RAIDZ2 in place; decide at ~6 drives.
Mirrors only re-read ONE drive to rebuild (gentler than the article's 8-drive RAID-5 rebuild),
but it is still single redundancy — **off-site backup is the second layer.**

## Rules (from the article)

1. **Burn in recertified drives** before data touches them (`scripts/burnin.sh`, ~3 days, both in parallel).
2. **Alerts on any SMART change** (smartd → ntfy), **ZFS events** (ZED → ntfy), **monthly scrub** with report,
   **weekly health report** including per-drive latency (SMART "PASSED" ≠ healthy speed).
3. **Before any drive swap or upgrade:** `zpool status -v`, `smartctl -a` on EVERY drive, check Scrutiny.
   Replace the weakest drive first. Never start a resilver with another drive showing errors.
4. **Leave slack:** alert at 80% full. No quotas/reservations (they blocked snapshots in the article).
5. **RAID is not backup.** sanoid snapshots (local mistakes) + restic → Backblaze B2 nightly (disasters).
   Monthly read-back verification of B2. Quarterly manual restore test.
6. **Verify migrations independently** (`scripts/verify-takeout.py`). Keep Google One until verified + backed up.
7. **Kernel updates are manual** (security updates are automatic); keep the previous kernel bootable.

## Ultrastar power-disable (PWDIS) note

HC550 "Power Disable" drives won't spin up if 3.3 V reaches SATA power pin 3.
Power the N6 backplane from its **Molex** inputs only (Molex has no 3.3 V). Fallback: Kapton tape over pins 1–3
of the drive's SATA power connector. If a drive doesn't appear in `lsblk`, this is the first suspect.

## Cost of a cold spare

A spare 18 TB (~$489) on the shelf shortens the exposure window after a failure. Reasonable once the
pool holds data you can't easily re-download; until then, B2 + Google (during migration) cover it.
