// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {KeelnetToken} from "../src/KeelnetToken.sol";

/// @notice Stands in for the launch factory: deploys the token and pays the supply out in the same
///         call, as `launchCustom` does in one transaction. Every amount must arrive exactly.
contract LaunchFlowProbe {
    uint256 public constant SWARM_BPS = 1_000;

    KeelnetToken public token;

    /// @dev Deploy, then move the swarm share, the pool share and the remainder, all in one call.
    ///      Returns the token so the test can inspect it afterwards.
    function launch(uint256 poolBps, address distributor, address pool, address remainderTo)
        external
        returns (KeelnetToken deployed)
    {
        deployed = new KeelnetToken();
        token = deployed;
        uint256 supply = deployed.totalSupply();
        require(deployed.balanceOf(address(this)) == supply, "supply not minted to the factory");

        uint256 swarm = (supply * SWARM_BPS) / 10_000;
        uint256 poolShare = (supply * poolBps) / 10_000;
        uint256 remainder = supply - swarm - poolShare;

        require(deployed.transfer(distributor, swarm), "swarm transfer returned false");
        require(deployed.balanceOf(distributor) == swarm, "swarm share arrived short");
        require(deployed.transfer(pool, poolShare), "pool transfer returned false");
        require(deployed.balanceOf(pool) == poolShare, "pool share arrived short");
        require(deployed.transfer(remainderTo, remainder), "remainder transfer returned false");
        require(deployed.balanceOf(remainderTo) == remainder, "remainder arrived short");
        require(deployed.balanceOf(address(this)) == 0, "the factory kept something back");
    }

    /// @dev Two deployments from one caller: each is its own supply; neither sees the other.
    function launchTwice() external returns (KeelnetToken first, KeelnetToken second) {
        first = new KeelnetToken();
        second = new KeelnetToken();
    }
}

/// @notice Inputs the behavioural suite did not reach: the zero address as a sender, pulls from
///         oneself, the allowance one below infinity, tokens sent to the contract itself, the same
///         call twice, strangers with no balance, the launch's single-transaction flow, and the
///         arithmetic of the supply constant at its edges.
/// forge-config: default.fuzz.runs = 1000
contract KeelnetTokenEdgesTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal spender = makeAddr("spender");

    KeelnetToken internal token;

    function setUp() public {
        vm.prank(deployer);
        token = new KeelnetToken();
    }

    // ---------------------------------------------------------------- supply arithmetic

    function test_supplyIsExactlyOneBillionTimesTenToTheDecimals() public view {
        assertEq(token.totalSupply(), 1_000_000_000 * 10 ** uint256(token.decimals()));
        assertEq(token.totalSupply() / 10 ** uint256(token.decimals()), 1_000_000_000);
        assertEq(token.totalSupply() % 10 ** uint256(token.decimals()), 0);
    }

    /// @dev The supply fits in the narrower integer widths common in pool and vesting code, so no
    ///      downstream cast of a balance can truncate it.
    function test_supplyFitsInUint96AndUint128() public view {
        assertLe(token.totalSupply(), uint256(type(uint96).max));
        assertLe(token.totalSupply(), uint256(type(uint128).max));
        assertEq(uint256(uint96(token.totalSupply())), token.totalSupply());
    }

    function test_constantsAgreeWithRuntimeMetadata() public view {
        assertEq(token.TOTAL_SUPPLY(), token.totalSupply());
        assertEq(token.DECIMALS(), token.decimals());
        assertEq(keccak256(bytes(token.TOKEN_NAME())), keccak256(bytes(token.name())));
        assertEq(keccak256(bytes(token.TOKEN_SYMBOL())), keccak256(bytes(token.symbol())));
    }

    // ---------------------------------------------------------------- zero address as sender

    function test_zeroAddressCannotTransfer() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSender.selector, address(0)));
        token.transfer(alice, 0);
    }

    function test_zeroAddressCannotApprove() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.approve(spender, 1);
    }

    /// @dev An approval granted to a spender for the zero address as owner cannot exist, so a
    ///      transferFrom naming the zero address as `from` fails on allowance before anything else.
    function test_transferFromZeroAddressRevertsOnAllowance() public {
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(address(0), alice, 1);
    }

    // ---------------------------------------------------------------- transferFrom edges

    /// @dev Being the owner grants nothing: a holder pulling from itself still needs an allowance.
    function test_ownerCannotTransferFromItselfWithoutSelfAllowance() public {
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1));
        token.transferFrom(deployer, alice, 1);
    }

    function test_selfAllowanceLetsOwnerTransferFromItself() public {
        vm.startPrank(deployer);
        token.approve(deployer, 3e18);
        assertTrue(token.transferFrom(deployer, alice, 3e18));
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 3e18);
        assertEq(token.allowance(deployer, deployer), 0);
    }

    /// @dev `from == to` moves nothing but still spends the allowance.
    function test_transferFromToSameAddressSpendsAllowanceOnly() public {
        vm.prank(deployer);
        token.approve(spender, 10e18);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, deployer, 4e18));
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.allowance(deployer, spender), 6e18);
    }

    /// @dev Only exactly `type(uint256).max` is infinite; one below it is an ordinary allowance.
    function test_allowanceOneBelowMaxIsDecremented() public {
        uint256 nearlyInfinite = type(uint256).max - 1;
        vm.prank(deployer);
        token.approve(spender, nearlyInfinite);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, spender), nearlyInfinite - 1);
    }

    /// @dev Allowance is checked before balance: a spender with an allowance larger than the
    ///      owner's balance is told about the balance, one with a smaller allowance about the
    ///      allowance, and a balance shortfall never consumes any allowance.
    function test_allowanceIsCheckedBeforeBalanceAndFailedPullKeepsAllowance() public {
        vm.prank(alice);
        token.approve(spender, 5e18);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 5e18, 6e18));
        token.transferFrom(alice, bob, 6e18);

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 5e18));
        token.transferFrom(alice, bob, 5e18);
        assertEq(token.allowance(alice, spender), 5e18, "a failed pull consumed allowance");
    }

    function test_allowanceIsPerSpender() public {
        vm.prank(deployer);
        token.approve(spender, 10e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1));
        token.transferFrom(deployer, bob, 1);
        assertEq(token.allowance(deployer, spender), 10e18);
    }

    function test_plainTransferDoesNotTouchAllowances() public {
        vm.startPrank(deployer);
        token.approve(spender, 10e18);
        token.transfer(alice, 1e18);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 10e18);
        assertEq(token.allowance(alice, spender), 0);
    }

    /// @dev Approvals are plain overwrites, never cumulative, and may be reset to zero.
    function test_approveIsOverwriteNotIncrement() public {
        vm.startPrank(deployer);
        token.approve(spender, 10e18);
        token.approve(spender, 10e18);
        assertEq(token.allowance(deployer, spender), 10e18);
        token.approve(spender, 0);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), 0);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(deployer, bob, 1);
    }

    /// @dev Approving more than the balance is allowed; the pull is bounded by the balance.
    function test_allowanceAboveBalanceIsBoundedByBalanceOnPull() public {
        vm.prank(deployer);
        token.transfer(alice, 2e18);
        vm.prank(alice);
        token.approve(spender, type(uint128).max);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 2e18, 2e18 + 1));
        token.transferFrom(alice, bob, 2e18 + 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 2e18));
        assertEq(token.balanceOf(alice), 0);
    }

    // ---------------------------------------------------------------- the same call twice

    function test_sameTransferTwiceFailsOnceBalanceIsGone() public {
        vm.prank(deployer);
        token.transfer(alice, 10e18);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 10e18));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 10e18));
        token.transfer(bob, 10e18);
        assertEq(token.balanceOf(bob), 10e18);
    }

    function test_sameTransferFromTwiceFailsOnceAllowanceIsSpent() public {
        vm.prank(deployer);
        token.approve(spender, 10e18);
        vm.prank(spender);
        token.transferFrom(deployer, bob, 10e18);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 10e18));
        token.transferFrom(deployer, bob, 10e18);
        assertEq(token.balanceOf(bob), 10e18);
    }

    // ---------------------------------------------------------------- tokens sent to the contract

    /// @dev A plain ERC-20 accepts its own address as a receiver and has no way to recover what
    ///      lands there. The README says so; this pins it as documented behaviour, not a defect.
    function test_tokensSentToTheContractAreStuckAndStillCounted() public {
        vm.prank(deployer);
        assertTrue(token.transfer(address(token), 1e18));
        assertEq(token.balanceOf(address(token)), 1e18);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer) + token.balanceOf(address(token)), EXPECTED_SUPPLY);

        // The contract itself never calls out, so no selector moves them, from anyone.
        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, deployer, 0, 1e18));
        token.transferFrom(address(token), deployer, 1e18);
        (bool ok,) = address(token).call(abi.encodeWithSignature("recover(address,uint256)", deployer, 1e18));
        assertFalse(ok);
        (ok,) = address(token).call(abi.encodeWithSignature("sweep(address)", deployer));
        assertFalse(ok);
        assertEq(token.balanceOf(address(token)), 1e18);
    }

    // ---------------------------------------------------------------- strangers

    function test_strangerCanApproveButSpenderPullsNothing() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        assertTrue(token.approve(spender, EXPECTED_SUPPLY));
        vm.prank(spender);
        assertTrue(token.transferFrom(stranger, bob, 0));
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, stranger, 0, 1));
        token.transferFrom(stranger, bob, 1);
    }

    function test_viewsOnUnknownAddressesAreZero() public view {
        address unknown = address(0x1234);
        assertEq(token.balanceOf(unknown), 0);
        assertEq(token.allowance(unknown, deployer), 0);
        assertEq(token.allowance(deployer, unknown), 0);
        assertEq(token.balanceOf(address(0)), 0);
    }

    // ---------------------------------------------------------------- launch flow in one call

    /// @dev The factory deploys and pays out in one transaction. The whole flow, at the README's
    ///      80% pool share, moves every amount exactly and leaves the factory empty.
    function test_launchFlowInOneCallMovesExactAmounts() public {
        LaunchFlowProbe probe = new LaunchFlowProbe();
        address distributor = makeAddr("distributor");
        address pool = makeAddr("pool");
        address remainderTo = makeAddr("remainderTo");

        KeelnetToken launched = probe.launch(8_000, distributor, pool, remainderTo);

        assertEq(launched.totalSupply(), EXPECTED_SUPPLY);
        assertEq(launched.balanceOf(distributor), EXPECTED_SUPPLY / 10);
        assertEq(launched.balanceOf(pool), (EXPECTED_SUPPLY * 8_000) / 10_000);
        assertEq(launched.balanceOf(remainderTo), EXPECTED_SUPPLY / 10);
        assertEq(launched.balanceOf(address(probe)), 0);
        assertEq(
            launched.balanceOf(distributor) + launched.balanceOf(pool) + launched.balanceOf(remainderTo),
            EXPECTED_SUPPLY
        );

        // A claimant takes the whole swarm share, whole.
        address claimant = makeAddr("claimant");
        vm.prank(distributor);
        assertTrue(launched.transfer(claimant, EXPECTED_SUPPLY / 10));
        assertEq(launched.balanceOf(claimant), EXPECTED_SUPPLY / 10);
        assertEq(launched.balanceOf(distributor), 0);
    }

    /// @dev Any pool share from 0 to 90% leaves a non-negative remainder and the flow is exact.
    function testFuzz_launchFlowIsExactForAnyPoolShare(uint16 poolBps) public {
        poolBps = uint16(bound(poolBps, 0, 9_000));
        LaunchFlowProbe probe = new LaunchFlowProbe();
        address distributor = makeAddr("distributor");
        address pool = makeAddr("pool");
        address remainderTo = makeAddr("remainderTo");

        KeelnetToken launched = probe.launch(poolBps, distributor, pool, remainderTo);

        uint256 swarm = EXPECTED_SUPPLY / 10;
        uint256 poolShare = (EXPECTED_SUPPLY * poolBps) / 10_000;
        assertEq(launched.balanceOf(distributor), swarm);
        assertEq(launched.balanceOf(pool), poolShare);
        assertEq(launched.balanceOf(remainderTo), EXPECTED_SUPPLY - swarm - poolShare);
        assertEq(launched.balanceOf(address(probe)), 0);
    }

    function test_twoDeploymentsAreIndependent() public {
        LaunchFlowProbe probe = new LaunchFlowProbe();
        (KeelnetToken first, KeelnetToken second) = probe.launchTwice();
        assertTrue(address(first) != address(second));
        assertEq(first.totalSupply(), EXPECTED_SUPPLY);
        assertEq(second.totalSupply(), EXPECTED_SUPPLY);
        assertEq(first.balanceOf(address(probe)), EXPECTED_SUPPLY);
        assertEq(second.balanceOf(address(probe)), EXPECTED_SUPPLY);
        assertEq(first.balanceOf(address(second)), 0);
        assertEq(second.balanceOf(address(first)), 0);
        assertEq(first.balanceOf(deployer), 0);
    }

    /// @dev The constructor reads nothing from its environment: deploying through CREATE2 at a
    ///      predictable address, as the factory does, mints the same supply to the same creator.
    function test_create2DeploymentMintsToCreator() public {
        bytes32 salt = bytes32(uint256(7));
        bytes memory code = type(KeelnetToken).creationCode;
        address predicted = vm.computeCreate2Address(salt, keccak256(code), address(this));
        KeelnetToken created = new KeelnetToken{salt: salt}();
        assertEq(address(created), predicted);
        assertEq(created.balanceOf(address(this)), EXPECTED_SUPPLY);
        assertEq(created.totalSupply(), EXPECTED_SUPPLY);
    }

    // ---------------------------------------------------------------- fuzz at the edges

    /// @dev Splitting the supply across two transfers conserves it; the second fails iff the
    ///      pair overshoots.
    function testFuzz_twoTransfersConserveOrRevertExactly(uint256 first, uint256 second) public {
        first = bound(first, 0, EXPECTED_SUPPLY);
        second = bound(second, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, first);
        uint256 left = EXPECTED_SUPPLY - first;
        vm.prank(deployer);
        if (second > left) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, deployer, left, second)
            );
            token.transfer(bob, second);
            assertEq(token.balanceOf(bob), 0);
        } else {
            assertTrue(token.transfer(bob, second));
            assertEq(token.balanceOf(bob), second);
        }
        assertEq(token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob), EXPECTED_SUPPLY);
    }

    /// @dev A round trip returns every unit: transfer out and back leaves balances as they began.
    function testFuzz_transferRoundTripRestoresBalances(uint256 amount) public {
        amount = bound(amount, 0, EXPECTED_SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, amount);
        vm.prank(alice);
        token.transfer(deployer, amount);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(alice), 0);
    }

    /// @dev Approve is a pure setter for any value, infinite included.
    function testFuzz_approveRoundTrip(address who, uint256 amount) public {
        who = address(uint160(bound(uint256(uint160(who)), 1, type(uint160).max)));
        vm.prank(deployer);
        assertTrue(token.approve(who, amount));
        assertEq(token.allowance(deployer, who), amount);
        assertEq(token.allowance(who, deployer), 0);
    }

    /// @dev Whoever has no balance cannot send a single unit, whatever address they are.
    function testFuzz_emptyAccountCannotSendAnything(address sender, uint256 amount) public {
        sender = address(uint160(bound(uint256(uint160(sender)), 1, type(uint160).max)));
        if (sender == deployer) sender = alice;
        amount = bound(amount, 1, type(uint256).max);
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, sender, 0, amount));
        token.transfer(bob, amount);
    }

    /// @dev Infinite allowance survives any number of pulls of any size the balance allows.
    function testFuzz_infiniteAllowanceNeverDecrements(uint256 a, uint256 b) public {
        a = bound(a, 0, EXPECTED_SUPPLY);
        b = bound(b, 0, EXPECTED_SUPPLY - a);
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        token.transferFrom(deployer, alice, a);
        token.transferFrom(deployer, bob, b);
        vm.stopPrank();
        assertEq(token.allowance(deployer, spender), type(uint256).max);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY - a - b);
    }

    /// @dev Calldata of any length behind an unknown selector is refused by every caller.
    function testFuzz_unknownSelectorAlwaysReverts(bytes4 selector, bytes calldata args, address caller) public {
        // Steer a known selector away instead of discarding the run.
        while (_isKnownSelector(selector)) {
            selector = bytes4(keccak256(abi.encodePacked(selector)));
        }
        vm.prank(caller);
        (bool ok,) = address(token).call(bytes.concat(selector, args));
        assertFalse(ok);
        assertEq(token.totalSupply(), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(deployer), EXPECTED_SUPPLY);
    }

    function _isKnownSelector(bytes4 selector) internal pure returns (bool) {
        return selector == IERC20.transfer.selector || selector == IERC20.transferFrom.selector
            || selector == IERC20.approve.selector || selector == IERC20.allowance.selector
            || selector == IERC20.balanceOf.selector || selector == IERC20.totalSupply.selector
            || selector == bytes4(keccak256("name()")) || selector == bytes4(keccak256("symbol()"))
            || selector == bytes4(keccak256("decimals()")) || selector == bytes4(keccak256("TOKEN_NAME()"))
            || selector == bytes4(keccak256("TOKEN_SYMBOL()")) || selector == bytes4(keccak256("DECIMALS()"))
            || selector == bytes4(keccak256("SUPPLY_WHOLE_TOKENS()")) || selector == bytes4(keccak256("TOTAL_SUPPLY()"));
    }
}
