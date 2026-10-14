// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {KeelNotesTestBase} from "./KeelNotesTestBase.sol";
import {KeelNotes} from "../src/KeelNotes.sol";
import {KeelNoteArt} from "../src/KeelNoteArt.sol";

contract ApplicationFactoryProbe {
    function deploy(address owner) external returns (KeelNoteArt art, KeelNotes notes) {
        art = new KeelNoteArt();
        notes = new KeelNotes(owner, address(art));
    }
}

contract ArtAndDeploymentTest is KeelNotesTestBase {
    function test_factoryDeploymentOnEmptyDependencyAddresses() public {
        vm.etch(notes.IMD(), "");
        vm.etch(notes.KEEL_FACTORY(), "");
        vm.etch(notes.KEEL_VAULT(), "");
        ApplicationFactoryProbe probe = new ApplicationFactoryProbe();
        (KeelNoteArt deployedArt, KeelNotes deployedNotes) = probe.deploy(owner);
        assertEq(deployedNotes.owner(), owner);
        assertEq(address(deployedNotes.art()), address(deployedArt));
        assertFalse(deployedNotes.mintOpen());
        _checkRuntime(address(deployedArt));
        _checkRuntime(address(deployedNotes));
    }

    function test_runtimeSizesAndForbiddenOpcodes() public view {
        _checkRuntime(address(notes));
        _checkRuntime(address(art));
    }

    function test_tokenURIContainsValidJSONEmbeddedSVGAndLiveRewards() public {
        _mintTo(alice);
        _fund(12.345 ether);
        string memory json = _decodeURI(notes.tokenURI(1), "data:application/json;base64,");
        assertEq(vm.parseJsonString(json, ".name"), "Keel Note #0001");
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "Standard");
        assertEq(vm.parseJsonUint(json, ".attributes[1].value"), 1);
        assertEq(vm.parseJsonString(json, ".attributes[3].value"), "12345000000000000000");
        string memory svg = _decodeURI(vm.parseJsonString(json, ".image"), "data:image/svg+xml;base64,");
        assertTrue(_contains(svg, "HOLDS 12.34 IMD"));
        assertTrue(_contains(svg, "No. 0001 / 1111"));
        assertTrue(_contains(svg, "STANDARD"));
        assertTrue(_contains(svg, "KEEL NOTE"));
        assertTrue(_contains(svg, "ASSEMBLED BY THE SWARM"));
        assertTrue(_contains(svg, "monospace"));
        assertFalse(_contains(svg, "BACKS $"));
        assertFalse(_contains(svg, "<script"));
        assertFalse(_contains(svg, "href=\"http"));
        string memory beforeURI = notes.tokenURI(1);
        _fund(1 ether);
        assertNotEq(notes.tokenURI(1), beforeURI);
    }

    function test_goldTokenURIEngravingAndMetadata() public {
        _mintTo(alice);
        address token = _gold(1, "FOREST");
        string memory json = _decodeURI(notes.tokenURI(1), "data:application/json;base64,");
        assertEq(vm.parseJsonString(json, ".attributes[0].value"), "Gold");
        assertEq(vm.parseJsonUint(json, ".attributes[1].value"), 5);
        assertEq(vm.parseJsonAddress(json, ".attributes[2].value"), token);
        string memory svg = _decodeURI(vm.parseJsonString(json, ".image"), "data:image/svg+xml;base64,");
        assertTrue(_contains(svg, "BACKS $FOREST"));
        assertTrue(_contains(svg, "#fff0be"));
        assertTrue(_contains(svg, "GOLD"));
    }

    function test_svgSerialDeterminismAndUniqueGuilloche() public view {
        string memory first = art.svg(421, false, address(0), "", 12.34 ether, 18);
        assertTrue(_contains(first, "No. 0421 / 1111"));
        assertEq(first, art.svg(421, false, address(0), "", 12.34 ether, 18));
        string memory next = art.svg(422, false, address(0), "", 12.34 ether, 18);
        assertNotEq(first, next);
        // The seed changes geometric coordinates, independently of the serial-number text.
        assertNotEq(_geometry(first), _geometry(next));
        assertTrue(_contains(art.svg(1111, false, address(0), "", 0, 18), "No. 1111 / 1111"));
    }

    function test_artEscapesAllXMLMetacharacters() public view {
        string memory svg = art.svg(1, true, alice, "<&>\"'", 0, 18);
        assertTrue(_contains(svg, "BACKS $&lt;&amp;&gt;&quot;&apos;"));
        assertFalse(_contains(svg, "BACKS $<&>"));
    }

    function test_artHonorsTokenDecimalsAndTruncatesDisplayOnly() public {
        _mintTo(alice);
        imd.setDecimals(6);
        _fund(12_345_678);
        string memory json = _decodeURI(notes.tokenURI(1), "data:application/json;base64,");
        string memory svg = _decodeURI(vm.parseJsonString(json, ".image"), "data:image/svg+xml;base64,");
        assertTrue(_contains(svg, "HOLDS 12.34 IMD"));
        assertEq(notes.pending(1), 12_345_678);
        assertTrue(_contains(art.svg(1, false, address(0), "", 123, 1), "HOLDS 12.30 IMD"));
        assertTrue(_contains(art.svg(1, false, address(0), "", 12, 0), "HOLDS 12.00 IMD"));
        assertTrue(_contains(art.svg(1, false, address(0), "", 1, 18), "HOLDS 0.00 IMD"));
        assertTrue(_contains(art.svg(1, false, address(0), "", type(uint256).max, 255), "HOLDS 0.00 IMD"));
    }

    function test_ownerCanReplaceRendererWithoutAffectingClaims() public {
        _mintTo(alice);
        _fund(7 ether);
        KeelNoteArt replacement = new KeelNoteArt();
        string memory beforeURI = notes.tokenURI(1);
        vm.prank(owner);
        notes.setArt(address(replacement));
        assertEq(notes.tokenURI(1), beforeURI);
        assertEq(notes.pending(1), 7 ether);
    }

    function _checkRuntime(address application) private view {
        bytes memory code = application.code;
        assertGt(code.length, 0);
        assertLt(code.length, 24_000);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }

    function _decodeURI(string memory uri, string memory prefix) private pure returns (string memory) {
        bytes memory input = bytes(uri);
        bytes memory expected = bytes(prefix);
        require(input.length >= expected.length, "short URI");
        for (uint256 i; i < expected.length; ++i) {
            require(input[i] == expected[i], "wrong URI prefix");
        }
        uint256 start = expected.length;
        uint256 n = input.length - start;
        require(n % 4 == 0 && n > 0, "bad base64 length");
        uint256 outputLength = n / 4 * 3;
        if (input[input.length - 1] == "=") --outputLength;
        if (input[input.length - 2] == "=") --outputLength;
        bytes memory output = new bytes(outputLength);
        uint256 out;
        for (uint256 i = start; i < input.length; i += 4) {
            uint256 word = (_sextet(input[i]) << 18) | (_sextet(input[i + 1]) << 12) | (_sextet(input[i + 2]) << 6)
                | _sextet(input[i + 3]);
            if (out < outputLength) output[out++] = bytes1(uint8(word >> 16));
            if (out < outputLength) output[out++] = bytes1(uint8(word >> 8));
            if (out < outputLength) output[out++] = bytes1(uint8(word));
        }
        return string(output);
    }

    function _sextet(bytes1 c) private pure returns (uint256) {
        uint8 b = uint8(c);
        if (b >= 65 && b <= 90) return b - 65;
        if (b >= 97 && b <= 122) return b - 71;
        if (b >= 48 && b <= 57) return b + 4;
        if (b == 43) return 62;
        if (b == 47) return 63;
        require(b == 61, "bad base64 character");
        return 0;
    }

    function _contains(string memory haystack, string memory needle) private pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i <= h.length - n.length; ++i) {
            bool match_ = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    match_ = false;
                    break;
                }
            }
            if (match_) return true;
        }
        return false;
    }

    function _geometry(string memory svg) private pure returns (bytes32) {
        bytes memory raw = bytes(svg);
        // Hash the first ellipse element (both radii are seed-derived).
        for (uint256 i; i + 8 < raw.length; ++i) {
            if (raw[i] == "<" && raw[i + 1] == "e" && raw[i + 2] == "l") {
                uint256 end = i;
                while (raw[end] != ">") ++end;
                bytes memory element = new bytes(end - i);
                for (uint256 j; j < element.length; ++j) {
                    element[j] = raw[i + j];
                }
                return keccak256(element);
            }
        }
        revert("missing ellipse");
    }
}
