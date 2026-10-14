// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IKeelNoteArt} from "./interfaces/IKeelNoteArt.sol";

/// @notice Stateless, entirely on-chain banknote artwork. No external fonts, images, or URLs.
contract KeelNoteArt is IKeelNoteArt {
    using Strings for uint256;

    function tokenURI(
        uint256 noteId,
        bool gold,
        address backedToken,
        string calldata symbol,
        uint256 pending,
        uint8 decimals,
        uint64 mintedAt
    ) external pure returns (string memory) {
        string memory image = string.concat(
            "data:image/svg+xml;base64,",
            Base64.encode(bytes(svg(noteId, gold, backedToken, symbol, pending, decimals)))
        );
        // User-controlled text is only included in the XML-escaped, base64-encoded image.
        // JSON attributes contain fixed strings, numeric values, or hex addresses.
        bytes memory json = bytes(
            string.concat(
                '{"name":"Keel Note #',
                _serial(noteId),
                '","description":"An engraved Keel banknote. IMD rewards stay with the note; redeeming burns it.",',
                '"image":"',
                image,
                '","attributes":[{"trait_type":"Level","value":"',
                gold ? "Gold" : "Standard",
                '"},{"trait_type":"Weight","value":',
                gold ? "5" : "1",
                '},{"trait_type":"Backed token","value":"',
                Strings.toHexString(backedToken),
                '"},{"trait_type":"Pending IMD (base units)","value":"',
                pending.toString(),
                '"},{"display_type":"date","trait_type":"Minted at","value":',
                uint256(mintedAt).toString(),
                "}]}"
            )
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    function svg(uint256 noteId, bool gold, address backedToken, string memory symbol, uint256 pending, uint8 decimals)
        public
        pure
        returns (string memory)
    {
        bytes32 seed = keccak256(abi.encode(noteId));
        return string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1200 680" role="img" aria-labelledby="title desc">',
            '<title id="title">KEEL NOTE ',
            _serial(noteId),
            '</title><desc id="desc">A dark engraved banknote with a chrome forest, silver leaves and a metallic K.</desc>',
            _defs(gold),
            '<rect width="1200" height="680" rx="28" fill="#080e11"/>',
            '<rect x="18" y="18" width="1164" height="644" rx="18" fill="url(#hatch)" stroke="url(#metal)" stroke-width="2"/>',
            '<rect x="32" y="32" width="1136" height="616" rx="10" fill="none" stroke="#667879"/>',
            '<rect x="42" y="42" width="1116" height="596" rx="6" fill="none" stroke="#3b4f51" stroke-dasharray="2 4"/>',
            _guilloche(seed),
            _forest(seed),
            '<circle cx="600" cy="322" r="172" fill="#0b1418" fill-opacity=".94" stroke="url(#metal)" stroke-width="3"/>',
            '<circle cx="600" cy="322" r="163" fill="url(#hatch)" stroke="#687b80"/>',
            '<circle cx="600" cy="322" r="151" fill="none" stroke="url(#metal)" stroke-dasharray="1 5" stroke-width="3"/>',
            '<path d="M524 221h44v88l80-88h57l-97 104 101 111h-60l-81-94v94h-44z" ',
            'fill="url(#metal)" stroke="#edf8f4" stroke-width="1.5"/>',
            '<path d="M531 228h30v91m15 8 76-93m-76 105 76 86" fill="none" stroke="#fff" stroke-opacity=".55"/>',
            _lettering(noteId, gold, backedToken, symbol, pending, decimals),
            "</svg>"
        );
    }

    function _defs(bool gold) private pure returns (string memory) {
        return string.concat(
            '<defs><linearGradient id="metal" x1="0" y1="0" x2=".8" y2="1">',
            gold
                ? '<stop stop-color="#fff0be"/><stop offset=".24" stop-color="#a57430"/><stop offset=".48" stop-color="#ffe5a0"/><stop offset=".52" stop-color="#795322"/><stop offset=".76" stop-color="#e7c875"/><stop offset="1" stop-color="#fff1b6"/>'
                : '<stop stop-color="#eef9ff"/><stop offset=".24" stop-color="#71868f"/><stop offset=".48" stop-color="#f1fbff"/><stop offset=".52" stop-color="#455b64"/><stop offset=".76" stop-color="#a8bdc7"/><stop offset="1" stop-color="#f4ffff"/>',
            '</linearGradient><linearGradient id="chrome"><stop stop-color="#243e40"/><stop offset=".45" stop-color="#d1e5e1"/>',
            '<stop offset=".53" stop-color="#50696b"/><stop offset="1" stop-color="#a9c5c0"/></linearGradient>',
            '<linearGradient id="leaf"><stop stop-color="#587a76"/><stop offset=".5" stop-color="#e7f4ed"/>',
            '<stop offset="1" stop-color="#879e98"/></linearGradient>',
            '<pattern id="hatch" width="6" height="6" patternUnits="userSpaceOnUse">',
            '<path d="M0 6 6 0" stroke="#a7c8bf" stroke-opacity=".07" stroke-width=".6"/></pattern>',
            '<path id="silverleaf" d="M0 0Q-31-33-5-53Q18-26 0 0Z" fill="url(#leaf)" stroke="#d3e5dc" stroke-width=".6"/>',
            '<g id="tree"><path d="M-6 0-3-220 3-220 7 0Z" fill="url(#chrome)"/>',
            '<path d="M0-50-40-100M0-82 43-129M0-121-33-164M0-153 31-194M0-185-21-217" ',
            'fill="none" stroke="url(#chrome)" stroke-width="4"/>',
            '<use href="#silverleaf" transform="translate(-40 -100) rotate(-43)"/>',
            '<use href="#silverleaf" transform="translate(43 -129) rotate(50)"/>',
            '<use href="#silverleaf" transform="translate(-33 -164) rotate(-45)"/>',
            '<use href="#silverleaf" transform="translate(31 -194) rotate(40)"/>',
            '<use href="#silverleaf" transform="translate(-21 -217) rotate(-32)"/>',
            '<use href="#silverleaf" transform="translate(0 -220)"/></g></defs>'
        );
    }

    function _guilloche(bytes32 seed) private pure returns (string memory result) {
        result = '<g fill="none" stroke="url(#metal)" stroke-width=".65" opacity=".34">';
        for (uint256 i; i < 18; ++i) {
            uint256 rx = 190 + uint8(seed[i]) % 50;
            uint256 ry = 115 + uint8(seed[31 - i]) % 55;
            string memory ellipse = string.concat(
                '<ellipse rx="',
                rx.toString(),
                '" ry="',
                ry.toString(),
                '" transform="rotate(',
                (i * 10).toString(),
                ')"/>'
            );
            result = string.concat(
                result,
                '<g transform="translate(260 321)">',
                ellipse,
                '</g><g transform="translate(940 321)">',
                ellipse,
                "</g>"
            );
        }
        result = string.concat(result, "</g>");
    }

    function _forest(bytes32 seed) private pure returns (string memory result) {
        result = '<g opacity=".84">';
        for (uint256 i; i < 10; ++i) {
            uint256 x = i < 5 ? 108 + i * 65 : 832 + (i - 5) * 65;
            uint256 scale = 6 + uint8(seed[i]) % 4;
            result = string.concat(
                result,
                '<use href="#tree" transform="translate(',
                x.toString(),
                " ",
                (uint256(460) + uint8(seed[20 + i]) % 25).toString(),
                ") scale(0.",
                scale.toString(),
                ')"/>'
            );
        }
        result = string.concat(
            result,
            '</g><path d="M90 489Q320 463 450 489T760 489 1110 489" fill="none" stroke="#829e95" stroke-opacity=".5"/>'
        );
    }

    function _lettering(
        uint256 noteId,
        bool gold,
        address backedToken,
        string memory symbol,
        uint256 pending,
        uint8 decimals
    ) private pure returns (string memory) {
        string memory backing = gold
            ? string.concat(
                '<text x="600" y="505" font-size="19" letter-spacing="3" fill="url(#metal)">BACKS $',
                _xmlEscape(symbol),
                '</text><text x="600" y="530" font-size="11" letter-spacing="1" fill="#91a7a4">',
                Strings.toHexString(backedToken),
                "</text>"
            )
            : '<text x="600" y="515" font-size="12" letter-spacing="4" fill="#91a7a4">KEEL / SERIES 01</text>';
        return string.concat(
            '<g font-family="monospace" fill="#ccdcdb"><text x="78" y="99" font-size="34" letter-spacing="8" fill="url(#metal)">KEEL NOTE</text>',
            '<text x="1122" y="96" text-anchor="end" font-size="20" letter-spacing="2">No. ',
            _serial(noteId),
            ' / 1111</text><path d="M78 118H1122M78 553H1122" stroke="url(#metal)" stroke-width=".8"/>',
            '<g text-anchor="middle"><text x="600" y="144" font-size="11" letter-spacing="4" fill="#8ea4a0">ASSEMBLED BY THE SWARM</text>',
            '<text x="600" y="194" font-size="16" letter-spacing="5" fill="url(#metal)">',
            gold ? "GOLD" : "STANDARD",
            "</text>",
            backing,
            '<text x="600" y="598" font-size="30" letter-spacing="3" fill="url(#metal)">HOLDS ',
            _formatIMD(pending, decimals),
            ' IMD</text><text x="600" y="627" font-size="9" letter-spacing="3" fill="#839b96">',
            "ASSEMBLED BY THE SWARM / KEEL NOTES / ASSEMBLED BY THE SWARM</text></g>",
            '<text x="80" y="590" font-size="11" letter-spacing="2">WEIGHT ',
            gold ? "05" : "01",
            '</text><text x="1120" y="590" text-anchor="end" font-size="11" letter-spacing="2">ETHEREUM</text></g>'
        );
    }

    function _serial(uint256 id) private pure returns (string memory) {
        string memory value = id.toString();
        if (id < 10) return string.concat("000", value);
        if (id < 100) return string.concat("00", value);
        if (id < 1000) return string.concat("0", value);
        return value;
    }

    /// @dev Display truncates to two decimals; accounting always uses full IMD base-unit precision.
    function _formatIMD(uint256 amount, uint8 decimals) private pure returns (string memory) {
        uint256 whole = decimals > 77 ? 0 : amount / (10 ** uint256(decimals));
        uint256 cents = 0;
        if (decimals == 1) cents = (amount % 10) * 10;
        else if (decimals >= 2 && decimals <= 79) cents = (amount / (10 ** (uint256(decimals) - 2))) % 100;
        return string.concat(whole.toString(), cents < 10 ? ".0" : ".", cents.toString());
    }

    function _xmlEscape(string memory value) private pure returns (string memory result) {
        bytes memory raw = bytes(value);
        for (uint256 i; i < raw.length; ++i) {
            bytes1 c = raw[i];
            if (c == "&") result = string.concat(result, "&amp;");
            else if (c == "<") result = string.concat(result, "&lt;");
            else if (c == ">") result = string.concat(result, "&gt;");
            else if (c == '"') result = string.concat(result, "&quot;");
            else if (c == "'") result = string.concat(result, "&apos;");
            else if (uint8(c) < 32 || uint8(c) > 126) result = string.concat(result, "?");
            else result = string.concat(result, string(abi.encodePacked(c)));
        }
    }
}
