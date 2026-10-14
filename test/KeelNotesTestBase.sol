// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeelNotes} from "../src/KeelNotes.sol";
import {KeelNoteArt} from "../src/KeelNoteArt.sol";
import {MockToken, MockFactory, MockVault} from "./mocks/Mocks.sol";

abstract contract KeelNotesTestBase is Test {
    KeelNotes internal notes;
    KeelNoteArt internal art;
    MockToken internal imd;
    MockToken internal keel;
    MockFactory internal factory;
    MockVault internal vault;
    address internal owner;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal signer;
    uint256 internal constant SIGNER_KEY = 0x123456;
    uint256 internal constant MINIMUM = 10 ether;

    function setUp() public virtual {
        owner = makeAddr("launch owner");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        signer = vm.addr(SIGNER_KEY);
        art = new KeelNoteArt();
        notes = new KeelNotes(owner, address(art));
        MockToken template = new MockToken();
        vm.etch(notes.IMD(), address(template).code);
        imd = MockToken(notes.IMD());
        imd.setDecimals(18);
        MockFactory factoryTemplate = new MockFactory();
        vm.etch(notes.KEEL_FACTORY(), address(factoryTemplate).code);
        factory = MockFactory(notes.KEEL_FACTORY());
        MockVault vaultTemplate = new MockVault();
        vm.etch(notes.KEEL_VAULT(), address(vaultTemplate).code);
        vault = MockVault(notes.KEEL_VAULT());
        keel = new MockToken();
        vm.startPrank(owner);
        notes.setKeelToken(address(keel));
        notes.setPassSigner(signer);
        notes.setMintOpen(true);
        vm.stopPrank();
    }

    function _signature(KeelNotes target, address to, uint256 minimum, uint256 deadline, uint256 key)
        internal
        view
        returns (bytes memory)
    {
        // Build the typed-data digest independently of the contract helper.
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("KeelNotes"),
                keccak256("1"),
                block.chainid,
                address(target)
            )
        );
        bytes32 payload = keccak256(
            abi.encode(keccak256("MintPass(address to,uint256 minKeel,uint256 deadline)"), to, minimum, deadline)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, payload)));
        return abi.encodePacked(r, s, v);
    }

    function _mintTo(address to) internal returns (uint256 id) {
        keel.mint(to, MINIMUM);
        uint256 deadline = block.timestamp + 1 days;
        bytes memory sig = _signature(notes, to, MINIMUM, deadline, SIGNER_KEY);
        vm.prank(to);
        id = notes.mint(MINIMUM, deadline, sig);
    }

    function _project(address creator, string memory symbol) internal returns (address token) {
        MockToken projectToken = new MockToken();
        projectToken.setSymbol(symbol);
        token = address(projectToken);
        _register(token, creator);
    }

    function _register(address token, address creator) internal {
        factory.setLaunched(token, true);
        vault.setCreator(token, creator);
    }

    function _gold(uint256 id, string memory symbol) internal returns (address token) {
        address holder = notes.ownerOf(id);
        token = _project(holder, symbol);
        vm.prank(holder);
        notes.upgradeToGold(id, token);
    }

    function _fund(uint256 amount) internal {
        imd.mint(address(this), amount);
        imd.approve(address(notes), amount);
        notes.fund(amount);
    }

    function _assertSolvent() internal view {
        uint256 owed;
        for (uint256 id = 1; id <= notes.totalMinted(); ++id) {
            try notes.ownerOf(id) returns (address) {
                owed += notes.pending(id);
            } catch {}
        }
        assertGe(notes.liabilities(), owed, "reserve covers all note claims");
        assertGe(imd.balanceOf(address(notes)), notes.liabilities(), "IMD covers reserve");
    }
}
