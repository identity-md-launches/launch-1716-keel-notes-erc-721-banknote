// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelNotesTestBase} from "./KeelNotesTestBase.sol";
import {KeelNotes} from "../src/KeelNotes.sol";

/// @dev IMD transferred directly belongs to the weights that were live when it arrived. Every weight
/// change credits it first, so no mint, upgrade or redemption can take or forfeit earlier IMD.
contract SurplusSyncTest is KeelNotesTestBase {
    function test_laterMintGetsNoneOfEarlierDirectIMD() public {
        _mintTo(alice);
        imd.mint(address(notes), 100 ether);
        (uint256 deadline, bytes memory sig) = _preparePass(bob);
        vm.expectEmit(true, true, true, true, address(notes));
        emit KeelNotes.Funded(bob, 100 ether, 100 ether * 1e36, true);
        vm.prank(bob);
        notes.mint(MINIMUM, deadline, sig);
        assertEq(notes.pending(1), 100 ether);
        assertEq(notes.pending(2), 0);
        notes.creditSurplus();
        assertEq(notes.pending(1), 100 ether);
        assertEq(notes.pending(2), 0);
        assertEq(notes.liabilities(), 100 ether);
        _assertSolvent();
    }

    function test_goldUpgradeCollectsEarlierDirectIMDAtStandardWeight() public {
        _mintTo(alice);
        _mintTo(bob);
        imd.mint(address(notes), 120 ether);
        _gold(2, "GOLD");
        assertEq(notes.pending(1), 60 ether);
        assertEq(notes.pending(2), 60 ether);
        notes.creditSurplus();
        assertEq(notes.pending(1), 60 ether);
        assertEq(notes.pending(2), 60 ether);
        imd.mint(address(notes), 60 ether);
        notes.creditSurplus();
        assertEq(notes.pending(1), 70 ether);
        assertEq(notes.pending(2), 110 ether);
        _assertSolvent();
    }

    function test_redeemBeforeAnyCreditPaysTheNoteShare() public {
        _mintTo(alice);
        _mintTo(bob);
        _fund(10 ether);
        imd.mint(address(notes), 100 ether);
        vm.prank(alice);
        notes.redeem(1);
        assertEq(imd.balanceOf(alice), 55 ether);
        assertEq(notes.pending(2), 55 ether);
        assertEq(notes.liabilities(), 55 ether);
        notes.creditSurplus();
        assertEq(notes.pending(2), 55 ether);
        vm.prank(bob);
        notes.redeem(2);
        assertEq(imd.balanceOf(bob), 55 ether);
        assertEq(imd.balanceOf(address(notes)), 0);
        _assertSolvent();
    }

    function test_redeemWithOnlyUncreditedRewardsSucceeds() public {
        _mintTo(alice);
        _mintTo(bob);
        imd.mint(address(notes), 10 ether);
        assertEq(notes.pending(1), 0);
        vm.prank(alice);
        notes.redeem(1);
        assertEq(imd.balanceOf(alice), 5 ether);
        assertEq(notes.pending(2), 5 ether);
        assertEq(notes.totalWeight(), 1);
        _assertSolvent();
    }

    function test_mintThenCreditThenRedeemInOneTransactionTakesNothingEarlier() public {
        _mintTo(alice);
        _mintTo(bob);
        imd.mint(address(notes), 100 ether);
        // Carol's mint, credit and redemption in one call cannot reach IMD that arrived before her note.
        _mintTo(carol);
        notes.creditSurplus();
        vm.prank(carol);
        vm.expectRevert(KeelNotes.NoRewards.selector);
        notes.redeem(3);
        assertEq(notes.pending(1), 50 ether);
        assertEq(notes.pending(2), 50 ether);
        assertEq(notes.pending(3), 0);
    }

    function test_preMintDepositIsReservedForNobody() public {
        imd.mint(address(notes), 1000 ether);
        vm.expectRevert(KeelNotes.NoWeight.selector);
        notes.creditSurplus();
        (uint256 deadline, bytes memory sig) = _preparePass(alice);
        vm.expectEmit(true, true, true, true, address(notes));
        emit KeelNotes.SurplusStranded(1000 ether);
        vm.prank(alice);
        notes.mint(MINIMUM, deadline, sig);
        assertEq(notes.pending(1), 0);
        assertEq(notes.liabilities(), 1000 ether);
        assertEq(notes.accPerWeight(), 0);
        notes.creditSurplus();
        assertEq(notes.pending(1), 0);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.NoRewards.selector);
        notes.redeem(1);
        _mintTo(bob);
        assertEq(notes.pending(2), 0);
        vm.prank(owner);
        vm.expectRevert(KeelNotes.IMDRescueForbidden.selector);
        notes.rescueToken(address(imd), owner, 1000 ether);
        // Funding after the first mint is shared normally and the reserve keeps the stranded amount.
        _fund(10 ether);
        assertEq(notes.pending(1), 5 ether);
        assertEq(notes.pending(2), 5 ether);
        assertEq(notes.liabilities(), 1010 ether);
        _assertSolvent();
    }

    function test_depositWhileAllNotesRedeemedIsReservedForNobody() public {
        _mintTo(alice);
        _fund(10 ether);
        vm.prank(alice);
        notes.redeem(1);
        assertEq(notes.totalWeight(), 0);
        imd.mint(address(notes), 7 ether);
        _mintTo(bob);
        assertEq(notes.pending(2), 0);
        assertEq(notes.liabilities(), 7 ether);
        assertEq(imd.balanceOf(address(notes)), 7 ether);
        _assertSolvent();
    }

    function test_shortfallDoesNotBlockWeightChanges() public {
        _mintTo(alice);
        _mintTo(bob);
        _fund(10 ether);
        imd.slash(address(notes), 1);
        vm.expectRevert(KeelNotes.Insolvent.selector);
        notes.creditSurplus();
        // Mint and upgrade still work because the sync skips a balance below the reserve.
        _mintTo(carol);
        _gold(3, "GOLD");
        assertEq(notes.pending(3), 0);
        // Redemption still refuses to pay out of a reserve the token no longer backs.
        vm.prank(alice);
        vm.expectRevert(KeelNotes.Insolvent.selector);
        notes.redeem(1);
        assertEq(notes.ownerOf(1), alice);
    }

    function testFuzz_directIMDFollowsLiveWeightsAcrossWeightChanges(uint96 first, uint96 second, bool goldFirst)
        public
    {
        uint256 a = bound(uint256(first), 2, 1e24);
        uint256 b = bound(uint256(second), 6, 1e24);
        _mintTo(alice);
        _mintTo(bob);
        imd.mint(address(notes), a);
        // a arrives at 1:1; the weight change afterwards must not move any of it.
        if (goldFirst) _gold(2, "GOLD");
        else _mintTo(carol);
        uint256 scaledA = a * 1e36 / 2;
        assertEq(notes.pending(1), scaledA / 1e36);
        assertEq(notes.pending(2), scaledA / 1e36);
        if (!goldFirst) assertEq(notes.pending(3), 0);
        imd.mint(address(notes), b);
        vm.prank(alice);
        notes.redeem(1);
        uint256 weightAfter = goldFirst ? 6 : 3;
        uint256 scaledB = b * 1e36 / weightAfter;
        // Each note keeps its sub-unit fraction, so the floor applies to the sum of both credits.
        assertEq(imd.balanceOf(alice), (scaledA + scaledB) / 1e36);
        assertEq(notes.pending(2), (scaledA + scaledB * (goldFirst ? 5 : 1)) / 1e36);
        if (!goldFirst) assertEq(notes.pending(3), scaledB / 1e36);
        _assertSolvent();
    }
}
