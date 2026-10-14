// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IKeelFactory, IKeelVault} from "../../src/interfaces/IKeel.sol";
import {KeelNotes} from "../../src/KeelNotes.sol";

/// @dev Test-only token. Used both as the existing IMD/Keel tokens and as project symbols.
contract MockToken is IERC20Metadata {
    string public name = "Mock token";
    string public symbol = "TEST";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public feeBps;
    uint256 public surcharge;
    bool public fail;
    bool public revertPayment;
    bool public noReturn;
    address public callbackTarget;
    bytes public callbackData;
    bool public callbackSuccess;
    bytes public callbackResult;
    bool public swallowCallback;

    function setSymbol(string memory value) external {
        symbol = value;
    }

    function setDecimals(uint8 value) external {
        decimals = value;
    }

    function setFee(uint256 bps) external {
        feeBps = bps;
    }

    function setSurcharge(uint256 value) external {
        surcharge = value;
    }

    function setFailure(bool falseReturn, bool reverts) external {
        fail = falseReturn;
        revertPayment = reverts;
    }

    function setNoReturn(bool value) external {
        noReturn = value;
    }

    function setCallback(address target, bytes memory data, bool swallow) external {
        callbackTarget = target;
        callbackData = data;
        swallowCallback = swallow;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function slash(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        return _move(from, to, amount);
    }

    function _move(address from, address to, uint256 amount) private returns (bool) {
        require(!revertPayment, "payment rejected");
        if (fail) return false;
        uint256 fee = amount * feeBps / 10_000;
        balanceOf[from] -= amount + surcharge;
        balanceOf[to] += amount - fee;
        totalSupply -= fee + surcharge;
        emit Transfer(from, to, amount - fee);
        if (callbackTarget != address(0)) {
            (callbackSuccess, callbackResult) = callbackTarget.call(callbackData);
            require(swallowCallback || callbackSuccess, "callback rejected");
        }
        if (noReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }
}

contract MockFactory is IKeelFactory {
    mapping(address => bool) public isLaunched;

    function setLaunched(address token, bool value) external {
        isLaunched[token] = value;
    }
}

contract MockVault is IKeelVault {
    mapping(address => Project) private _projects;

    function setCreator(address token, address creator) external {
        _projects[token] =
            Project(creator, 2, true, 1234, 123, 456, 1, 2, 3, 4, 5, 6, bytes32(uint256(7)), bytes32(uint256(8)));
    }

    function project(address token) external view returns (Project memory) {
        return _projects[token];
    }
}

/// @dev Answers project(address) with the 15-word layout the live Ethereum KeelVault returns:
/// the supplied 14-word struct followed by one extra uint256 word.
contract WideVault {
    mapping(address => address) public creators;

    function setCreator(address token, address creator) external {
        creators[token] = creator;
    }

    function project(address token) external view {
        bytes memory words = abi.encode(
            creators[token], uint8(0), true, uint16(8000), uint64(1_791_677_931), uint64(0), 0, 0, 0, 0, 0, 0, 0
        );
        bytes memory encoded = abi.encodePacked(words, bytes32(uint256(7)), bytes32(uint256(7)));
        assembly ("memory-safe") {
            return(add(encoded, 32), mload(encoded))
        }
    }
}

contract Mock1271 is IERC1271 {
    mapping(bytes32 => bytes32) private _signatures;
    bool public revoked;
    bool public shouldRevert;

    function permit(bytes32 digest, bytes memory signature) external {
        _signatures[digest] = keccak256(signature);
    }

    function setRevoked(bool value) external {
        revoked = value;
    }

    function setRevert(bool value) external {
        shouldRevert = value;
    }

    function isValidSignature(bytes32 digest, bytes memory signature) external view returns (bytes4) {
        require(!shouldRevert, "1271 unavailable");
        return !revoked && _signatures[digest] == keccak256(signature) ? IERC1271.isValidSignature.selector : bytes4(0);
    }
}

contract RevertingSymbol {
    function symbol() external pure returns (string memory) {
        revert("no metadata");
    }
}

contract MalformedSymbol {
    fallback() external {
        assembly ("memory-safe") {
            mstore(0, 42)
            return(0, 32)
        }
    }
}

contract ExpensiveSymbol {
    function symbol() external pure returns (string memory) {
        while (true) {}
        return "UNREACHABLE";
    }
}

contract HugeSymbol {
    function symbol() external pure returns (string memory) {
        return new string(200_000);
    }
}

/// @dev Deliberately has no ERC721Receiver hook.
contract ContractMinter {
    function mint(KeelNotes notes, uint256 minimum, uint256 deadline, bytes calldata signature) external {
        notes.mint(minimum, deadline, signature);
    }
}
