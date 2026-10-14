// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelNotesTestBase} from "./KeelNotesTestBase.sol";
import {KeelNotes} from "../src/KeelNotes.sol";
import {MockToken, RevertingSymbol, MalformedSymbol, ExpensiveSymbol, HugeSymbol} from "./mocks/Mocks.sol";

contract GoldTest is KeelNotesTestBase {
    function test_goldEngravesTokenAndSymbolOnce() public {
        _mintTo(alice);
        address token = _gold(1, "Keel123");
        MockToken(token).setSymbol("CHANGED");
        (KeelNotes.Level level, uint256 weight, address backing, string memory symbol,,) = notes.noteInfo(1);
        assertEq(uint256(level), uint256(KeelNotes.Level.Gold));
        assertEq(weight, 5);
        assertEq(backing, token);
        assertEq(symbol, "Keel123");
        assertTrue(notes.usedBackingToken(token));
        assertEq(notes.totalWeight(), 5);
        assertEq(notes.goldCount(), 1);
    }

    function test_onlyCurrentOwnerAndCreatorCanUpgrade() public {
        _mintTo(alice);
        address token = _project(alice, "KEEL");
        vm.prank(alice);
        notes.approve(bob, 1);
        vm.prank(bob);
        vm.expectRevert(KeelNotes.NotNoteOwner.selector);
        notes.upgradeToGold(1, token);
        vault.setCreator(token, bob);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.NotProjectCreator.selector);
        notes.upgradeToGold(1, token);
        vm.prank(alice);
        notes.transferFrom(alice, bob, 1);
        vm.prank(bob);
        notes.upgradeToGold(1, token);
        assertEq(notes.goldCount(), 1);
    }

    function test_mustBeLaunchedAndStandard() public {
        _mintTo(alice);
        address token = _project(alice, "KEEL");
        factory.setLaunched(token, false);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.NotLaunched.selector);
        notes.upgradeToGold(1, token);
        factory.setLaunched(token, true);
        vm.prank(alice);
        notes.upgradeToGold(1, token);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.AlreadyGold.selector);
        notes.upgradeToGold(1, token);
    }

    function test_tokenCannotBackAnotherNoteEvenAfterBurn() public {
        _mintTo(alice);
        _mintTo(bob);
        vm.prank(bob);
        notes.transferFrom(bob, alice, 2);
        address token = _gold(1, "ONCE");
        vm.prank(alice);
        vm.expectRevert(KeelNotes.BackingTokenUsed.selector);
        notes.upgradeToGold(2, token);
        _fund(6 ether);
        vm.prank(alice);
        notes.redeem(1);
        vm.prank(alice);
        vm.expectRevert(KeelNotes.BackingTokenUsed.selector);
        notes.upgradeToGold(2, token);
        assertEq(notes.goldCount(), 1);
    }

    function test_goldLifetimeCapAndBurnDoesNotFreeSlot() public {
        for (uint256 i = 1; i <= 112; ++i) {
            _mintTo(address(uint160(0x20000 + i)));
            if (i <= 111) _gold(i, "CAP");
        }
        assertEq(notes.goldCount(), 111);
        assertEq(notes.totalWeight(), 556);
        address holder = notes.ownerOf(112);
        address token = _project(holder, "EXTRA");
        vm.prank(holder);
        vm.expectRevert(KeelNotes.GoldCap.selector);
        notes.upgradeToGold(112, token);
        _fund(556 ether);
        address goldHolder = notes.ownerOf(1);
        vm.prank(goldHolder);
        notes.redeem(1);
        assertEq(notes.goldCount(), 111);
        assertEq(notes.totalWeight(), 551);
        vm.prank(holder);
        vm.expectRevert(KeelNotes.GoldCap.selector);
        notes.upgradeToGold(112, token);
    }

    function test_symbolsMustBeNonemptyAlphanumericAndAtMost16() public {
        _checkSymbol("", "?");
        _checkSymbol("0123456789abcdef", "0123456789abcdef");
        _checkSymbol("0123456789abcdefg", "?");
        _checkSymbol("A B", "?");
        _checkSymbol("$KEEL", "?");
        _checkSymbol("<script>&", "?");
        _checkSymbol(unicode"Kéel", "?");
        _checkSymbol("aAZz09", "aAZz09");
    }

    function test_revertingMalformedExpensiveAndHugeMetadataFallBack() public {
        _checkBroken(address(new RevertingSymbol()));
        _checkBroken(address(new MalformedSymbol()));
        _checkBroken(address(new ExpensiveSymbol()));
        _checkBroken(address(new HugeSymbol()));
        _checkBroken(makeAddr("token without metadata code"));
    }

    function test_symbolDecoderOnlySelf() public {
        vm.expectRevert(KeelNotes.OnlySelf.selector);
        notes.readTokenSymbol(address(keel));
    }

    function testFuzz_symbolValidation(bytes memory raw) public {
        if (raw.length > 64) raw = abi.encodePacked(keccak256(raw));
        bool valid = raw.length > 0 && raw.length <= 16;
        for (uint256 i; i < raw.length; ++i) {
            uint8 c = uint8(raw[i]);
            if (!((c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57))) valid = false;
        }
        _checkSymbol(string(raw), valid ? string(raw) : "?");
    }

    function _checkSymbol(string memory raw, string memory expected) private {
        uint256 id = notes.totalMinted() + 1;
        _mintTo(address(uint160(0x30000 + id)));
        _gold(id, raw);
        (,,, string memory symbol,,) = notes.noteInfo(id);
        assertEq(symbol, expected);
    }

    function _checkBroken(address token) private {
        uint256 id = notes.totalMinted() + 1;
        address holder = address(uint160(0x40000 + id));
        _mintTo(holder);
        _register(token, holder);
        vm.prank(holder);
        notes.upgradeToGold(id, token);
        (,,, string memory symbol,,) = notes.noteInfo(id);
        assertEq(symbol, "?");
    }
}
