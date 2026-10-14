// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelNotesTestBase} from "./KeelNotesTestBase.sol";
import {KeelNotes} from "../src/KeelNotes.sol";
import {KeelNoteArt} from "../src/KeelNoteArt.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Mock1271, ContractMinter} from "./mocks/Mocks.sol";

contract MintAndConfigTest is KeelNotesTestBase {
    function test_deploymentStartsClosedWithExplicitOwnerAndNoExternalCalls() public {
        address absentArt = makeAddr("art not yet deployed");
        KeelNotes fresh = new KeelNotes(owner, absentArt);
        assertEq(fresh.name(), "Keel Notes");
        assertEq(fresh.symbol(), "KNOTE");
        assertEq(fresh.owner(), owner);
        assertEq(address(fresh.art()), absentArt);
        assertFalse(fresh.mintOpen());
        assertEq(fresh.keelToken(), address(0));
        assertEq(fresh.passSigner(), address(0));
        vm.expectRevert(KeelNotes.MintClosed.selector);
        fresh.mint(1, block.timestamp, "");
    }

    function test_zeroConstructorArgumentsRejected() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new KeelNotes(address(0), address(art));
        vm.expectRevert(KeelNotes.ZeroAddress.selector);
        new KeelNotes(owner, address(0));
    }

    function test_unconfiguredOpeningAndOneTimeKeel() public {
        KeelNotes fresh = new KeelNotes(owner, address(art));
        vm.startPrank(owner);
        vm.expectRevert(KeelNotes.KeelTokenNotSet.selector);
        fresh.setMintOpen(true);
        vm.expectRevert(KeelNotes.ZeroAddress.selector);
        fresh.setKeelToken(address(0));
        fresh.setKeelToken(address(keel));
        vm.expectRevert(KeelNotes.KeelTokenAlreadySet.selector);
        fresh.setKeelToken(address(keel));
        vm.expectRevert(KeelNotes.PassSignerNotSet.selector);
        fresh.setMintOpen(true);
        vm.expectRevert(KeelNotes.ZeroAddress.selector);
        fresh.setPassSigner(address(0));
        fresh.setPassSigner(signer);
        fresh.setMintOpen(true);
        vm.stopPrank();
        assertTrue(fresh.mintOpen());
    }

    function test_validPassMintsFreeAndReportsInfo() public {
        vm.warp(1_800_000_000);
        uint256 id = _mintTo(alice);
        assertEq(id, 1);
        assertEq(notes.ownerOf(id), alice);
        assertEq(notes.balanceOf(alice), 1);
        assertTrue(notes.hasMinted(alice));
        assertEq(notes.totalMinted(), 1);
        assertEq(notes.totalSupply(), 1);
        assertEq(notes.totalWeight(), 1);
        assertEq(keel.balanceOf(alice), MINIMUM);
        assertEq(address(notes).balance, 0);
        (
            KeelNotes.Level level,
            uint256 weight,
            address backing,
            string memory symbol,
            uint256 pending,
            uint64 mintedAt
        ) = notes.noteInfo(id);
        assertEq(uint256(level), uint256(KeelNotes.Level.Standard));
        assertEq(weight, 1);
        assertEq(backing, address(0));
        assertEq(symbol, "");
        assertEq(pending, 0);
        assertEq(mintedAt, block.timestamp);
        assertTrue(notes.supportsInterface(0x80ac58cd));
        assertTrue(notes.supportsInterface(0x5b5e139f));
    }

    function test_contractWithoutReceiverCanMint() public {
        ContractMinter minter = new ContractMinter();
        keel.mint(address(minter), MINIMUM);
        bytes memory sig = _signature(notes, address(minter), MINIMUM, block.timestamp, SIGNER_KEY);
        minter.mint(notes, MINIMUM, block.timestamp, sig);
        assertEq(notes.ownerOf(1), address(minter));
    }

    function test_deadlineInclusiveThenExpired() public {
        uint256 expired = 100_000;
        vm.warp(expired);
        keel.mint(alice, MINIMUM);
        bytes memory sig = _signature(notes, alice, MINIMUM, expired, SIGNER_KEY);
        vm.prank(alice);
        notes.mint(MINIMUM, expired, sig);
        bytes memory sig2 = _signature(notes, bob, MINIMUM, expired, SIGNER_KEY);
        vm.warp(expired + 1);
        vm.prank(bob);
        vm.expectRevert(KeelNotes.PassExpired.selector);
        notes.mint(MINIMUM, expired, sig2);
    }

    function test_passCannotBeUsedByDifferentRecipient() public {
        keel.mint(bob, MINIMUM);
        bytes memory sig = _signature(notes, alice, MINIMUM, block.timestamp, SIGNER_KEY);
        vm.prank(bob);
        vm.expectRevert(KeelNotes.InvalidPass.selector);
        notes.mint(MINIMUM, block.timestamp, sig);
    }

    function test_wrongSignerTamperedMinimumDeadlineAndMalformedSignature() public {
        keel.mint(alice, MINIMUM);
        bytes memory sig = _signature(notes, alice, MINIMUM, block.timestamp, SIGNER_KEY + 1);
        vm.startPrank(alice);
        vm.expectRevert(KeelNotes.InvalidPass.selector);
        notes.mint(MINIMUM, block.timestamp, sig);
        vm.stopPrank();
        sig = _signature(notes, alice, MINIMUM, block.timestamp, SIGNER_KEY);
        vm.startPrank(alice);
        vm.expectRevert(KeelNotes.InvalidPass.selector);
        notes.mint(MINIMUM - 1, block.timestamp, sig);
        vm.expectRevert(KeelNotes.InvalidPass.selector);
        notes.mint(MINIMUM, block.timestamp + 1, sig);
        vm.expectRevert(KeelNotes.InvalidPass.selector);
        notes.mint(MINIMUM, block.timestamp, hex"1234");
        vm.stopPrank();
        assertFalse(notes.hasMinted(alice));
    }

    function test_domainBindsChainAndContract() public {
        vm.chainId(1);
        keel.mint(alice, MINIMUM);
        bytes memory sig = _signature(notes, alice, MINIMUM, block.timestamp, SIGNER_KEY);
        vm.chainId(2);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.InvalidPass.selector);
        notes.mint(MINIMUM, block.timestamp, sig);
        vm.chainId(1);
        KeelNotes second = new KeelNotes(owner, address(art));
        vm.startPrank(owner);
        second.setKeelToken(address(keel));
        second.setPassSigner(signer);
        second.setMintOpen(true);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(KeelNotes.InvalidPass.selector);
        second.mint(MINIMUM, block.timestamp, sig);
    }

    function test_positiveMinimumAndLiveBalanceRequired() public {
        bytes memory zeroSig = _signature(notes, alice, 0, block.timestamp, SIGNER_KEY);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.ZeroMinimum.selector);
        notes.mint(0, block.timestamp, zeroSig);
        keel.mint(alice, MINIMUM);
        bytes memory sig = _signature(notes, alice, MINIMUM, block.timestamp, SIGNER_KEY);
        vm.prank(alice);
        keel.transfer(bob, 1);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.InsufficientKeel.selector);
        notes.mint(MINIMUM, block.timestamp, sig);
        assertFalse(notes.hasMinted(alice));
        keel.mint(alice, 1);
        vm.prank(alice);
        notes.mint(MINIMUM, block.timestamp, sig);
    }

    function test_oneMintEverEvenAfterTransferOrRedemption() public {
        _mintTo(alice);
        vm.prank(alice);
        notes.transferFrom(alice, bob, 1);
        _mintTo(bob); // Receiving somebody else's note does not consume a mint.
        _fund(2 ether);
        vm.prank(bob);
        notes.redeem(2);
        bytes memory sig = _signature(notes, alice, MINIMUM, block.timestamp, SIGNER_KEY);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.AlreadyMinted.selector);
        notes.mint(MINIMUM, block.timestamp, sig);
        sig = _signature(notes, bob, MINIMUM, block.timestamp, SIGNER_KEY);
        vm.prank(bob);
        vm.expectRevert(KeelNotes.AlreadyMinted.selector);
        notes.mint(MINIMUM, block.timestamp, sig);
    }

    function test_lifetimeSupplyCapDoesNotReopenOnBurn() public {
        for (uint256 i = 1; i <= 1111; ++i) {
            uint256 id = _mintTo(address(uint160(0x10000 + i)));
            assertEq(id, i);
        }
        assertEq(notes.totalMinted(), 1111);
        _fund(1111 ether);
        vm.prank(address(uint160(0x10001)));
        notes.redeem(1);
        assertEq(notes.totalSupply(), 1110);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.SupplyCap.selector);
        notes.mint(MINIMUM, block.timestamp, "");
        assertEq(notes.totalMinted(), 1111);
    }

    function test_ERC1271PassAndRevocation() public {
        Mock1271 contractSigner = new Mock1271();
        vm.prank(owner);
        notes.setPassSigner(address(contractSigner));
        keel.mint(alice, MINIMUM);
        keel.mint(bob, MINIMUM);
        bytes memory signature = hex"cafe1234";
        contractSigner.permit(notes.mintPassDigest(alice, MINIMUM, block.timestamp), signature);
        contractSigner.permit(notes.mintPassDigest(bob, MINIMUM, block.timestamp), signature);
        vm.prank(alice);
        notes.mint(MINIMUM, block.timestamp, signature);
        contractSigner.setRevoked(true);
        vm.prank(bob);
        vm.expectRevert(KeelNotes.InvalidPass.selector);
        notes.mint(MINIMUM, block.timestamp, signature);
        contractSigner.setRevoked(false);
        contractSigner.setRevert(true);
        vm.prank(bob);
        vm.expectRevert(KeelNotes.InvalidPass.selector);
        notes.mint(MINIMUM, block.timestamp, signature);
    }

    function test_signerRotationRevocationAndMintClosure() public {
        keel.mint(alice, MINIMUM);
        bytes memory sig = _signature(notes, alice, MINIMUM, block.timestamp, SIGNER_KEY);
        vm.prank(owner);
        notes.setPassSigner(bob);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.InvalidPass.selector);
        notes.mint(MINIMUM, block.timestamp, sig);
        vm.prank(owner);
        notes.revokePassSigner();
        vm.prank(alice);
        vm.expectRevert(KeelNotes.PassSignerNotSet.selector);
        notes.mint(MINIMUM, block.timestamp, sig);
        vm.startPrank(owner);
        notes.setPassSigner(signer);
        notes.setMintOpen(false);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(KeelNotes.MintClosed.selector);
        notes.mint(MINIMUM, block.timestamp, sig);
    }

    function test_allSettingsRequireOwner() public {
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(unauthorized);
        notes.setKeelToken(address(keel));
        vm.expectRevert(unauthorized);
        notes.setPassSigner(alice);
        vm.expectRevert(unauthorized);
        notes.revokePassSigner();
        vm.expectRevert(unauthorized);
        notes.setMintOpen(false);
        vm.expectRevert(unauthorized);
        notes.setArt(alice);
        vm.stopPrank();
    }

    function test_twoStepOwnershipAndArtUpdate() public {
        vm.prank(owner);
        notes.transferOwnership(alice);
        assertEq(notes.owner(), owner);
        assertEq(notes.pendingOwner(), alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        notes.acceptOwnership();
        vm.prank(alice);
        notes.acceptOwnership();
        assertEq(notes.owner(), alice);
        KeelNoteArt replacement = new KeelNoteArt();
        vm.startPrank(alice);
        vm.expectRevert(KeelNotes.ZeroAddress.selector);
        notes.setArt(address(0));
        notes.setArt(address(replacement));
        vm.stopPrank();
        assertEq(address(notes.art()), address(replacement));
    }

    function test_unknownNoteViewsRevert() public {
        bytes memory unknown = abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1);
        vm.expectRevert(unknown);
        notes.noteInfo(1);
        vm.expectRevert(unknown);
        notes.pending(1);
        vm.expectRevert(unknown);
        notes.tokenURI(1);
    }
}
