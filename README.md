# Keel Notes

ERC-721 banknotes for the Keel launchpad on Ethereum (chain ID 1). The only production applications are `KeelNoteArt` and `KeelNotes`. This project creates no ERC-20, pool, liquidity position, proxy, or upgrade mechanism.

## Build and checks

Foundry and Solidity **0.8.26** are required. All Solidity dependencies are vendored as ordinary files under `lib/`; no network, submodules, environment configuration, FFI, or filesystem cheatcode permissions are required by the tests.

```sh
forge build
FOUNDRY_FUZZ_SEED=0x485f8d7d32111fc48577652b8f1994903cbeb0b387deb8f8dfdab3ee24cab200 forge test
forge fmt --check
```

`foundry.toml` enables optimization and the IR compiler, targets Cancun, disables the bytecode metadata hash and CBOR trailer, and configures 512 fuzz runs and 128 invariant runs of 64 operations. Tests install offline mocks at the three fixed integration addresses. [Dependency versions and provenance](docs/DEPENDENCIES.md) are included.

## Deployment parameters

Deploy in this order through the launch's existing deployment process:

| Contract | Constructor arguments |
| --- | --- |
| `KeelNoteArt` | None |
| `KeelNotes` | `owner_ = $owner`, `art_ = $contract:KeelNoteArt` |

The supplied launch owner is `0x51a9ca901c0cb5c222d244b2ccb0ebfc5c9aba99`. Ownership is explicitly assigned to that constructor argument, never to the deploying factory or transaction origin. Constructors make no external calls or code-presence checks; zero owner/art addresses are rejected. There is no initializer. A separate launch step supplies its manifest and actual deployed addresses; this repository does not broadcast transactions.

Fixed integrations, supplied by the task:

| Integration | Ethereum address | Usage |
| --- | --- | --- |
| IMD | `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7` | Only reward asset; `balanceOf`, `transferFrom`, `transfer`, `decimals` |
| KeelFactory | `0x39dfa7d3ce9364db50433fe9cc2f308c6a219f5f` | `isLaunched(token)` |
| KeelVault | `0xe2fb1c0e5ea5342cd8607efa8e7c44f06b47013c` | `project(token)`; first field is `creator` |

`IKeelVault.Project` preserves all supplied field types and their order. Names of the unused fields are descriptive placeholders for ABI decoding, not additional assumptions about their meaning. The tests model the supplied ABI; live deployed integrations have not been independently validated in this assignment.

## After launch

The launch owner must complete these settings before issuing usable mint passes:

1. Call `setKeelToken(address)` with the actual Keel token used for mint eligibility. Obtain and verify its Ethereum address from the Keel launch operator. **This can be set only once and cannot be corrected afterward.** A zero address is rejected; the owner must check its code and `balanceOf` behavior before committing it.
2. Call `setPassSigner(address)` with the backend signing wallet or ERC-1271 contract the launch operator controls. Obtain this address from that operator; no signer address or production key is embedded in this project.
3. Call `setMintOpen(true)` when ready. Minting starts closed and cannot be opened before both settings exist.

For signer rotation, call `setPassSigner(newSigner)`. `revokePassSigner()` immediately prevents new mints even if `mintOpen` is true. Outstanding signatures from a previous signer fail; restoring the same signer can make its still-unexpired passes valid again. `setMintOpen(false)` pauses only minting. Existing note transfers, Gold upgrades, funding, and redemptions remain available.

The owner can replace the metadata renderer with `setArt(address)` and recover unrelated ERC-20 tokens with `rescueToken(token,to,amount)`. IMD cannot be rescued, including direct donations and rounding dust. Ownership changes use `transferOwnership` followed by the nominated owner's `acceptOwnership`. Inherited `renounceOwnership` permanently removes configuration powers; do not use it while configuration or signer management is still needed.

## Mint passes

Free `mint(minKeel, deadline, sig)` issues the next ID, starting at 1, through 1111. Every wallet can mint once for the lifetime of the collection. Receiving, sending, or redeeming a note does not reset this flag, and receiving a note does not consume the recipient's own mint allowance. Burning never frees an issuance slot.

The EIP-712 payload is exactly:

```text
domain = {
  name: "KeelNotes",
  version: "1",
  chainId: 1,
  verifyingContract: <deployed KeelNotes address>
}
MintPass(address to,uint256 minKeel,uint256 deadline)
```

`to` must be the transaction caller. `minKeel` must be positive and is denominated in the configured Keel token's **base units**. `deadline` is a Unix timestamp; equality with the block timestamp is allowed. `mintPassDigest` exposes the digest for integration checking. OpenZeppelin `SignatureChecker` supports EOA and ERC-1271 signers. The permanent `hasMinted` flag supplies replay protection without an extra nonce in the requested payload; the domain binds the chain and collection.

The caller must hold at least `minKeel` **at mint time**. No Keel is transferred or locked. This is a wallet balance condition, not a proof of a unique person or long-term holdings. Minting intentionally uses `_mint`, so a calling contract does not need `IERC721Receiver`; it is responsible for being able to manage its note.

## Gold

A Standard note has weight 1. A Gold note has weight 5. `upgradeToGold(noteId, token)` requires the current owner (an approved operator is insufficient), a Standard note, a launched token whose vault creator is that owner, an unused backing token, and fewer than 111 lifetime Gold upgrades. Backing-token use and the Gold count remain consumed after a burn. No project tokens are deposited; “BACKS” identifies the creator's engraved endorsement, not custody of those tokens or a collateral claim.

An upgrade settles the old weight's rewards and fractional remainder before changing the weight. The address and symbol are then permanent. A symbol is read once, must contain 1–16 ASCII letters/digits, and otherwise becomes `?`. The **50,000 gas** decoding boundary also handles reverting, malformed, oversized, or gas-consuming metadata. It is acceptable for a costly valid symbol to fall back to `?`.

## IMD funding and redemption

Anyone can approve IMD and call `fund(amount)`. At least one live weight is required. Credit is the increase in the contract's IMD balance, so incoming transfer fees are measured. Zero amounts/receipts revert. IMD sent directly creates an uncredited surplus; anyone can call `creditSurplus()` while live notes exist to allocate it to the weights **at the time of credit**. Direct transfers do not automatically update rewards, and a later `fund` credits only its own receipt.

Each credit adds `floor(received * 1e36 / totalWeight)` to `accPerWeight`. New notes start at the current accumulator. Transfers do not change any reward state. Fractional base-unit earnings survive a Gold upgrade. Full-precision multiplication/division prevents intermediate multiplication overflow when the resulting accumulator fits in `uint256`; an unrepresentable cumulative accumulator reverts instead of wrapping.

`redeem(noteId)` is the sole burn path. Only the current owner can call it, and a zero pending balance reverts. It burns the note, removes its live weight, decrements its reserve, then safely transfers the pending IMD. Failed payments, including a recipient receiving less than its pending amount, revert all changes. A reentrancy guard covers mint, upgrade, fund, surplus credit, redeem, and rescue. Approved NFT operators can transfer notes but cannot redeem or upgrade them.

`liabilities` is a conservative reserve: **total credited IMD minus completed redemption amounts**, including rounding dust. Thus:

```text
sum of pending IMD on live notes <= liabilities <= IMD balance
uncredited surplus = IMD balance - liabilities
```

Accumulator division rounds down; each redemption rounds down to a whole IMD base unit. Undistributed dust and a redeemed note's fractional remainder stay reserved permanently. They cannot be credited again, swept by the owner, or assigned to future notes. This choice favors solvency and prevents earlier rewards being allocated to later notes. A note holding less than one payable base unit cannot redeem until it earns more.

The invariants assume the fixed IMD contract reports truthful balances and does not confiscate or negatively rebase the collection's balance. External token balance destruction cannot be prevented here. Unexpected shortfalls are rejected on fund/surplus operations; redemption checks the remaining reserve after payment. SafeERC20 handles false, reverting, and no-return tokens. Incoming transfer fees are supported. An outgoing recipient fee that reduces the amount received causes redemption to revert, preserving the note until a full payment is possible. The design does not promise compatibility with arbitrary rebasing or malicious reward assets.

## Views, artwork, and events

`noteInfo(id)` returns `(level, weight, backedToken, symbol, pending, mintedAt)`. `Level.Standard` is 0 and `Level.Gold` is 1. Standard backing is unset and its symbol is empty. Nonexistent and redeemed IDs revert on note views and `tokenURI`. Counters include `totalWeight`, `goldCount` (lifetime), `totalMinted` (lifetime), `totalBurned`, `totalSupply` (live), and `hasMinted(wallet)`. `pending(id)` returns full base units.

The token URI embeds base64 JSON containing a base64 SVG. Its dark banknote uses deterministic `keccak256(abi.encode(noteId))` guilloche, chrome trees with silver leaves, a metallic K, serial number, level, live holdings, and swarm microtext. Gold adds gold metal and its escaped symbol/address engraving. The renderer uses only internal SVG references and monospace fonts, with no network resources. `svg(...)` is also exposed for previewing. Geometry is decorative, not valuable randomness. [Standard preview](docs/standard.svg) and [Gold preview](docs/gold.svg) are generated by the renderer with illustrative inputs; the Gold address is a local mock, not a deployment address.

The renderer receives IMD's current `decimals()` value and displays two decimal places, truncated. All accounting remains in full base units. Metadata may therefore show `0.00 IMD` while a small nonzero redemption is possible. A failing IMD `decimals()` call or an unavailable owner-selected renderer can interrupt metadata rendering without interrupting rewards or redemption. Marketplaces may cache token URIs; refresh metadata to see current holdings.

Application events are `NoteMinted`, `NoteUpgraded`, `Funded` (including whether credit came from surplus), `NoteRedeemed`, `KeelTokenSet`, `PassSignerSet` (including revocation to zero), `MintOpenSet`, `ArtSet`, and `TokenRescued`, alongside standard ERC-721 and ownership events.

There is no payable entry point, receive function, or fallback. Normal ETH sends and unknown selectors revert. The EVM can still force ETH into a contract; there is no ETH recovery path.

## Validation and review

Unit, fuzz, and stateful invariant tests cover success and failure paths, including both lifetime caps, ERC-1271, domain separation, transfer/upgrade settlement, fee-on-transfer funding, donations, rounding, rollback, reentrancy, token rescue, ETH rejection, metadata, runtime limits, and the supplied forbidden-opcode scan. The invariant reference ledger distributes each credit immediately to all live notes rather than using the production checkpoint mechanism.

[Recorded validation](docs/VALIDATION.md) lists the local results and runtime sizes. [Security review notes](docs/SECURITY.md) describe the accounting argument and operational trust boundaries. Local tests and review are not an independent security audit. An independent adversarial review and validation of the fixed live integrations remain release responsibilities.
