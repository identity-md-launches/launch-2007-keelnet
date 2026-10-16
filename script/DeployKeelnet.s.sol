// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {KeelnetToken} from "../src/KeelnetToken.sol";

/// @title Deploy script for Keelnet (KEEL)
/// @notice Reviewable reference deployment. The IdentityMD launch does not run this script: its
///         factory deploys the token from the built bytecode and receives the supply as
///         `msg.sender`. This script exists so a reviewer can reproduce a deployment locally.
/// @dev `deploy()` takes no configuration because the token has none: name, symbol and supply
///      are constants of the contract. Tests call `deploy()` directly; only `run()` broadcasts.
contract DeployKeelnet is Script {
    /// @notice Deploys a fresh token. The caller of this function's broadcast context receives
    ///         the supply.
    function deploy() public returns (KeelnetToken token) {
        token = new KeelnetToken();
    }

    /// @notice Broadcast entry point for `forge script`. Uses whichever signer forge was given on
    ///         the command line; it reads no environment variables itself.
    function run() external returns (KeelnetToken token) {
        vm.startBroadcast();
        token = deploy();
        vm.stopBroadcast();
    }
}
