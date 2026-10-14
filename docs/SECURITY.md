# Local security review

## Accounting argument

For a funding credit `r` at live weight `W`, the accumulator increment is `q = floor(r * 1e36 / W)`. The total scaled reward allocated to all then-live notes is `q * W <= r * 1e36`. A note begins with the current accumulator checkpoint, so it cannot receive earlier allocation. Its owner is never part of the calculation; ERC-721 transfers preserve its claim.

On upgrade, the note's old-weight allocation is split into whole base units and a remainder modulo `1e36`, both retained. Its checkpoint moves to the current accumulator before the weight becomes 5. Future credits cannot multiply its past Standard earnings by five. Redemption pays only the floor of the accumulated scaled reward. Removed fractional claims and undistributed division remainders remain reserved.

By induction over credits, upgrades, mints, transfers, and redemptions, all live payable claims are bounded by credited receipts minus completed payouts. This is the stored `liabilities`. Direct donations affect balance but not liabilities until credited; subtracting the whole reserve prevents dust or already-allocated funds from being credited twice.

A donation is credited at the latest immediately before the next change to the weight set. `mint`, `upgradeToGold` and `redeem` each call the private surplus sync before touching a weight or computing a payout, so the accumulator a donation lands in always reflects the weights that were live while it sat in the contract. Without this, a note minted, upgraded or redeemed between arrival and `creditSurplus()` would take or forfeit IMD it was not entitled to; the reviewer's proof for that case is kept as a passing test. A donation that arrives while `totalWeight == 0` has no entitled note; the next mint folds it into `liabilities` and emits `SurplusStranded`, so it is never paid to anyone rather than paid to whichever wallet mints first. The sync returns silently when the balance is at or below the reserve, so an external shortfall cannot block minting, upgrading or redeeming through this path; the redemption's own post-payment check still rejects spending another note's reserve.

## External-call boundaries

- EOA/ERC-1271 pass validation, Keel balance checks, project eligibility, and symbol reads use static calls. They cannot mutate note state during the check.
- `fund` needs an external transfer before it can measure a receipt. Its reentrancy guard prevents reentrant mint, upgrade, funding, surplus credit, or redemption during that measurement. A note transfer during a token callback cannot change aggregate weight or allocate rewards twice.
- `redeem` updates counters/reserve, deletes note data, and burns before its external IMD transfer. SafeERC20 propagates failed payments; a recipient balance-delta check rejects underpayment, and the remaining-balance check rejects spending another note's reserve. Transaction rollback restores the burn and every counter when payment fails.
- Standard safe-transfer receiver callbacks execute after NFT ownership has changed. The recipient may redeem its newly owned note from that callback; the tests exercise this behavior.
- The symbol decoder is callable only by the collection itself. An outer gas-bounded `try/catch` surrounds the token call and ABI decoding, so malformed return data and resource exhaustion degrade to `?`. The successful return has at most 16 allowed characters.
- The renderer is called statically and receives display data only. It has no access to move IMD or change accounting. Dynamic text is XML-escaped and appears only inside a base64 SVG, not interpolated into JSON.

## Authorization and permanent limits

Mint passes bind the caller, minimum, deadline, chain ID, and verifying contract. Permanent `hasMinted` consumption prevents replay even after sale or redemption. This deliberately implements the specified typed data without an additional nonce. Signer rotation/revocation is checked at execution time.

Gold qualification and redemption require direct ownership, not approval. NFT approvals retain their normal transfer power, which necessarily allows an operator to move an asset and its rewards. Lifetime mint and Gold counters never decrement; backing-token use is permanent. Public burn methods and zero-address transfers cannot bypass redemption. The `_update` override refuses any transfer whose recipient is the collection itself: the collection can never be the caller of its own `redeem`, so such a note would keep its weight and its share of every later credit forever.

The owner controls mint availability, the one-time Keel eligibility-token choice, signer management, metadata, non-IMD rescue, and ownership. These are explicit trust assumptions. The owner cannot alter weights, erase a mint flag, reuse backing tokens, sweep IMD, or pause a holder's redemption. Ownership renunciation is inherited and irreversible. Because the Keel token choice is permanent, `setKeelToken` probes the candidate with a static `balanceOf` call and refuses an address without code or without a decodable answer; a wrong but functional token remains the owner's responsibility to avoid.

## Scope and residual assumptions

The fixed IMD token must supply truthful accounting, support transfers, and not destroy balances outside this contract. Funding measures net receipt; an outgoing recipient fee causes redemption to revert atomically, preserving the note. Inbound fee, outgoing recipient fee, false-return, no-return, reverted-payment, sender-surcharge, and reentrant-token mocks exercise these boundaries. A deliberate mock balance slash demonstrates shortfall detection, not protection from an externally malicious token.

KeelFactory and KeelVault are authoritative for launch status and creator identity. Their specified ABI is modeled offline; their governance was not validated here. A read of the live vault during the revision showed `project(address)` answering 15 words rather than the 14 the task specifies, with `creator` in the first word as expected. The 14-word interface decodes both answers because Solidity ignores trailing return data; it must not be tightened to an exact return size. The one-time Keel token and pass signer must be supplied by the launch operator. No production signer key is present in the repository.

All collection arithmetic is checked. Full-precision `mulDiv`/`mulmod` avoid multiplication overflow in funding and individual accrual. Finite accumulator capacity is a practical limit: credits which cannot be represented revert atomically. Stored timestamps use 64 bits, sufficient for all realistic Ethereum timestamps.

The SVG is deterministic display artwork, not a randomness source. No proxies, upgrades, arbitrary delegatecalls, selfdestructs, payable application entry points, or public/external linked libraries are used. Runtime tests scan executable bytes using the same PUSH-skipping rule as the supplied protected test.

Validation uses Foundry's compiler, unit tests, seeded fuzzing, stateful invariants, and manual code review. Slither and Mythril were not run. This review is by the implementer; it does not replace the independent contributor review required before release.
