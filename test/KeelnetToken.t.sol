// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {KeelnetToken} from "../src/KeelnetToken.sol";
import {DeployKeelnet} from "../script/DeployKeelnet.s.sol";

/// @notice Behavioural tests for Keelnet (KEEL): metadata, the one-time mint, ERC-20 success and
///         failure paths, and the absence of any privileged power over supply or balances.
contract KeelnetTokenTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    /// @dev Stands in for the launch factory: the address that deploys and therefore holds the supply.
    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");

    KeelnetToken internal token;

    function setUp() public {
        vm.prank(deployer);
        token = new KeelnetToken();
    }

    // ---------------------------------------------------------------- metadata and supply

    function test_metadata() public view {
        assertEq(token.name(), "Keelnet");
        assertEq(token.symbol(), "KEEL");
        assertEq(token.decimals(), 18);
        assertEq(token.TOKEN_NAME(), "Keelnet");
        assertEq(token.TOKEN_SYMBOL(), "KEEL");
        assertEq(token.DECIMALS(), 18);
    }

    function test_supplyConstantsMatchTheBrief() public view {
        assertEq(token.SUPPLY_WHOLE_TOKENS(), 1_000_000_000);
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY);
        assertEq(token.TOTAL_SUPPLY(), 1_000_000_000_000_000_000_000_000_000);
    }

    function test_constructorMintsWholeSupplyToDeployer() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function test_constructorEmitsSingleMintTransfer() public {
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(address(0), deployer, EXPECTED_SUPPLY);
        vm.prank(deployer);
        new KeelnetToken();
    }

    function test_supplyGoesToWhoeverDeploys() public {
        address other = makeAddr("otherDeployer");
        vm.prank(other);
        KeelnetToken fresh = new KeelnetToken();
        assertEq(fresh.balanceOf(other), EXPECTED_SUPPLY);
        assertEq(fresh.balanceOf(deployer), 0);
        assertEq(fresh.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_deployScriptMintsToItsCaller() public {
        DeployKeelnet deployScript = new DeployKeelnet();
        KeelnetToken deployed = deployScript.deploy();
        // Without a broadcast, `new` inside the script runs as the script contract.
        assertEq(deployed.balanceOf(address(deployScript)), EXPECTED_SUPPLY);
        assertEq(deployed.totalSupply(), EXPECTED_SUPPLY);
        assertEq(deployed.name(), "Keelnet");
        assertEq(deployed.symbol(), "KEEL");
    }

    // ---------------------------------------------------------------- transfer: success

    function test_transferMovesExactAmount() public {
        uint256 amount = 1_234e18;
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Transfer(deployer, alice, amount);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function test_transferWholeBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(alice, EXPECTED_SUPPLY));
        assertEq(token.balanceOf(alice), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
    }

    function test_transferZeroAmountSucceeds() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, 5e18));
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_holderCanForwardWhatItReceived() public {
        vm.prank(deployer);
        token.transfer(alice, 100e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 100e18));
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(bob), 100e18);
    }

    // ---------------------------------------------------------------- transfer: failure

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
    }

    function test_transferRevertsWhenAmountExceedsBalanceByOne() public {
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, deployer, EXPECTED_SUPPLY, EXPECTED_SUPPLY + 1
            )
        );
        token.transfer(alice, EXPECTED_SUPPLY + 1);
    }

    function test_transferToZeroAddressReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1e18);
    }

    // ---------------------------------------------------------------- approve / transferFrom

    function test_approveSetsAllowanceAndEmits() public {
        vm.prank(deployer);
        vm.expectEmit(true, true, true, true);
        emit IERC20.Approval(deployer, spender, 50e18);
        assertTrue(token.approve(spender, 50e18));
        assertEq(token.allowance(deployer, spender), 50e18);
    }

    function test_approveOverwritesPreviousAllowance() public {
        vm.startPrank(deployer);
        token.approve(spender, 50e18);
        token.approve(spender, 7e18);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 7e18);
    }

    function test_approveZeroAddressSpenderReverts() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 1);
    }

    function test_transferFromWithinAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 50e18);

        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, 20e18));

        assertEq(token.balanceOf(bob), 20e18);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - 20e18);
        assertEq(token.allowance(deployer, spender), 30e18);
    }

    function test_transferFromExactAllowanceLeavesZero() public {
        vm.prank(deployer);
        token.approve(spender, 20e18);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 20e18);
        assertEq(token.allowance(deployer, spender), 0);
    }

    function test_transferFromInfiniteAllowanceIsNotDecremented() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 20e18);
        assertEq(token.allowance(deployer, spender), type(uint256).max);
    }

    function test_transferFromRevertsWithoutAllowance() public {
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1e18));
        token.transferFrom(deployer, bob, 1e18);
    }

    function test_transferFromRevertsAboveAllowance() public {
        vm.prank(deployer);
        token.approve(spender, 10e18);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 10e18, 11e18));
        token.transferFrom(deployer, bob, 11e18);
    }

    function test_transferFromRevertsWhenOwnerBalanceTooLow() public {
        vm.prank(alice);
        token.approve(spender, 10e18);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 10e18));
        token.transferFrom(alice, bob, 10e18);
    }

    function test_transferFromToZeroAddressReverts() public {
        vm.prank(deployer);
        token.approve(spender, 10e18);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(deployer, address(0), 1e18);
    }

    /// @dev The deployer holds no special power: without an allowance it cannot pull from a holder.
    function test_deployerCannotPullFromHolderWithoutAllowance() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(alice, deployer, 1);
        assertEq(token.balanceOf(alice), 10e18);
    }

    // ---------------------------------------------------------------- no privileged surface

    /// @dev None of the usual admin entry points exist. Each call must revert (no fallback, no
    ///      matching selector) and leave supply and balances untouched, whether from a stranger
    ///      or from the deployer.
    function test_noAdminSelectorChangesSupplyOrBalances() public {
        address attacker = makeAddr("attacker");
        string[16] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "mint()",
            "issue(uint256)",
            "burnFrom(address,uint256)",
            "pause()",
            "unpause()",
            "setOwner(address)",
            "transferOwnership(address)",
            "owner()",
            "blacklist(address)",
            "freeze(address)",
            "setBlacklist(address,bool)",
            "setTransfersEnabled(bool)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            bytes memory data = abi.encodeWithSignature(signatures[i], attacker, type(uint128).max);
            vm.prank(attacker);
            (bool okAttacker,) = address(token).call(data);
            assertFalse(okAttacker, signatures[i]);
            vm.prank(deployer);
            (bool okDeployer,) = address(token).call(data);
            assertFalse(okDeployer, signatures[i]);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(attacker), 0);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function test_noReceiveOrFallback() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1 ether}("");
        assertFalse(ok, "token accepted ether");
        vm.prank(alice);
        (ok,) = address(token).call(hex"deadbeef");
        assertFalse(ok, "token answered an unknown selector");
        assertEq(address(token).balance, 0);
    }

    function test_runtimeHasNoDelegatecallCallcodeOrSelfdestruct() public view {
        bytes memory runtime = address(token).code;
        assertGt(runtime.length, 0);
        assertLe(runtime.length, 24_576, "runtime exceeds EIP-170");
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7F) {
                i += (op - 0x5F);
                continue;
            }
            assertTrue(op != 0xF4, "DELEGATECALL");
            assertTrue(op != 0xF2, "CALLCODE");
            assertTrue(op != 0xFF, "SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        assertTrue(token.transfer(to, amount));
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }

    function testFuzz_transferAboveBalanceReverts(uint256 amount) public {
        amount = bound(amount, EXPECTED_SUPPLY + 1, type(uint256).max);
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, EXPECTED_SUPPLY, amount)
        );
        token.transfer(alice, amount);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowanceAmount, uint256 spend) public {
        allowanceAmount = bound(allowanceAmount, 0, EXPECTED_SUPPLY);
        spend = bound(spend, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.approve(spender, allowanceAmount);
        vm.prank(spender);
        if (spend > allowanceAmount) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowanceAmount, spend
                )
            );
            token.transferFrom(deployer, bob, spend);
        } else {
            assertTrue(token.transferFrom(deployer, bob, spend));
            assertEq(token.balanceOf(bob), spend);
            assertEq(token.allowance(deployer, spender), allowanceAmount - spend);
        }
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
    }
}
