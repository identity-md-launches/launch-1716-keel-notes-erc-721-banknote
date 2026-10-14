# Vendored dependencies

- `OpenZeppelin/openzeppelin-contracts` `v5.2.0`: https://codeload.github.com/OpenZeppelin/openzeppelin-contracts/tar.gz/refs/tags/v5.2.0
  Archive SHA-256: `80f86d2dba4e1c0d66a216d2ddf0ac5d731edf9338ea12a985edca8774802814`. 32 transitive Solidity source files and the license vendored (unused package sources omitted).

- `foundry-rs/forge-std` `v1.9.6`: https://codeload.github.com/foundry-rs/forge-std/tar.gz/refs/tags/v1.9.6
  Archive SHA-256: `53d2b498183cb7dc62cf726cc6c1a222ad728b0d87976a877ca1f3ed3707b1c6`. 26 source/license files vendored.

Dependencies are ordinary source files; no submodules or network downloads are needed to build. OpenZeppelin production imports are limited to the transitive source closure used by this project. Forge Standard Library is test-only.

The exact retained files are checksummed in [vendor.sha256](vendor.sha256). Verify from the repository root with `sha256sum --check docs/vendor.sha256`.
