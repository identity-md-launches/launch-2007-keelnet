// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Keelnet (KEEL)
/// @notice A fixed-supply ERC-20. The whole supply is minted once, in the constructor, to the
///         deployer (`msg.sender`). There is no owner, no mint function, no pause, no blocklist,
///         no fee and no burn hook: after deployment nobody can grow the supply or move or freeze
///         a holder's balance. Transfers follow the plain ERC-20 rules of OpenZeppelin v5.
/// @dev The contract name is the launch's Solidity identifier (at most 32 characters). The
///      token's human-readable name and symbol are returned by `name()` and `symbol()`.
contract KeelnetToken is ERC20 {
    /// @notice Token name as returned by `name()`.
    string public constant TOKEN_NAME = "Keelnet";

    /// @notice Token symbol as returned by `symbol()`.
    string public constant TOKEN_SYMBOL = "KEEL";

    /// @notice Number of decimals, the ERC-20 default.
    uint8 public constant DECIMALS = 18;

    /// @notice Whole-token supply before scaling by decimals: one billion.
    uint256 public constant SUPPLY_WHOLE_TOKENS = 1_000_000_000;

    /// @notice Total supply in minor units: 1,000,000,000 * 10^18.
    uint256 public constant TOTAL_SUPPLY = SUPPLY_WHOLE_TOKENS * 10 ** uint256(DECIMALS);

    /// @notice Mints the entire supply to the deployer. Takes no arguments and calls no other
    ///         contract, so it deploys on an empty chain and through the launch factory unchanged.
    constructor() ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
