# Tasks: E3 Pending Transaction Store

## Slice A — Store interface and RocksDB backend

- [ ] T012-S1 Define the public `Store`, `Entry`, `EntryId`, `EntryStatus`, and `Receipt` domain surface using existing Cardano chain types.
- [ ] T012-S1 Implement a restart-safe, concurrency-safe RocksDB backend with no manual delete API.
- [ ] T012-S1 Add unit coverage for entry round-trip, close/reopen persistence, and concurrent witness writes.
- [ ] T012-S1 Wire modules and dependencies in `cardano-multisig.cabal`.
- [ ] T012-S1 Run focused unit tests and the ticket gate commands.
