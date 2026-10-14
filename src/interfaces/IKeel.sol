// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IKeelFactory {
    function isLaunched(address token) external view returns (bool);
}

interface IKeelVault {
    // The field order and types are the fixed KeelVault ABI. Only creator is used.
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
