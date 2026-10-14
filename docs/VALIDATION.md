# Recorded local validation

Validated with Foundry **1.8.5** and the repository-pinned Solidity **0.8.26** compiler. These are implementer observations, not an independent attestation or audit.

| Check | Result |
| --- | --- |
| `forge build --sizes` | Passed |
| Seeded `forge test` | 60 tests passed, no failures or skips |
| `forge fmt --check` | Passed |
| Clean-copy `forge build --offline` | Passed |
| Clean-copy seeded `forge test --offline` | 60 tests passed |
| Clean-copy formatting and vendored-file checksums | Passed |
| Generated Standard and Gold SVGs | Valid XML; 36 seed-derived ellipses each; internal references only |

The clean copy contained the delivered sources, tests, libraries, documentation, and Foundry configuration. It excluded build/cache directories, scratch scaffolding, and the supplied `.imd` inputs. Build and tests ran with an empty process environment except `PATH` and, for tests, the prescribed fuzz seed. No network dependency was available to Foundry in offline mode.

```text
FOUNDRY_FUZZ_SEED=0x485f8d7d32111fc48577652b8f1994903cbeb0b387deb8f8dfdab3ee24cab200
```

The suite comprises 17 mint/configuration tests, 9 Gold tests, 25 reward/safety tests, 8 artwork/deployment tests, and one grouped invariant campaign with two invariant checks. Three fuzz tests run 512 cases each. The invariant campaign ran 128 sequences of 64 operations: **8,192 calls, zero reverts**, checking solvency, exact reference-ledger claims, ownership, weights, lifetime mint flags, and counters after mixed mint/fund/donate/credit/upgrade/transfer/redeem operations.

Final application runtime sizes:

| Contract | Runtime bytes |
| --- | ---: |
| `KeelNotes` | 12,390 |
| `KeelNoteArt` | 10,747 |

Both are below 24,000 bytes, have no unresolved library links, and pass the PUSH-aware forbidden-opcode scan. Constructors are exercised together through a factory probe with no code at the fixed external integration addresses.

Foundry's remaining informational lints concern the deliberately requested `_mint`, timestamp deadlines and the practical `uint64` timestamp range, events following guarded/static calls, the gas-bounded self-call for symbol decoding, and the ordering of `onlyOwner` before `nonReentrant` on rescue. The ownership modifier reads storage only. The symbol helper returns at most 16 characters on success and runs the token call/decoding inside its capped catch boundary; tests cover malformed, oversized, reverting, and gas-consuming symbols. These warnings and their trust boundaries were reviewed locally; the project does not suppress them globally.

Slither, Mythril, a mainnet integration fork, and an independent contributor audit were not run. Their absence is not concealed by the local test result.
