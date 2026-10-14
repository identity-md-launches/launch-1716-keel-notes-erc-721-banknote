// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelNotesTestBase} from "./KeelNotesTestBase.sol";
import {KeelNotes} from "../src/KeelNotes.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract RedeemingReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256 id, bytes calldata) external returns (bytes4) {
        KeelNotes(msg.sender).redeem(id);
        return this.onERC721Received.selector;
    }
}

contract RewardsTest is KeelNotesTestBase {
    function test_oneToFiveSplit() public {
        _mintTo(alice);
        _mintTo(bob);
        _gold(2, "GOLD");
        _fund(60 ether);
        assertEq(notes.pending(1), 10 ether);
        assertEq(notes.pending(2), 50 ether);
        assertEq(notes.liabilities(), 60 ether);
        assertEq(notes.accPerWeight(), 10 ether * 1e36);
        _assertSolvent();
    }

    function test_upgradeSettlesStandardBeforeGoldRewards() public {
        _mintTo(alice);
        _mintTo(bob);
        _fund(20 ether);
        _gold(1, "GOLD");
        assertEq(notes.pending(1), 10 ether);
        _fund(60 ether);
        assertEq(notes.pending(1), 60 ether);
        assertEq(notes.pending(2), 20 ether);
        _assertSolvent();
    }

    function test_upgradePreservesFractionalStandardEarnings() public {
        _mintTo(alice);
        _mintTo(bob);
        _fund(1);
        assertEq(notes.pending(1), 0);
        _gold(1, "GOLD");
        _fund(3);
        assertEq(notes.pending(1), 3);
        assertEq(notes.pending(2), 1);
        _assertSolvent();
    }

    function test_laterNotesReceiveNoEarlierRewardsOrFractions() public {
        _mintTo(alice);
        _mintTo(bob);
        _mintTo(carol);
        _fund(2);
        address late = makeAddr("late minter");
        _mintTo(late);
        assertEq(notes.pending(4), 0);
        _fund(2);
        for (uint256 i = 1; i <= 3; ++i) {
            assertEq(notes.pending(i), 1);
        }
        assertEq(notes.pending(4), 0);
        _assertSolvent();
    }

    function test_transferKeepsPastAndFutureRewardsWithNote() public {
        _mintTo(alice);
        _fund(12 ether);
        vm.prank(alice);
        notes.approve(carol, 1);
        vm.prank(carol);
        notes.transferFrom(alice, bob, 1);
        assertEq(notes.pending(1), 12 ether);
        _fund(3 ether);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.NotNoteOwner.selector);
        notes.redeem(1);
        vm.prank(bob);
        notes.redeem(1);
        assertEq(imd.balanceOf(bob), 15 ether);
        assertEq(imd.balanceOf(alice), 0);
        _assertSolvent();
    }

    function test_safeTransferReceiverCanRedeemItsNewlyOwnedNote() public {
        _mintTo(alice);
        _fund(1 ether);
        RedeemingReceiver receiver = new RedeemingReceiver();
        vm.prank(alice);
        notes.safeTransferFrom(alice, address(receiver), 1);
        assertEq(imd.balanceOf(address(receiver)), 1 ether);
        assertEq(notes.totalBurned(), 1);
        _assertSolvent();
    }

    function test_redemptionBurnsAndRemovesWeightOnlyOwner() public {
        _mintTo(alice);
        _mintTo(bob);
        _gold(1, "GOLD");
        _fund(60 ether);
        vm.prank(alice);
        notes.setApprovalForAll(carol, true);
        vm.prank(carol);
        vm.expectRevert(KeelNotes.NotNoteOwner.selector);
        notes.redeem(1);
        vm.prank(alice);
        notes.redeem(1);
        assertEq(imd.balanceOf(alice), 50 ether);
        assertEq(notes.totalWeight(), 1);
        assertEq(notes.totalBurned(), 1);
        assertEq(notes.totalSupply(), 1);
        assertEq(notes.totalMinted(), 2);
        assertEq(notes.goldCount(), 1);
        assertTrue(notes.hasMinted(alice));
        bytes memory nonexistent = abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1);
        vm.expectRevert(nonexistent);
        notes.ownerOf(1);
        vm.expectRevert(nonexistent);
        notes.noteInfo(1);
        vm.expectRevert(nonexistent);
        notes.tokenURI(1);
        vm.prank(alice);
        vm.expectRevert(nonexistent);
        notes.redeem(1);
        _fund(4 ether);
        assertEq(notes.pending(2), 14 ether);
        _assertSolvent();
    }

    function test_redeemZeroRevertsWithoutBurn() public {
        _mintTo(alice);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.NoRewards.selector);
        notes.redeem(1);
        assertEq(notes.ownerOf(1), alice);
        assertEq(notes.totalBurned(), 0);
    }

    function test_fundNeedsWeightAndNonzeroReceipts() public {
        vm.expectRevert(KeelNotes.NoWeight.selector);
        notes.fund(1);
        imd.mint(address(notes), 100);
        vm.expectRevert(KeelNotes.NoWeight.selector);
        notes.creditSurplus();
        // IMD that arrived while no note was live is reserved by the first mint, not handed to the minter.
        (uint256 deadline, bytes memory sig) = _preparePass(alice);
        vm.expectEmit(true, true, true, true, address(notes));
        emit KeelNotes.SurplusStranded(100);
        vm.prank(alice);
        notes.mint(MINIMUM, deadline, sig);
        assertEq(notes.liabilities(), 100);
        assertEq(notes.pending(1), 0);
        vm.expectRevert(KeelNotes.ZeroReceived.selector);
        notes.fund(0);
        imd.setFee(10_000);
        imd.mint(address(this), 10);
        imd.approve(address(notes), 10);
        vm.expectRevert(KeelNotes.ZeroReceived.selector);
        notes.fund(10);
        assertEq(notes.liabilities(), 100);
        assertEq(imd.balanceOf(address(this)), 10);
        _assertSolvent();
    }

    function test_incomingTransferFeeCreditsOnlyReceived() public {
        _mintTo(alice);
        imd.setFee(1000);
        _fund(100 ether);
        assertEq(notes.pending(1), 90 ether);
        assertEq(notes.liabilities(), 90 ether);
        assertEq(imd.balanceOf(address(notes)), 90 ether);
        _assertSolvent();
    }

    function test_directTransfersAreCreditedExactlyOnceAndNotByFund() public {
        _mintTo(alice);
        imd.mint(address(this), 20 ether);
        imd.transfer(address(notes), 20 ether);
        assertEq(notes.pending(1), 0);
        _fund(3 ether);
        assertEq(notes.pending(1), 3 ether);
        vm.prank(bob);
        notes.creditSurplus();
        assertEq(notes.pending(1), 23 ether);
        assertEq(notes.liabilities(), 23 ether);
        // Nothing left to credit: a repeated call is a harmless no-op that changes no accounting.
        notes.creditSurplus();
        assertEq(notes.pending(1), 23 ether);
        assertEq(notes.liabilities(), 23 ether);
        _mintTo(bob);
        assertEq(notes.pending(2), 0);
        _assertSolvent();
    }

    function test_roundingDustIsReservedAndNeverAwardedToLaterNotes() public {
        _mintTo(alice);
        _mintTo(bob);
        _mintTo(carol);
        _fund(10);
        vm.prank(alice);
        notes.redeem(1);
        vm.prank(bob);
        notes.redeem(2);
        vm.prank(carol);
        notes.redeem(3);
        assertEq(notes.totalWeight(), 0);
        assertEq(notes.liabilities(), 1);
        assertEq(imd.balanceOf(address(notes)), 1);
        _mintTo(makeAddr("future minter"));
        assertEq(notes.pending(4), 0);
        notes.creditSurplus();
        assertEq(notes.pending(4), 0);
        assertEq(notes.liabilities(), 1);
        _fund(1);
        assertEq(notes.pending(4), 1);
        _assertSolvent();
    }

    function test_failedOutgoingTransferRollsBackWholeRedemption() public {
        _mintTo(alice);
        _gold(1, "GOLD");
        _fund(5 ether);
        imd.setFailure(true, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
        notes.redeem(1);
        _assertRedemptionRolledBack();
        imd.setFailure(false, true);
        vm.prank(alice);
        vm.expectRevert("payment rejected");
        notes.redeem(1);
        _assertRedemptionRolledBack();
        imd.setFailure(false, false);
        vm.prank(alice);
        notes.redeem(1);
        assertEq(imd.balanceOf(alice), 5 ether);
    }

    function test_failedIncomingTransferRollsBackCredit() public {
        _mintTo(alice);
        imd.mint(address(this), 10 ether);
        imd.approve(address(notes), 10 ether);
        imd.setFailure(true, false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(imd)));
        notes.fund(10 ether);
        assertEq(notes.pending(1), 0);
        assertEq(notes.liabilities(), 0);
        assertEq(notes.accPerWeight(), 0);
    }

    function test_noReturnERC20CanFundAndRedeem() public {
        _mintTo(alice);
        imd.setNoReturn(true);
        _fund(10 ether);
        vm.prank(alice);
        notes.redeem(1);
        assertEq(imd.balanceOf(alice), 10 ether);
        _assertSolvent();
    }

    function test_outgoingRecipientFeeRollsBackBurnUntilFullPaymentPossible() public {
        _mintTo(alice);
        imd.setFee(1000);
        _fund(100 ether);
        assertEq(notes.pending(1), 90 ether);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.IncompletePayment.selector);
        notes.redeem(1);
        assertEq(notes.ownerOf(1), alice);
        assertEq(notes.pending(1), 90 ether);
        assertEq(notes.totalBurned(), 0);
        assertEq(imd.balanceOf(alice), 0);
        _assertSolvent();
        imd.setFee(0);
        vm.prank(alice);
        notes.redeem(1);
        assertEq(imd.balanceOf(alice), 90 ether);
    }

    function test_outgoingSurchargeCannotSpendAnotherNotesReserve() public {
        _mintTo(alice);
        _mintTo(bob);
        _fund(10 ether);
        imd.setSurcharge(1);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.Insolvent.selector);
        notes.redeem(1);
        assertEq(notes.ownerOf(1), alice);
        assertEq(notes.pending(1), 5 ether);
        assertEq(notes.liabilities(), 10 ether);
        _assertSolvent();
    }

    function test_externalBalanceLossIsDetected() public {
        _mintTo(alice);
        _fund(10);
        imd.slash(address(notes), 1);
        vm.expectRevert(KeelNotes.Insolvent.selector);
        notes.creditSurplus();
        vm.expectRevert(KeelNotes.Insolvent.selector);
        notes.fund(1);
    }

    function test_fundAndRedeemReentrancyBlocked() public {
        _mintTo(alice);
        imd.setCallback(address(notes), abi.encodeCall(notes.creditSurplus, ()), true);
        _fund(10 ether);
        assertFalse(imd.callbackSuccess());
        assertEq(imd.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(notes.pending(1), 10 ether);
        imd.setCallback(address(notes), abi.encodeCall(notes.redeem, (1)), true);
        vm.prank(alice);
        notes.redeem(1);
        assertFalse(imd.callbackSuccess());
        assertEq(imd.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(imd.balanceOf(alice), 10 ether);
        assertEq(notes.totalBurned(), 1);
        _assertSolvent();
    }

    function test_noOtherBurnPath() public {
        _mintTo(alice);
        vm.prank(alice);
        (bool success,) = address(notes).call(abi.encodeWithSignature("burn(uint256)", 1));
        assertFalse(success);
        vm.prank(owner);
        (success,) = address(notes).call(abi.encodeWithSignature("burn(uint256)", 1));
        assertFalse(success);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        notes.transferFrom(alice, address(0), 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        notes.safeTransferFrom(alice, address(0), 1);
        assertEq(notes.totalBurned(), 0);
        assertEq(notes.ownerOf(1), alice);
    }

    function test_noteCannotBeTransferredToTheCollection() public {
        _mintTo(alice);
        _mintTo(bob);
        vm.prank(alice);
        notes.approve(carol, 1);
        vm.startPrank(alice);
        vm.expectRevert(KeelNotes.TransferToCollection.selector);
        notes.transferFrom(alice, address(notes), 1);
        vm.expectRevert(KeelNotes.TransferToCollection.selector);
        notes.safeTransferFrom(alice, address(notes), 1);
        vm.stopPrank();
        vm.prank(carol);
        vm.expectRevert(KeelNotes.TransferToCollection.selector);
        notes.transferFrom(alice, address(notes), 1);
        assertEq(notes.ownerOf(1), alice);
        assertEq(notes.totalWeight(), 2);
        vm.prank(alice);
        notes.transferFrom(alice, carol, 1);
        assertEq(notes.ownerOf(1), carol);
    }

    function test_rescueOnlyOwnerAndNeverIMD() public {
        keel.mint(address(notes), 20);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        notes.rescueToken(address(keel), alice, 20);
        vm.startPrank(owner);
        vm.expectRevert(KeelNotes.IMDRescueForbidden.selector);
        notes.rescueToken(address(imd), owner, 0);
        vm.expectRevert(KeelNotes.ZeroAddress.selector);
        notes.rescueToken(address(keel), address(0), 20);
        notes.rescueToken(address(keel), alice, 20);
        vm.stopPrank();
        assertEq(keel.balanceOf(alice), 20);
    }

    function test_ETHAndUnknownSelectorsRevertOnBothContracts() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(notes).call{value: 1}("");
        assertFalse(success);
        (success,) = address(art).call{value: 1}("");
        assertFalse(success);
        (success,) = address(notes).call(hex"cafebabe");
        assertFalse(success);
        (success,) = address(art).call(hex"cafebabe");
        assertFalse(success);
        (success,) = address(notes).call{value: 1}(abi.encodeCall(notes.mint, (MINIMUM, block.timestamp, bytes(""))));
        assertFalse(success);
        assertEq(address(notes).balance, 0);
    }

    function testFuzz_weightedPayoutConservation(uint128 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 6, 1e30);
        _mintTo(alice);
        _mintTo(bob);
        _gold(2, "GOLD");
        _fund(amount);
        uint256 index = amount * 1e36 / 6;
        uint256 standard = index / 1e36;
        uint256 gold = index * 5 / 1e36;
        assertEq(notes.pending(1), standard);
        assertEq(notes.pending(2), gold);
        vm.prank(bob);
        notes.redeem(2);
        vm.prank(alice);
        notes.redeem(1);
        assertEq(imd.balanceOf(alice) + imd.balanceOf(bob), standard + gold);
        assertEq(imd.balanceOf(address(notes)), amount - standard - gold);
        assertEq(notes.liabilities(), amount - standard - gold);
        _assertSolvent();
    }

    function test_fullPrecisionProductsAndAccumulatorOverflowRollback() public {
        _mintTo(alice);
        _gold(1, "LARGE");
        uint256 amount = 3e41;
        // Both amount * 1e36 and the note's accumulator * 5 exceed uint256.
        _fund(amount);
        assertEq(notes.pending(1), amount);
        assertEq(notes.accPerWeight(), 6e76);
        imd.mint(address(this), amount);
        imd.approve(address(notes), amount);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        notes.fund(amount);
        assertEq(notes.liabilities(), amount);
        assertEq(imd.balanceOf(address(notes)), amount);
        assertEq(imd.balanceOf(address(this)), amount);
        assertEq(notes.pending(1), amount);
        vm.prank(alice);
        notes.redeem(1);
        assertEq(imd.balanceOf(alice), amount);
        _assertSolvent();
    }

    function testFuzz_mintUpgradeTransferThenRedeem(uint128 first, uint128 second, bool reverse) public {
        uint256 a = bound(uint256(first), 2, 1e28);
        uint256 b = bound(uint256(second), 6, 1e28);
        _mintTo(alice);
        _fund(a);
        _mintTo(bob);
        _gold(2, "GOLD");
        _fund(b);
        uint256 index = b * 1e36 / 6;
        assertEq(notes.pending(1), a + index / 1e36);
        assertEq(notes.pending(2), index * 5 / 1e36);
        vm.prank(alice);
        notes.transferFrom(alice, carol, 1);
        uint256 firstId = reverse ? 2 : 1;
        uint256 secondId = reverse ? 1 : 2;
        address holder = notes.ownerOf(firstId);
        vm.prank(holder);
        notes.redeem(firstId);
        _assertSolvent();
        holder = notes.ownerOf(secondId);
        vm.prank(holder);
        notes.redeem(secondId);
        assertLe(imd.balanceOf(carol) + imd.balanceOf(bob), a + b);
        _assertSolvent();
    }

    function _assertRedemptionRolledBack() private view {
        assertEq(notes.ownerOf(1), alice);
        assertEq(notes.pending(1), 5 ether);
        assertEq(notes.totalWeight(), 5);
        assertEq(notes.totalBurned(), 0);
        assertEq(notes.liabilities(), 5 ether);
        assertEq(imd.balanceOf(alice), 0);
        _assertSolvent();
    }
}
