// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeelNotesTestBase} from "./KeelNotesTestBase.sol";
import {KeelNotes} from "../src/KeelNotes.sol";
import {MockToken, MockFactory, MockVault} from "./mocks/Mocks.sol";

/// @dev Drives KeelNotes near its lifetime Gold cap with honest and hostile callers. Every hostile action
/// must revert with the expected error and leave the observable state untouched.
contract AdversarialHandler is Test {
    uint256 public constant ACTORS = 160;
    KeelNotes public immutable notes;
    MockToken public immutable imd;
    MockToken public immutable keel;
    MockToken public immutable stray;
    MockFactory public immutable factory;
    MockVault public immutable vault;
    address public immutable owner;
    uint256 public immutable signerKey;

    uint256 public credited;
    uint256 public paid;
    uint256 public uncredited;
    uint256 public credits;
    uint256 public gold;
    uint256 public burned;
    uint256 public strayHeld;
    uint256 public hostileReverts;
    uint256 private _backingNonce;
    mapping(uint256 => address) public backing;

    constructor(KeelNotes notes_, MockToken keel_, address owner_, uint256 signerKey_) {
        notes = notes_;
        imd = MockToken(notes_.IMD());
        keel = keel_;
        factory = MockFactory(notes_.KEEL_FACTORY());
        vault = MockVault(notes_.KEEL_VAULT());
        owner = owner_;
        signerKey = signerKey_;
        stray = new MockToken();
    }

    function actor(uint256 seed) public pure returns (address) {
        return address(uint160(0xA0000 + seed % ACTORS));
    }

    function _pass(address to, uint256 minimum, uint256 deadline) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, notes.mintPassDigest(to, minimum, deadline));
        return abi.encodePacked(r, s, v);
    }

    function _live(uint256 seed) internal view returns (uint256 id, address holder, bool ok) {
        uint256 minted = notes.totalMinted();
        if (minted == 0) return (0, address(0), false);
        id = 1 + seed % minted;
        try notes.ownerOf(id) returns (address h) {
            return (id, h, true);
        } catch {
            return (id, address(0), false);
        }
    }

    // ---------------- honest actions ----------------

    function mint(uint256 actorSeed) public {
        address to = actor(actorSeed);
        if (notes.hasMinted(to)) return;
        keel.mint(to, 1);
        bytes memory sig = _pass(to, 1, block.timestamp);
        vm.prank(to);
        notes.mint(1, block.timestamp, sig);
    }

    function fund(uint96 raw) external {
        if (notes.totalWeight() == 0) return;
        uint256 amount = bound(uint256(raw), 1, 1e27);
        imd.mint(address(this), amount);
        imd.approve(address(notes), amount);
        notes.fund(amount);
        credited += amount;
        ++credits;
    }

    function donate(uint96 raw) external {
        uint256 amount = bound(uint256(raw), 1, 1e27);
        imd.mint(address(this), amount);
        imd.transfer(address(notes), amount);
        uncredited += amount;
    }

    function creditSurplus() external {
        if (notes.totalWeight() == 0) return;
        if (uncredited == 0) {
            vm.expectRevert(KeelNotes.ZeroReceived.selector);
            notes.creditSurplus();
            ++hostileReverts;
            return;
        }
        notes.creditSurplus();
        credited += uncredited;
        uncredited = 0;
        ++credits;
    }

    function upgrade(uint256 seed) public {
        (uint256 id, address holder, bool ok) = _live(seed);
        if (!ok) return;
        (KeelNotes.Level level,,,,,) = notes.noteInfo(id);
        address token = address(uint160(0xB00000 + ++_backingNonce));
        factory.setLaunched(token, true);
        vault.setCreator(token, holder);
        uint256 pendingBefore = notes.pending(id);
        if (level == KeelNotes.Level.Gold) {
            vm.prank(holder);
            vm.expectRevert(KeelNotes.AlreadyGold.selector);
            notes.upgradeToGold(id, token);
            ++hostileReverts;
            return;
        }
        if (notes.goldCount() == notes.MAX_GOLD()) {
            vm.prank(holder);
            vm.expectRevert(KeelNotes.GoldCap.selector);
            notes.upgradeToGold(id, token);
            ++hostileReverts;
            return;
        }
        vm.prank(holder);
        notes.upgradeToGold(id, token);
        assertEq(notes.pending(id), pendingBefore, "upgrade settles without gain or loss");
        backing[id] = token;
        ++gold;
    }

    /// Upgrades a run of notes so sequences can reach and cross the lifetime cap.
    function upgradeMany(uint256 seed, uint8 count) external {
        uint256 n = bound(count, 1, 40);
        for (uint256 i; i < n; ++i) {
            upgrade(seed + i);
        }
    }

    function transfer(uint256 seed, uint256 actorSeed) external {
        (uint256 id, address holder, bool ok) = _live(seed);
        if (!ok) return;
        address to = actor(actorSeed);
        uint256 pendingBefore = notes.pending(id);
        vm.prank(holder);
        notes.transferFrom(holder, to, id);
        assertEq(notes.pending(id), pendingBefore, "transfer keeps rewards with the note");
    }

    function redeem(uint256 seed) external {
        (uint256 id, address holder, bool ok) = _live(seed);
        if (!ok) return;
        uint256 amount = notes.pending(id);
        if (amount == 0) {
            vm.prank(holder);
            vm.expectRevert(KeelNotes.NoRewards.selector);
            notes.redeem(id);
            ++hostileReverts;
            return;
        }
        uint256 before = imd.balanceOf(holder);
        vm.prank(holder);
        notes.redeem(id);
        assertEq(imd.balanceOf(holder) - before, amount, "redemption pays exactly pending");
        paid += amount;
        ++burned;
    }

    function warp(uint32 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 30 days));
    }

    function strayDeposit(uint96 raw) external {
        uint256 amount = bound(uint256(raw), 1, 1e27);
        stray.mint(address(notes), amount);
        strayHeld += amount;
    }

    function rescueStray(uint96 raw) external {
        if (strayHeld == 0) return;
        uint256 amount = bound(uint256(raw), 1, strayHeld);
        vm.prank(owner);
        notes.rescueToken(address(stray), owner, amount);
        strayHeld -= amount;
    }

    // ---------------- hostile actions: each must revert ----------------

    function strangerRedeem(uint256 seed, uint256 actorSeed) external {
        (uint256 id, address holder, bool ok) = _live(seed);
        if (!ok) return;
        address stranger = actor(actorSeed);
        if (stranger == holder) return;
        vm.prank(stranger);
        vm.expectRevert(KeelNotes.NotNoteOwner.selector);
        notes.redeem(id);
        ++hostileReverts;
    }

    function approvedOperatorRedeem(uint256 seed, uint256 actorSeed) external {
        (uint256 id, address holder, bool ok) = _live(seed);
        if (!ok) return;
        address operator = actor(actorSeed);
        if (operator == holder) return;
        vm.prank(holder);
        notes.approve(operator, id);
        vm.prank(operator);
        vm.expectRevert(KeelNotes.NotNoteOwner.selector);
        notes.redeem(id);
        vm.prank(holder);
        notes.approve(address(0), id);
        ++hostileReverts;
    }

    function burnedRedeem(uint256 seed, uint256 actorSeed) external {
        (uint256 id,, bool ok) = _live(seed);
        if (ok || id == 0) return;
        vm.prank(actor(actorSeed));
        vm.expectRevert();
        notes.redeem(id);
        ++hostileReverts;
    }

    function doubleMint(uint256 actorSeed) external {
        address to = actor(actorSeed);
        if (!notes.hasMinted(to)) return;
        keel.mint(to, 1);
        bytes memory sig = _pass(to, 1, block.timestamp);
        vm.prank(to);
        vm.expectRevert(KeelNotes.AlreadyMinted.selector);
        notes.mint(1, block.timestamp, sig);
        ++hostileReverts;
    }

    function stolenPass(uint256 fromSeed, uint256 toSeed) external {
        address passOwner = actor(fromSeed);
        address thief = actor(toSeed);
        if (passOwner == thief || notes.hasMinted(thief) || notes.totalMinted() == notes.MAX_SUPPLY()) return;
        keel.mint(thief, 1);
        bytes memory sig = _pass(passOwner, 1, block.timestamp);
        vm.prank(thief);
        vm.expectRevert(KeelNotes.InvalidPass.selector);
        notes.mint(1, block.timestamp, sig);
        ++hostileReverts;
    }

    function reuseBacking(uint256 seedA, uint256 seedB) external {
        (uint256 id, address holder, bool okB) = _live(seedB);
        if (!okB) return;
        // A burned Gold note's token stays used forever, so liveness of the first note is irrelevant.
        address token = backing[1 + seedA % notes.totalMinted()];
        if (token == address(0)) return;
        (KeelNotes.Level level,,,,,) = notes.noteInfo(id);
        if (level == KeelNotes.Level.Gold || notes.goldCount() == notes.MAX_GOLD()) return;
        vault.setCreator(token, holder);
        vm.prank(holder);
        vm.expectRevert(KeelNotes.BackingTokenUsed.selector);
        notes.upgradeToGold(id, token);
        ++hostileReverts;
    }

    function nonCreatorUpgrade(uint256 seed, uint256 actorSeed) external {
        (uint256 id, address holder, bool ok) = _live(seed);
        if (!ok) return;
        (KeelNotes.Level level,,,,,) = notes.noteInfo(id);
        if (level == KeelNotes.Level.Gold || notes.goldCount() == notes.MAX_GOLD()) return;
        address creator = actor(actorSeed);
        if (creator == holder) return;
        address token = address(uint160(0xC00000 + ++_backingNonce));
        factory.setLaunched(token, true);
        vault.setCreator(token, creator);
        vm.prank(holder);
        vm.expectRevert(KeelNotes.NotProjectCreator.selector);
        notes.upgradeToGold(id, token);
        // The creator is not the note owner either.
        vm.prank(creator);
        vm.expectRevert(KeelNotes.NotNoteOwner.selector);
        notes.upgradeToGold(id, token);
        hostileReverts += 2;
    }

    function unlaunchedUpgrade(uint256 seed) external {
        (uint256 id, address holder, bool ok) = _live(seed);
        if (!ok) return;
        (KeelNotes.Level level,,,,,) = notes.noteInfo(id);
        if (level == KeelNotes.Level.Gold || notes.goldCount() == notes.MAX_GOLD()) return;
        address token = address(uint160(0xD00000 + ++_backingNonce));
        vault.setCreator(token, holder);
        vm.prank(holder);
        vm.expectRevert(KeelNotes.NotLaunched.selector);
        notes.upgradeToGold(id, token);
        ++hostileReverts;
    }

    function rescueIMD(uint96 raw) external {
        vm.prank(owner);
        vm.expectRevert(KeelNotes.IMDRescueForbidden.selector);
        notes.rescueToken(address(imd), owner, raw);
        ++hostileReverts;
    }

    function strangerRescue(uint256 actorSeed) external {
        if (strayHeld == 0) return;
        vm.prank(actor(actorSeed));
        vm.expectRevert();
        notes.rescueToken(address(stray), actor(actorSeed), 1);
        ++hostileReverts;
    }

    function sendETH(uint96 raw) external {
        uint256 amount = bound(uint256(raw), 1, 100 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(notes).call{value: amount}("");
        assertFalse(ok, "ETH must be refused");
        ++hostileReverts;
    }

    function overfund(uint96 raw) external {
        if (notes.totalWeight() == 0) return;
        uint256 amount = bound(uint256(raw), 2, 1e27);
        imd.mint(address(this), amount - 1);
        imd.approve(address(notes), amount);
        vm.expectRevert();
        notes.fund(amount);
        imd.approve(address(notes), 0);
        imd.transfer(address(0xdead00), amount - 1);
        ++hostileReverts;
    }
}

contract AdversarialInvariantTest is KeelNotesTestBase {
    AdversarialHandler private handler;
    uint256 private constant PREMINT = 140;
    uint256 private constant PREGOLD = 100;

    function setUp() public override {
        super.setUp();
        handler = new AdversarialHandler(notes, keel, owner, SIGNER_KEY);
        for (uint256 i; i < PREMINT; ++i) {
            handler.mint(i);
        }
        for (uint256 i; i < PREGOLD; ++i) {
            handler.upgrade(i);
        }
        excludeSender(address(notes));
        targetContract(address(handler));
    }

    function _sumPending() internal view returns (uint256 sum, uint256 live, uint256 goldLive) {
        uint256 minted = notes.totalMinted();
        for (uint256 id = 1; id <= minted; ++id) {
            try notes.ownerOf(id) returns (address) {
                (KeelNotes.Level level, uint256 weight,,, uint256 p,) = notes.noteInfo(id);
                sum += p;
                ++live;
                if (level == KeelNotes.Level.Gold) {
                    ++goldLive;
                    assertEq(weight, 5);
                } else {
                    assertEq(weight, 1);
                }
            } catch {}
        }
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 48
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_conservationAndBoundedDust() public view {
        (uint256 owed, uint256 live,) = _sumPending();
        uint256 held = imd.balanceOf(address(notes));
        assertEq(notes.liabilities(), handler.credited() - handler.paid(), "liabilities track credits minus payouts");
        assertEq(held, handler.credited() + handler.uncredited() - handler.paid(), "every IMD wei accounted");
        assertGe(held, notes.liabilities(), "balance covers liabilities");
        assertGe(notes.liabilities(), owed, "liabilities cover every claim");
        // Holders lose at most rounding dust: < 1 wei per credit, per live note and per redemption.
        assertLe(notes.liabilities() - owed, handler.credits() + live + handler.burned(), "dust is bounded");
        assertEq(address(notes).balance, 0, "no ETH ever held");
        assertEq(handler.stray().balanceOf(address(notes)), handler.strayHeld(), "rescue moves only what it says");
    }

    /// forge-config: default.invariant.runs = 48
    /// forge-config: default.invariant.depth = 48
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_capsAndWeights() public view {
        (, uint256 live, uint256 goldLive) = _sumPending();
        assertLe(notes.totalMinted(), notes.MAX_SUPPLY());
        assertLe(notes.goldCount(), notes.MAX_GOLD(), "never more than 111 Gold");
        assertEq(notes.goldCount(), handler.gold(), "goldCount counts upgrades ever, not live Gold");
        assertGe(notes.goldCount(), goldLive);
        assertEq(notes.totalBurned(), handler.burned());
        assertEq(notes.totalSupply(), live);
        assertEq(notes.totalWeight(), live + 4 * goldLive, "total weight equals live 1:5 weights");
        assertGe(notes.totalMinted(), PREMINT);
    }
}
