// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IKeelFactory {
    function isLaunched(address token) external view returns (bool);
}

interface IKeelVault {
    // The field order and types are the KeelVault ABI as supplied by the task. Only creator is used.
    // The live Ethereum vault (0xe2fb...013c) returns one extra uint256 word (15 words, 480 bytes)
    // after this 14-word layout. Solidity ignores trailing return data, so this shorter declaration
    // decodes both layouts. Do not lengthen it or add a returndatasize equality check: a vault
    // answering exactly 14 words would then make every Gold upgrade revert.
    struct Project {
        address creator;
        uint8 status;
        bool flag;
        uint16 rate;
        uint64 startedAt;
        uint64 endedAt;
        uint256 value0;
        uint256 value1;
        uint256 value2;
        uint256 value3;
        uint256 value4;
        uint256 value5;
        bytes32 data0;
        bytes32 data1;
    }

    function project(address token) external view returns (Project memory);
}
