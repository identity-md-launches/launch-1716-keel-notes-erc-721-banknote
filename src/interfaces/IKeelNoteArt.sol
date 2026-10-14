// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IKeelNoteArt {
    function tokenURI(
        uint256 noteId,
        bool gold,
        address backedToken,
        string calldata symbol,
        uint256 pending,
        uint8 decimals,
        uint64 mintedAt
    ) external view returns (string memory);
}
