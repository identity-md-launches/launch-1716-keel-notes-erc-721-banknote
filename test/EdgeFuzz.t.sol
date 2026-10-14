// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelNotesTestBase} from "./KeelNotesTestBase.sol";
import {KeelNotes} from "../src/KeelNotes.sol";

contract EdgeFuzzTest is KeelNotesTestBase {
    uint256 private constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_passFromAnyOtherKeyIsRejected(uint256 key) public {
        key = bound(key, 1, SECP256K1_N - 1);
        if (key == SIGNER_KEY) key = SIGNER_KEY + 1;
        keel.mint(alice, MINIMUM);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = _signature(notes, alice, MINIMUM, deadline, key);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.InvalidPass.selector);
        notes.mint(MINIMUM, deadline, sig);
        assertFalse(notes.hasMinted(alice));
        assertEq(notes.totalMinted(), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_passFieldsAreBound(
        uint256 signedMin,
        uint256 claimedMin,
        uint256 signedDeadline,
        uint256 claimedDeadline
    ) public {
        signedMin = bound(signedMin, 1, 1e30);
        claimedMin = bound(claimedMin, 1, 1e30);
        signedDeadline = bound(signedDeadline, block.timestamp, block.timestamp + 365 days);
        claimedDeadline = bound(claimedDeadline, block.timestamp, block.timestamp + 365 days);
        keel.mint(alice, 1e30);
        bytes memory sig = _signature(notes, alice, signedMin, signedDeadline, SIGNER_KEY);
        vm.prank(alice);
        if (signedMin != claimedMin || signedDeadline != claimedDeadline) {
            vm.expectRevert(KeelNotes.InvalidPass.selector);
            notes.mint(claimedMin, claimedDeadline, sig);
            assertEq(notes.totalMinted(), 0);
        } else {
            assertEq(notes.mint(claimedMin, claimedDeadline, sig), 1);
        }
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_liveKeelBalanceMustMeetMinimum(uint256 minimum, uint256 balance) public {
        minimum = bound(minimum, 1, 1e30);
        balance = bound(balance, 0, 1e30);
        keel.mint(alice, balance);
        uint256 deadline = block.timestamp;
        bytes memory sig = _signature(notes, alice, minimum, deadline, SIGNER_KEY);
        vm.prank(alice);
        if (balance < minimum) {
            vm.expectRevert(KeelNotes.InsufficientKeel.selector);
            notes.mint(minimum, deadline, sig);
            assertFalse(notes.hasMinted(alice));
        } else {
            notes.mint(minimum, deadline, sig);
            assertTrue(notes.hasMinted(alice));
            assertEq(keel.balanceOf(alice), balance, "mint is free and does not take Keel");
        }
    }

    function testFuzz_expiredPassRejected(uint256 lateBy) public {
        lateBy = bound(lateBy, 1, 10 * 365 days);
        keel.mint(alice, MINIMUM);
        // Literal timestamps: via-IR may re-read block.timestamp after a warp.
        uint256 deadline = 1_700_000_000;
        vm.warp(deadline);
        bytes memory sig = _signature(notes, alice, MINIMUM, deadline, SIGNER_KEY);
        vm.warp(1_700_000_000 + lateBy);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.PassExpired.selector);
        notes.mint(MINIMUM, deadline, sig);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splitIsOneToFiveForAnyGoldSet(uint8 mask, uint128 rawAmount) public {
        uint256 amount = bound(rawAmount, 1, type(uint128).max);
        uint256 weight;
        for (uint256 i; i < 8; ++i) {
            address holder = address(uint160(0x5000 + i));
            uint256 id = _mintTo(holder);
            if (mask & (1 << i) != 0) {
                _gold(id, "GOLD");
                weight += 5;
            } else {
                weight += 1;
            }
        }
        assertEq(notes.totalWeight(), weight);
        _fund(amount);
        uint256 per = amount * 1e36 / weight;
        uint256 sum;
        for (uint256 id = 1; id <= 8; ++id) {
            bool isGold = mask & (1 << (id - 1)) != 0;
            uint256 p = notes.pending(id);
            assertEq(p, (isGold ? 5 : 1) * per / 1e36, "share is weight * floor(amount / totalWeight)");
            sum += p;
        }
        assertLe(sum, amount, "never pays more than funded");
        assertGe(sum + 8, amount, "loses at most one wei per note");

        uint256 paidOut;
        for (uint256 id = 1; id <= 8; ++id) {
            address holder = notes.ownerOf(id);
            uint256 p = notes.pending(id);
            if (p == 0) continue;
            vm.prank(holder);
            notes.redeem(id);
            paidOut += p;
        }
        assertEq(imd.balanceOf(address(notes)), amount - paidOut);
        assertGe(imd.balanceOf(address(notes)), notes.liabilities());
    }

    function testFuzz_laterNoteGetsNothingFromEarlierFunding(uint128 first, uint128 second) public {
        uint256 a = bound(first, 1, 1e30);
        uint256 b = bound(second, 1, 1e30);
        _mintTo(alice);
        _fund(a);
        uint256 late = _mintTo(bob);
        assertEq(notes.pending(late), 0);
        vm.prank(bob);
        vm.expectRevert(KeelNotes.NoRewards.selector);
        notes.redeem(late);
        _fund(b);
        assertEq(notes.pending(late), b * 1e36 / 2 / 1e36);
        assertEq(notes.pending(1), a + b * 1e36 / 2 / 1e36);
    }

    function test_zeroAndSelfReferencingBackingTokensRejected() public {
        uint256 id = _mintTo(alice);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.NotLaunched.selector);
        notes.upgradeToGold(id, address(0));
        // Even if the factory reported the note contract itself as launched, alice is not its creator.
        factory.setLaunched(address(notes), true);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.NotProjectCreator.selector);
        notes.upgradeToGold(id, address(notes));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("ERC721NonexistentToken(uint256)", 999));
        notes.upgradeToGold(999, address(notes));
        (KeelNotes.Level level,,,,,) = notes.noteInfo(id);
        assertEq(uint8(level), uint8(KeelNotes.Level.Standard));
        assertEq(notes.goldCount(), 0);
    }

    function test_goldRedeemRemovesFiveWeightButKeepsCapSlot() public {
        uint256 a = _mintTo(alice);
        _mintTo(bob);
        _gold(a, "AAA");
        assertEq(notes.totalWeight(), 6);
        _fund(6 ether);
        vm.prank(alice);
        notes.redeem(a);
        assertEq(imd.balanceOf(alice), 5 ether);
        assertEq(notes.totalWeight(), 1);
        assertEq(notes.goldCount(), 1, "burn never frees a Gold slot");
        _fund(1 ether);
        assertEq(notes.pending(2), 2 ether, "remaining note receives everything after the Gold burn");
    }

    function test_closingMintBlocksValidPassAndReopenRestoresIt() public {
        keel.mint(alice, MINIMUM);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signature(notes, alice, MINIMUM, deadline, SIGNER_KEY);
        vm.prank(owner);
        notes.setMintOpen(false);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.MintClosed.selector);
        notes.mint(MINIMUM, deadline, sig);
        vm.prank(owner);
        notes.setMintOpen(true);
        vm.prank(alice);
        assertEq(notes.mint(MINIMUM, deadline, sig), 1);
    }

    function test_reopeningAfterSignerRevokedIsRefused() public {
        vm.startPrank(owner);
        notes.setMintOpen(false);
        notes.revokePassSigner();
        vm.expectRevert(KeelNotes.PassSignerNotSet.selector);
        notes.setMintOpen(true);
        vm.stopPrank();
    }
}
