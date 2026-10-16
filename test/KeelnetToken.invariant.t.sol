// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {KeelnetToken} from "../src/KeelnetToken.sol";

/// @notice Drives Keelnet with random call sequences from a small set of actors, keeps a ghost
///         model of every balance and allowance it expects, and asserts inside each action that the
///         token agreed with the model. Failure paths are driven too: every revert the token must
///         produce is provoked on purpose and checked for the exact ERC-6093 error.
/// @dev Every input is bounded, never assumed away, so with `fail-on-revert = true` any revert that
///      the handler did not itself expect is a finding. Receivers include the token's own address:
///      a plain ERC-20 lets tokens get stuck there, and the sum-of-balances invariant must still
///      hold with that sink counted.
contract KeelnetHandler is Test {
    KeelnetToken public immutable token;
    uint256 public immutable supply;

    /// @dev Addresses that may send: the deployer (the factory stand-in) and five holders.
    address[] public actors;
    /// @dev Addresses that may receive: every actor plus the token contract itself.
    address[] public receivers;

    mapping(address => uint256) public ghostBalance;
    mapping(address => mapping(address => uint256)) public ghostAllowance;

    mapping(bytes32 => uint256) public calls;
    /// @dev Set if the token ever disagreed with the ghost model. Belt and braces beside the
    ///      assertion reverts that `fail-on-revert` already turns into failures.
    bool public modelViolated;

    constructor(KeelnetToken token_, address deployer, address[] memory holders) {
        token = token_;
        supply = token_.totalSupply();
        actors.push(deployer);
        for (uint256 i; i < holders.length; ++i) {
            actors.push(holders[i]);
        }
        receivers = actors;
        receivers.push(address(token_));
        ghostBalance[deployer] = supply;
    }

    // ---------------------------------------------------------------- views for the invariants

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function receiverCount() external view returns (uint256) {
        return receivers.length;
    }

    // ---------------------------------------------------------------- success paths

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _receiver(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        calls["transfer"]++;

        vm.prank(from);
        bool ok = token.transfer(to, amount);
        _check(ok, "transfer returned false");

        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        _checkBalance(from);
        _checkBalance(to);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        // One approval in eight is the infinite allowance, so transferFrom sees both regimes.
        if (amount % 8 == 0) amount = type(uint256).max;
        calls["approve"]++;

        vm.prank(owner);
        bool ok = token.approve(spender, amount);
        _check(ok, "approve returned false");

        ghostAllowance[owner][spender] = amount;
        _check(token.allowance(owner, spender) == amount, "allowance not set");
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _receiver(toSeed);
        uint256 allowed = token.allowance(from, spender);
        uint256 cap = allowed < token.balanceOf(from) ? allowed : token.balanceOf(from);
        amount = bound(amount, 0, cap);
        calls["transferFrom"]++;

        vm.prank(spender);
        bool ok = token.transferFrom(from, to, amount);
        _check(ok, "transferFrom returned false");

        ghostBalance[from] -= amount;
        ghostBalance[to] += amount;
        if (allowed != type(uint256).max) ghostAllowance[from][spender] = allowed - amount;
        _checkBalance(from);
        _checkBalance(to);
        _check(token.allowance(from, spender) == ghostAllowance[from][spender], "allowance drift");
    }

    // ---------------------------------------------------------------- failure paths

    function transferAboveBalance(uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address from = _actor(fromSeed);
        address to = _receiver(toSeed);
        uint256 held = token.balanceOf(from);
        uint256 amount = held + bound(excess, 1, type(uint256).max - held);
        calls["transferAboveBalance"]++;

        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        _check(!ok, "transfer above balance succeeded");
        _check(
            keccak256(ret)
                == keccak256(
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount)
                ),
            "wrong error for transfer above balance"
        );
        _checkBalance(from);
        _checkBalance(to);
    }

    function transferToZeroAddress(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        calls["transferToZeroAddress"]++;

        vm.prank(from);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transfer, (address(0), amount)));
        _check(!ok, "transfer to zero address succeeded");
        _check(
            keccak256(ret) == keccak256(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0))),
            "wrong error for transfer to zero"
        );
        _checkBalance(from);
    }

    function transferFromAboveAllowance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess)
        external
    {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _receiver(toSeed);
        uint256 allowed = token.allowance(from, spender);
        if (allowed == type(uint256).max) {
            // Nothing exceeds an infinite allowance; make it finite first so the path is exercised.
            allowed = bound(excess, 0, token.balanceOf(from));
            vm.prank(from);
            token.approve(spender, allowed);
            ghostAllowance[from][spender] = allowed;
        }
        uint256 amount = allowed + bound(excess, 1, type(uint256).max - allowed);
        calls["transferFromAboveAllowance"]++;

        vm.prank(spender);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        _check(!ok, "transferFrom above allowance succeeded");
        _check(
            keccak256(ret)
                == keccak256(
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, allowed, amount)
                ),
            "wrong error for transferFrom above allowance"
        );
        _checkBalance(from);
        _checkBalance(to);
        _check(token.allowance(from, spender) == allowed, "a failed transferFrom changed the allowance");
    }

    function transferFromAboveBalance(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 excess) external {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        address to = _receiver(toSeed);
        uint256 held = token.balanceOf(from);
        uint256 amount = held + bound(excess, 1, type(uint256).max - held);
        // Give the spender enough allowance that only the balance can be the reason to revert.
        vm.prank(from);
        token.approve(spender, type(uint256).max);
        ghostAllowance[from][spender] = type(uint256).max;
        calls["transferFromAboveBalance"]++;

        vm.prank(spender);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.transferFrom, (from, to, amount)));
        _check(!ok, "transferFrom above balance succeeded");
        _check(
            keccak256(ret)
                == keccak256(
                    abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, held, amount)
                ),
            "wrong error for transferFrom above balance"
        );
        _checkBalance(from);
        _checkBalance(to);
        _check(token.allowance(from, spender) == type(uint256).max, "infinite allowance changed by a failed pull");
    }

    function approveZeroSpender(uint256 ownerSeed, uint256 amount) external {
        address owner = _actor(ownerSeed);
        calls["approveZeroSpender"]++;

        vm.prank(owner);
        (bool ok, bytes memory ret) = address(token).call(abi.encodeCall(IERC20.approve, (address(0), amount)));
        _check(!ok, "approve to zero spender succeeded");
        _check(
            keccak256(ret) == keccak256(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0))),
            "wrong error for approve to zero spender"
        );
    }

    /// @dev Any selector the ERC-20 surface does not define must revert with no state change,
    ///      whoever the caller is. Random calldata hunts for a hidden admin entry point.
    function unknownSelector(uint256 callerSeed, bytes4 selector, bytes calldata args) external {
        if (_isKnownSelector(selector)) return;
        address caller = _actor(callerSeed);
        calls["unknownSelector"]++;

        vm.prank(caller);
        (bool ok,) = address(token).call(bytes.concat(selector, args));
        _check(!ok, "an unknown selector was answered");
        _check(token.totalSupply() == supply, "an unknown selector changed the supply");
        _checkBalance(caller);
    }

    // ---------------------------------------------------------------- internals

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _receiver(uint256 seed) internal view returns (address) {
        return receivers[seed % receivers.length];
    }

    function _checkBalance(address who) internal {
        _check(token.balanceOf(who) == ghostBalance[who], "balance disagrees with the model");
    }

    function _check(bool condition, string memory reason) internal {
        if (!condition) modelViolated = true;
        assertTrue(condition, reason);
    }

    function _isKnownSelector(bytes4 selector) internal view returns (bool) {
        return selector == IERC20.transfer.selector || selector == IERC20.transferFrom.selector
            || selector == IERC20.approve.selector || selector == IERC20.allowance.selector
            || selector == IERC20.balanceOf.selector || selector == IERC20.totalSupply.selector
            || selector == IERC20Metadata.name.selector || selector == IERC20Metadata.symbol.selector
            || selector == IERC20Metadata.decimals.selector || selector == token.TOKEN_NAME.selector
            || selector == token.TOKEN_SYMBOL.selector || selector == token.DECIMALS.selector
            || selector == token.SUPPLY_WHOLE_TOKENS.selector || selector == token.TOTAL_SUPPLY.selector;
    }
}

/// @notice Invariants of Keelnet under random sequences of transfers, approvals, pulls and
///         deliberate failures from several actors. The token keeps balances, so what it owes
///         (the sum of balances) must always equal what exists (the fixed supply).
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract KeelnetTokenInvariantTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    address internal deployer = makeAddr("deployer");
    KeelnetToken internal token;
    KeelnetHandler internal handler;
    bytes32 internal codeHashAtDeployment;

    function setUp() public {
        vm.prank(deployer);
        token = new KeelnetToken();
        codeHashAtDeployment = address(token).codehash;

        address[] memory holders = new address[](5);
        holders[0] = makeAddr("alice");
        holders[1] = makeAddr("bob");
        holders[2] = makeAddr("carol");
        holders[3] = makeAddr("dave");
        holders[4] = makeAddr("erin");
        handler = new KeelnetHandler(token, deployer, holders);

        targetContract(address(handler));
    }

    /// @dev Fixed supply: no sequence of calls grows or shrinks it.
    function invariant_totalSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "supply changed");
        assertEq(token.TOTAL_SUPPLY(), EXPECTED_SUPPLY, "supply constant changed");
    }

    /// @dev Conservation: every unit minted sits with exactly one of the addresses that could
    ///      have received it, the token's own address included.
    function invariant_sumOfBalancesEqualsSupply() public view {
        uint256 sum;
        uint256 n = handler.receiverCount();
        for (uint256 i; i < n; ++i) {
            sum += token.balanceOf(handler.receivers(i));
        }
        assertEq(sum, token.totalSupply(), "balances do not sum to the supply");
    }

    /// @dev The token's balances agree with the ghost model the handler kept from the outside.
    function invariant_balancesMatchGhostModel() public view {
        uint256 n = handler.receiverCount();
        uint256 ghostSum;
        for (uint256 i; i < n; ++i) {
            address who = handler.receivers(i);
            assertEq(token.balanceOf(who), handler.ghostBalance(who), "balance drifted from the model");
            ghostSum += handler.ghostBalance(who);
        }
        assertEq(ghostSum, EXPECTED_SUPPLY, "ghost model lost or invented tokens");
        assertFalse(handler.modelViolated(), "the handler recorded a disagreement");
    }

    /// @dev Allowances only change through approve and through a successful transferFrom.
    function invariant_allowancesMatchGhostModel() public view {
        uint256 n = handler.actorCount();
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < n; ++j) {
                address owner = handler.actors(i);
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.ghostAllowance(owner, spender), "allowance drifted");
            }
        }
    }

    /// @dev Nobody can hold more than exists, and the zero address holds nothing.
    function invariant_noBalanceExceedsSupplyAndZeroHoldsNothing() public view {
        uint256 n = handler.receiverCount();
        for (uint256 i; i < n; ++i) {
            assertLe(token.balanceOf(handler.receivers(i)), EXPECTED_SUPPLY, "a balance exceeds the supply");
        }
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
    }

    /// @dev Metadata and code are immutable: no call changes what the token says it is.
    function invariant_metadataAndCodeUnchanged() public view {
        assertEq(token.name(), "Keelnet");
        assertEq(token.symbol(), "KEEL");
        assertEq(token.decimals(), 18);
        assertEq(address(token).codehash, codeHashAtDeployment, "runtime code changed");
        assertEq(address(token).balance, 0, "the token holds ether");
    }

    /// @dev The handler's actions are live, not vacuous: each one, driven once by hand, runs to its
    ///      assertions and counts itself. (Not an invariant, because invariants are also checked
    ///      after the first call of a sequence, when the counters may legitimately still be zero.)
    function test_handlerActionsAreExercised() public {
        handler.transfer(0, 1, 5e18);
        handler.approve(0, 2, 7e18);
        handler.transferFrom(2, 0, 3, 7e18);
        handler.transferAboveBalance(1, 2, 1);
        handler.transferToZeroAddress(0, 1);
        handler.transferFromAboveAllowance(3, 0, 1, 1);
        handler.transferFromAboveBalance(4, 1, 2, 1);
        handler.approveZeroSpender(0, 1);
        handler.unknownSelector(0, bytes4(keccak256("mint(address,uint256)")), abi.encode(deployer, 1));
        handler.unknownSelector(1, IERC20.transfer.selector, "");

        assertEq(handler.calls("transfer"), 1);
        assertEq(handler.calls("approve"), 1);
        assertEq(handler.calls("transferFrom"), 1);
        assertEq(handler.calls("transferAboveBalance"), 1);
        assertEq(handler.calls("transferToZeroAddress"), 1);
        assertEq(handler.calls("transferFromAboveAllowance"), 1);
        assertEq(handler.calls("transferFromAboveBalance"), 1);
        assertEq(handler.calls("approveZeroSpender"), 1);
        assertEq(handler.calls("unknownSelector"), 1, "a known selector must be skipped, not counted");
        assertFalse(handler.modelViolated());

        invariant_sumOfBalancesEqualsSupply();
        invariant_balancesMatchGhostModel();
        invariant_allowancesMatchGhostModel();
    }
}

/// @notice The same token under the open fuzzer: the runner picks senders and arguments itself,
///         with every selector of the token as a target and reverts allowed. Whatever a stranger
///         sends, the supply does not move and nobody holds more than the supply.
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 32
/// forge-config: default.invariant.fail-on-revert = false
contract KeelnetTokenOpenInvariantTest is Test {
    uint256 internal constant EXPECTED_SUPPLY = 1_000_000_000 * 1e18;

    address internal deployer = makeAddr("deployer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    KeelnetToken internal token;

    function setUp() public {
        vm.prank(deployer);
        token = new KeelnetToken();
        targetContract(address(token));
        targetSender(deployer);
        targetSender(alice);
        targetSender(bob);
        targetSender(address(0xBEEF));
    }

    function invariant_openSupplyNeverChanges() public view {
        assertEq(token.totalSupply(), EXPECTED_SUPPLY, "supply changed under open fuzzing");
    }

    function invariant_openKnownHoldersNeverExceedSupply() public view {
        assertLe(token.balanceOf(deployer), EXPECTED_SUPPLY);
        assertLe(token.balanceOf(alice), EXPECTED_SUPPLY);
        assertLe(token.balanceOf(bob), EXPECTED_SUPPLY);
        assertLe(token.balanceOf(deployer) + token.balanceOf(alice) + token.balanceOf(bob), EXPECTED_SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function invariant_openMetadataUnchanged() public view {
        assertEq(token.name(), "Keelnet");
        assertEq(token.symbol(), "KEEL");
        assertEq(token.decimals(), 18);
    }
}
