// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IKeelFactory, IKeelVault} from "./interfaces/IKeel.sol";
import {IKeelNoteArt} from "./interfaces/IKeelNoteArt.sol";

/// @notice Free banknote NFTs whose IMD rewards belong to the note until it is redeemed and burned.
contract KeelNotes is ERC721, Ownable2Step, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    address public constant KEEL_FACTORY = 0x39dFA7D3CE9364dB50433Fe9CC2F308C6a219F5F;
    address public constant KEEL_VAULT = 0xe2Fb1c0e5ea5342cD8607efA8e7c44F06b47013c;
    uint256 public constant MAX_SUPPLY = 1111;
    uint256 public constant MAX_GOLD = 111;
    uint256 public constant PRECISION = 1e36;
    uint256 public constant SYMBOL_GAS_LIMIT = 50_000;
    bytes32 public constant MINT_PASS_TYPEHASH = keccak256("MintPass(address to,uint256 minKeel,uint256 deadline)");

    enum Level {
        Standard,
        Gold
    }

    struct Note {
        Level level;
        uint64 mintedAt;
        address backedToken;
        string symbol;
        uint256 checkpoint;
        uint256 accrued;
        uint256 fraction;
    }

    address public keelToken;
    address public passSigner;
    IKeelNoteArt public art;
    bool public mintOpen;
    uint256 public totalMinted;
    uint256 public totalBurned;
    uint256 public goldCount;
    uint256 public totalWeight;
    uint256 public accPerWeight;

    /// @notice Conservative IMD reserve: credited receipts minus redemptions, including rounding dust.
    uint256 public liabilities;
    mapping(address wallet => bool) public hasMinted;
    mapping(address token => bool) public usedBackingToken;
    mapping(uint256 noteId => Note) private _notes;

    error ZeroAddress();
    error KeelTokenAlreadySet();
    error KeelTokenNotSet();
    error PassSignerNotSet();
    error MintClosed();
    error AlreadyMinted();
    error SupplyCap();
    error PassExpired();
    error ZeroMinimum();
    error InvalidPass();
    error InsufficientKeel();
    error NotNoteOwner();
    error AlreadyGold();
    error GoldCap();
    error NotLaunched();
    error NotProjectCreator();
    error BackingTokenUsed();
    error NoWeight();
    error ZeroReceived();
    error Insolvent();
    error NoRewards();
    error IncompletePayment();
    error IMDRescueForbidden();
    error OnlySelf();
    error InvalidKeelToken();
    error TransferToCollection();

    event NoteMinted(address indexed to, uint256 indexed noteId, uint64 mintedAt);
    event NoteUpgraded(uint256 indexed noteId, address indexed creator, address indexed backedToken, string symbol);
    event Funded(address indexed caller, uint256 amount, uint256 accPerWeight, bool surplus);
    event SurplusStranded(uint256 amount);
    event NoteRedeemed(address indexed owner, uint256 indexed noteId, uint256 amount);
    event KeelTokenSet(address indexed token);
    event PassSignerSet(address indexed previousSigner, address indexed newSigner);
    event MintOpenSet(bool open);
    event ArtSet(address indexed previousArt, address indexed newArt);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);

    constructor(address owner_, address art_) ERC721("Keel Notes", "KNOTE") Ownable(owner_) EIP712("KeelNotes", "1") {
        if (art_ == address(0)) revert ZeroAddress();
        art = IKeelNoteArt(art_);
        emit ArtSet(address(0), art_);
    }

    function setKeelToken(address token) external onlyOwner {
        if (keelToken != address(0)) revert KeelTokenAlreadySet();
        if (token == address(0)) revert ZeroAddress();
        // Permanent setting: refuse an address that cannot answer the balance query mint() depends on.
        if (token.code.length == 0) revert InvalidKeelToken();
        (bool ok, bytes memory answer) = token.staticcall(abi.encodeCall(IERC20.balanceOf, (address(this))));
        if (!ok || answer.length < 32) revert InvalidKeelToken();
        keelToken = token;
        emit KeelTokenSet(token);
    }

    function setPassSigner(address signer) external onlyOwner {
        if (signer == address(0)) revert ZeroAddress();
        address previous = passSigner;
        passSigner = signer;
        emit PassSignerSet(previous, signer);
    }

    function revokePassSigner() external onlyOwner {
        address previous = passSigner;
        passSigner = address(0);
        emit PassSignerSet(previous, address(0));
    }

    function setMintOpen(bool open) external onlyOwner {
        if (open) {
            if (keelToken == address(0)) revert KeelTokenNotSet();
            if (passSigner == address(0)) revert PassSignerNotSet();
        }
        mintOpen = open;
        emit MintOpenSet(open);
    }

    function setArt(address newArt) external onlyOwner {
        if (newArt == address(0)) revert ZeroAddress();
        address previous = address(art);
        art = IKeelNoteArt(newArt);
        emit ArtSet(previous, newArt);
    }

    function mint(uint256 minKeel, uint256 deadline, bytes calldata sig)
        external
        nonReentrant
        returns (uint256 noteId)
    {
        if (!mintOpen) revert MintClosed();
        if (keelToken == address(0)) revert KeelTokenNotSet();
        if (passSigner == address(0)) revert PassSignerNotSet();
        if (hasMinted[msg.sender]) revert AlreadyMinted();
        if (totalMinted == MAX_SUPPLY) revert SupplyCap();
        if (block.timestamp > deadline) revert PassExpired();
        if (minKeel == 0) revert ZeroMinimum();
        if (!SignatureChecker.isValidSignatureNow(passSigner, mintPassDigest(msg.sender, minKeel, deadline), sig)) {
            revert InvalidPass();
        }
        if (IERC20(keelToken).balanceOf(msg.sender) < minKeel) revert InsufficientKeel();

        _syncSurplus();
        hasMinted[msg.sender] = true;
        noteId = ++totalMinted;
        Note storage note = _notes[noteId];
        note.mintedAt = uint64(block.timestamp);
        note.checkpoint = accPerWeight;
        ++totalWeight;
        // Intentionally allows contracts without ERC721Receiver, as required by the mint policy.
        _mint(msg.sender, noteId);
        emit NoteMinted(msg.sender, noteId, note.mintedAt);
    }

    function mintPassDigest(address to, uint256 minKeel, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(MINT_PASS_TYPEHASH, to, minKeel, deadline)));
    }

    function upgradeToGold(uint256 noteId, address token) external nonReentrant {
        if (_requireOwned(noteId) != msg.sender) revert NotNoteOwner();
        Note storage note = _notes[noteId];
        if (note.level == Level.Gold) revert AlreadyGold();
        if (goldCount == MAX_GOLD) revert GoldCap();
        if (usedBackingToken[token]) revert BackingTokenUsed();
        if (!IKeelFactory(KEEL_FACTORY).isLaunched(token)) revert NotLaunched();
        if (IKeelVault(KEEL_VAULT).project(token).creator != msg.sender) revert NotProjectCreator();

        _syncSurplus();
        // Preserve Standard earnings, including sub-wei fractions, before increasing the weight.
        (note.accrued, note.fraction) = _earned(note);
        note.checkpoint = accPerWeight;
        note.level = Level.Gold;
        note.backedToken = token;
        note.symbol = _engraveSymbol(token);
        usedBackingToken[token] = true;
        ++goldCount;
        totalWeight += 4;
        emit NoteUpgraded(noteId, msg.sender, token, note.symbol);
    }

    /// @dev The outer try/catch also catches ABI decoding failures and caps malicious returndata/gas use.
    function _engraveSymbol(address token) private view returns (string memory) {
        try this.readTokenSymbol{gas: SYMBOL_GAS_LIMIT}(token) returns (string memory value) {
            return value;
        } catch {
            return "?";
        }
    }

    /// @dev Self-only decoding boundary; the token's symbol is read exactly once per successful upgrade.
    function readTokenSymbol(address token) external view returns (string memory) {
        if (msg.sender != address(this)) revert OnlySelf();
        string memory value = IERC20Metadata(token).symbol();
        bytes memory raw = bytes(value);
        if (raw.length == 0 || raw.length > 16) return "?";
        for (uint256 i; i < raw.length; ++i) {
            bytes1 c = raw[i];
            if (!((c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || (c >= "0" && c <= "9"))) return "?";
        }
        return value;
    }

    function fund(uint256 amount) external nonReentrant {
        if (totalWeight == 0) revert NoWeight();
        if (amount == 0) revert ZeroReceived();
        IERC20 imd = IERC20(IMD);
        uint256 beforeBalance = imd.balanceOf(address(this));
        if (beforeBalance < liabilities) revert Insolvent();
        imd.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = imd.balanceOf(address(this));
        if (afterBalance < beforeBalance) revert Insolvent();
        _credit(afterBalance - beforeBalance, false);
    }

    /// @notice Credits IMD sent directly to the live weights. A no-op when nothing is uncredited, because
    /// every mint, upgrade and redemption already credits what arrived before it.
    function creditSurplus() external nonReentrant {
        if (totalWeight == 0) revert NoWeight();
        if (IERC20(IMD).balanceOf(address(this)) < liabilities) revert Insolvent();
        _syncSurplus();
    }

    function _credit(uint256 received, bool surplus) private {
        if (received == 0) revert ZeroReceived();
        liabilities += received;
        accPerWeight += Math.mulDiv(received, PRECISION, totalWeight);
        emit Funded(msg.sender, received, accPerWeight, surplus);
    }

    /// @dev Credits directly transferred IMD to the weights that were live when it arrived, so a mint,
    /// upgrade or redemption that changes the weight set can neither take nor forfeit earlier IMD.
    /// IMD that arrives while no note is live belongs to no note: it is reserved permanently rather
    /// than handed to whichever wallet mints next. A balance below the reserve is left to the
    /// explicit funding paths and the redemption check, so an external shortfall never blocks redeem.
    function _syncSurplus() private {
        uint256 balance = IERC20(IMD).balanceOf(address(this));
        if (balance <= liabilities) return;
        uint256 surplus = balance - liabilities;
        if (totalWeight == 0) {
            liabilities = balance;
            emit SurplusStranded(surplus);
            return;
        }
        _credit(surplus, true);
    }

    function redeem(uint256 noteId) external nonReentrant {
        if (_requireOwned(noteId) != msg.sender) revert NotNoteOwner();
        _syncSurplus();
        Note storage note = _notes[noteId];
        (uint256 amount,) = _earned(note);
        if (amount == 0) revert NoRewards();
        IERC20 imd = IERC20(IMD);
        uint256 recipientBefore = imd.balanceOf(msg.sender);
        totalWeight -= _weight(note.level);
        ++totalBurned;
        liabilities -= amount;
        delete _notes[noteId];
        _burn(noteId);
        emit NoteRedeemed(msg.sender, noteId, amount);
        imd.safeTransfer(msg.sender, amount);
        uint256 recipientAfter = imd.balanceOf(msg.sender);
        if (recipientAfter < recipientBefore || recipientAfter - recipientBefore < amount) revert IncompletePayment();
        // Reject sender-side transfer surcharges that would spend another note's reserve.
        if (imd.balanceOf(address(this)) < liabilities) revert Insolvent();
    }

    function rescueToken(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == IMD) revert IMDRescueForbidden();
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit TokenRescued(token, to, amount);
    }

    function totalSupply() external view returns (uint256) {
        return totalMinted - totalBurned;
    }

    function pending(uint256 noteId) public view returns (uint256 amount) {
        _requireOwned(noteId);
        (amount,) = _earned(_notes[noteId]);
    }

    function noteInfo(uint256 noteId)
        external
        view
        returns (
            Level level,
            uint256 weight,
            address backedToken,
            string memory symbol_,
            uint256 pending_,
            uint64 mintedAt
        )
    {
        _requireOwned(noteId);
        Note storage note = _notes[noteId];
        (pending_,) = _earned(note);
        return (note.level, _weight(note.level), note.backedToken, note.symbol, pending_, note.mintedAt);
    }

    function tokenURI(uint256 noteId) public view override returns (string memory) {
        _requireOwned(noteId);
        Note storage note = _notes[noteId];
        (uint256 amount,) = _earned(note);
        return art.tokenURI(
            noteId,
            note.level == Level.Gold,
            note.backedToken,
            note.symbol,
            amount,
            IERC20Metadata(IMD).decimals(),
            note.mintedAt
        );
    }

    /// @dev The collection can never call its own redeem, so a note it held would be dead weight forever.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (to == address(this)) revert TransferToCollection();
        return super._update(to, tokenId, auth);
    }

    function _weight(Level level) private pure returns (uint256) {
        return level == Level.Gold ? 5 : 1;
    }

    function _earned(Note storage note) private view returns (uint256 amount, uint256 fraction) {
        uint256 delta = accPerWeight - note.checkpoint;
        uint256 weight = _weight(note.level);
        amount = note.accrued + Math.mulDiv(delta, weight, PRECISION);
        fraction = note.fraction + mulmod(delta, weight, PRECISION);
        amount += fraction / PRECISION;
        fraction %= PRECISION;
    }
}
