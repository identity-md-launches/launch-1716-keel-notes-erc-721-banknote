// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {KeelNotesTestBase} from "./KeelNotesTestBase.sol";
import {KeelNotes} from "../src/KeelNotes.sol";
import {MockToken, MockFactory, MockVault, Mock1271} from "./mocks/Mocks.sol";

/// @dev The reference ledger distributes each credit to all living notes immediately.
/// It has no accumulator checkpoints or upgrade settlement, independently exercising those transitions.
contract RewardHandler is Test {
    uint256 public constant ACTORS = 16;
    uint256 private constant SCALE = 1e36;
    KeelNotes public immutable notes;
    MockToken public immutable imd;
    MockToken public immutable keel;
    MockFactory public immutable factory;
    MockVault public immutable vault;
    Mock1271 public immutable signer;
    uint256 public minted;
    uint256 public burned;
    uint256 public gold;
    uint256 public weight;
    uint256 public credited;
    uint256 public paid;
    uint256 public uncredited;
    uint256 public stranded;
    mapping(uint256 => uint256) public modelScaled;
    mapping(uint256 => uint256) public weights;
    mapping(uint256 => address) public holder;
    mapping(address => bool) public mintedWallet;

    constructor(KeelNotes notes_, MockToken keel_, Mock1271 signer_) {
        notes = notes_;
        imd = MockToken(notes_.IMD());
        keel = keel_;
        factory = MockFactory(notes_.KEEL_FACTORY());
        vault = MockVault(notes_.KEEL_VAULT());
        signer = signer_;
    }

    function actor(uint256 index) public pure returns (address) {
        return address(uint160(0x80000 + index % ACTORS));
    }

    function mint(uint256 actorSeed) external {
        address to = actor(actorSeed);
        if (mintedWallet[to]) return;
        keel.mint(to, 1);
        signer.permit(notes.mintPassDigest(to, 1, block.timestamp), hex"123456");
        _sync();
        vm.prank(to);
        uint256 id = notes.mint(1, block.timestamp, hex"123456");
        assertEq(id, ++minted);
        mintedWallet[to] = true;
        holder[id] = to;
        weights[id] = 1;
        ++weight;
    }

    function fund(uint96 raw) external {
        if (weight == 0) return;
        uint256 amount = bound(uint256(raw), 1, 1e24);
        imd.mint(address(this), amount);
        imd.approve(address(notes), amount);
        notes.fund(amount);
        _credit(amount);
    }

    function donate(uint96 raw) external {
        uint256 amount = bound(uint256(raw), 1, 1e24);
        imd.mint(address(this), amount);
        imd.transfer(address(notes), amount);
        uncredited += amount;
    }

    function credit() external {
        if (weight == 0) return;
        notes.creditSurplus();
        _sync();
    }

    function upgrade(uint256 seed) external {
        if (minted == 0) return;
        uint256 id = 1 + seed % minted;
        if (weights[id] != 1) return;
        address backing = address(uint160(0x90000 + id));
        factory.setLaunched(backing, true);
        vault.setCreator(backing, holder[id]);
        _sync();
        vm.prank(holder[id]);
        notes.upgradeToGold(id, backing);
        weights[id] = 5;
        weight += 4;
        ++gold;
    }

    function transfer(uint256 seed, uint256 actorSeed) external {
        if (minted == 0) return;
        uint256 id = 1 + seed % minted;
        if (weights[id] == 0) return;
        address from = holder[id];
        address to = actor(actorSeed);
        vm.prank(from);
        notes.transferFrom(from, to, id);
        holder[id] = to;
    }

    function redeem(uint256 seed) external {
        if (minted == 0) return;
        uint256 id = 1 + seed % minted;
        if (weights[id] == 0) return;
        // Redemption credits the uncredited IMD first; a zero claim after that reverts and syncs nothing.
        uint256 amount = (modelScaled[id] + weights[id] * (uncredited * SCALE / weight)) / SCALE;
        if (amount == 0) return;
        _sync();
        assertEq(modelScaled[id] / SCALE, amount, "predicted claim matches the synced ledger");
        address to = holder[id];
        uint256 beforeBalance = imd.balanceOf(to);
        vm.prank(to);
        notes.redeem(id);
        assertEq(imd.balanceOf(to) - beforeBalance, amount, "redemption matches the independent ledger");
        paid += amount;
        weight -= weights[id];
        weights[id] = 0;
        holder[id] = address(0);
        ++burned;
    }

    /// @dev Mirrors the collection: IMD that arrived is credited to the live weights before any weight
    /// change, and IMD that arrived while no note was live is reserved for nobody.
    function _sync() private {
        if (uncredited == 0) return;
        if (weight == 0) {
            stranded += uncredited;
        } else {
            _credit(uncredited);
        }
        uncredited = 0;
    }

    function _credit(uint256 amount) private {
        uint256 increment = amount * SCALE / weight;
        for (uint256 id = 1; id <= minted; ++id) {
            modelScaled[id] += weights[id] * increment;
        }
        credited += amount;
    }
}

contract RewardsInvariantTest is KeelNotesTestBase {
    RewardHandler private handler;

    function setUp() public override {
        super.setUp();
        Mock1271 signerContract = new Mock1271();
        vm.prank(owner);
        notes.setPassSigner(address(signerContract));
        handler = new RewardHandler(notes, keel, signerContract);
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.fund.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.credit.selector;
        selectors[4] = handler.upgrade.selector;
        selectors[5] = handler.transfer.selector;
        selectors[6] = handler.redeem.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_balanceCoversReserveAndEveryClaim() public view {
        uint256 allClaims;
        for (uint256 id = 1; id <= handler.minted(); ++id) {
            if (handler.weights(id) == 0) continue;
            uint256 claim = notes.pending(id);
            assertEq(claim, handler.modelScaled(id) / 1e36, "note matches immediate-distribution ledger");
            allClaims += claim;
        }
        assertGe(notes.liabilities(), allClaims);
        assertGe(imd.balanceOf(address(notes)), notes.liabilities());
        assertEq(notes.liabilities(), handler.credited() + handler.stranded() - handler.paid());
        assertEq(
            imd.balanceOf(address(notes)),
            handler.credited() + handler.stranded() + handler.uncredited() - handler.paid()
        );
    }

    function invariant_lifetimeLimitsWeightsAndOwners() public view {
        assertEq(notes.totalMinted(), handler.minted());
        assertEq(notes.totalBurned(), handler.burned());
        assertEq(notes.totalSupply(), handler.minted() - handler.burned());
        assertEq(notes.totalWeight(), handler.weight());
        assertEq(notes.goldCount(), handler.gold());
        assertLe(notes.totalMinted(), 1111);
        assertLe(notes.goldCount(), 111);
        for (uint256 id = 1; id <= handler.minted(); ++id) {
            if (handler.weights(id) == 0) continue;
            assertEq(notes.ownerOf(id), handler.holder(id));
            (, uint256 weight,,,,) = notes.noteInfo(id);
            assertEq(weight, handler.weights(id));
        }
        for (uint256 i; i < handler.ACTORS(); ++i) {
            address actor = handler.actor(i);
            assertEq(notes.hasMinted(actor), handler.mintedWallet(actor));
        }
    }
}
