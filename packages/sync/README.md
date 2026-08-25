# packages/sync

ElectricSQL client wiring and conflict-resolution helpers for the cowork
feature.

**Phase 3, and it starts as a throwaway spike, not as this package.**

Electric's read-path sync (Postgres → device) is mature; its write-path
(device → server) is newer and described by third parties as still maturing.
Before anything real is built here, the spike has to answer:

1. Two local clients, one Postgres, concurrent writes to the same mutable
   draft row — how does the conflict actually surface to the app?
2. Does that match the design in `ARCHITECTURE.md`: an explicit version
   conflict shown to a human, never a silent auto-merge?
3. `db/schema.sql` requires an entry to be inserted as a draft and posted by a
   subsequent UPDATE, so posting is always validated. Direct table replication
   of an already-posted row will be rejected by that trigger. Does Electric's
   write path go through the API (fine) or straight at the tables (not fine)?

If it does not hold up, that gets reported rather than routed around.
