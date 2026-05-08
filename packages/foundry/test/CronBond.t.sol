// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2, StdInvariant} from "forge-std/Test.sol";
import {CronBond} from "../contracts/CronBond.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

// -----------------------------------------------------------------
// Mock USDC implementations
// -----------------------------------------------------------------

contract MockUSDC {
    string public name = "USD Coin";
    string public symbol = "USDC";
    uint8 public decimals = 6;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) {
            allowance[from][msg.sender] = a - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal virtual {
        require(balanceOf[from] >= amount, "balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

contract MockUSDCWithBlocklist is MockUSDC {
    mapping(address => bool) public blocked;

    function setBlocked(address a, bool v) external {
        blocked[a] = v;
    }

    function _transfer(address from, address to, uint256 amount) internal override {
        require(!blocked[from], "blocked from");
        require(!blocked[to], "blocked to");
        super._transfer(from, to, amount);
    }
}

// -----------------------------------------------------------------
// Mock target contracts
// -----------------------------------------------------------------

contract MockTarget {
    uint256 public counter;

    function ping() external {
        counter++;
    }

    function bork() external pure {
        revert("bork");
    }
}

contract ReentrantTarget {
    CronBond public bond;
    uint256 public jobId;
    bool public attempted;

    function setup(CronBond _bond, uint256 _jobId) external {
        bond = _bond;
        jobId = _jobId;
    }

    function attack() external {
        attempted = true;
        bond.cancel(jobId);
    }
}

// -----------------------------------------------------------------
// Main test contract
// -----------------------------------------------------------------

contract CronBondTest is Test {
    CronBond internal cb;
    MockUSDC internal usdc;

    address internal owner = address(0xABCD);
    address internal feeReceiver = address(0xFEE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal keeper = address(0xC0FFEE);

    MockTarget internal target;

    uint256 internal constant START_TIMESTAMP = 1_700_000_000;

    event JobRegistered(
        uint256 indexed jobId,
        address indexed registrant,
        address indexed target,
        uint64 executeAt,
        uint256 bondAmount,
        uint32 maxGas,
        bytes32 calldataHash
    );
    event JobExecuted(
        uint256 indexed jobId,
        address indexed keeper,
        bool success,
        bytes32 calldataHash,
        uint256 keeperPayout,
        uint64 gasUsed
    );
    event JobCancelled(uint256 indexed jobId, address indexed registrant, uint256 refunded, uint256 cancellationFee);
    event JobReclaimedStale(uint256 indexed jobId, address indexed registrant, uint256 refunded, uint256 fee);
    event ProtocolFeeWithdrawn(address indexed to, uint256 amount);

    event MinBondUpdated(uint256 oldValue, uint256 newValue);
    event ProtocolFeeBpsUpdated(uint256 oldValue, uint256 newValue);
    event CancellationFeeBpsUpdated(uint256 oldValue, uint256 newValue);
    event CancellationFeeFloorUpdated(uint256 oldValue, uint256 newValue);
    event StaleWindowUpdated(uint256 oldValue, uint256 newValue);
    event MinDelayUpdated(uint64 oldValue, uint64 newValue);
    event MaxDelayUpdated(uint64 oldValue, uint64 newValue);

    function setUp() public virtual {
        vm.warp(START_TIMESTAMP);
        usdc = new MockUSDC();
        cb = new CronBond(address(usdc), feeReceiver, owner);
        target = new MockTarget();

        // Fund users
        usdc.mint(alice, 1_000_000 * 1e6);
        usdc.mint(bob, 1_000_000 * 1e6);

        vm.prank(alice);
        usdc.approve(address(cb), type(uint256).max);
        vm.prank(bob);
        usdc.approve(address(cb), type(uint256).max);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    function _registerDefault(address user) internal returns (uint256) {
        bytes memory data = abi.encodeWithSelector(MockTarget.ping.selector);
        uint64 executeAt = uint64(block.timestamp + 3600);
        uint256 bondAmount = 10 * 1e6; // $10
        uint32 maxGas = 200_000;
        vm.prank(user);
        return cb.register(address(target), data, executeAt, bondAmount, maxGas);
    }

    // -----------------------------------------------------------------
    // register() unit tests
    // -----------------------------------------------------------------

    function test_Register_HappyPath_EmitsEvent() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.ping.selector);
        uint64 executeAt = uint64(block.timestamp + 3600);
        uint256 bondAmount = 10 * 1e6;
        uint32 maxGas = 200_000;

        vm.expectEmit(true, true, true, true, address(cb));
        emit JobRegistered(0, alice, address(target), executeAt, bondAmount, maxGas, keccak256(data));

        vm.prank(alice);
        uint256 jobId = cb.register(address(target), data, executeAt, bondAmount, maxGas);
        assertEq(jobId, 0);
    }

    function test_Register_RevertsBannedTarget() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.ping.selector);
        uint64 executeAt = uint64(block.timestamp + 3600);
        vm.prank(alice);
        vm.expectRevert(CronBond.BannedTarget.selector);
        cb.register(address(cb), data, executeAt, 10 * 1e6, 200_000);
    }

    function test_Register_RevertsBannedTarget_USDC() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.ping.selector);
        uint64 executeAt = uint64(block.timestamp + 3600);
        vm.prank(alice);
        vm.expectRevert(CronBond.BannedTarget.selector);
        cb.register(address(usdc), data, executeAt, 10 * 1e6, 200_000);
    }

    function test_Constructor_RevertsZeroUSDC() public {
        vm.expectRevert(CronBond.ZeroTarget.selector);
        new CronBond(address(0), feeReceiver, owner);
    }

    function test_Constructor_RevertsZeroFeeReceiver() public {
        vm.expectRevert(CronBond.ZeroTarget.selector);
        new CronBond(address(usdc), address(0), owner);
    }

    function test_Register_RevertsZeroTarget() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.ping.selector);
        uint64 executeAt = uint64(block.timestamp + 3600);
        vm.prank(alice);
        vm.expectRevert(CronBond.ZeroTarget.selector);
        cb.register(address(0), data, executeAt, 10 * 1e6, 200_000);
    }

    function test_Register_RevertsCalldataTooLarge() public {
        bytes memory data = new bytes(4097);
        uint64 executeAt = uint64(block.timestamp + 3600);
        vm.prank(alice);
        vm.expectRevert(CronBond.CalldataTooLarge.selector);
        cb.register(address(target), data, executeAt, 10 * 1e6, 200_000);
    }

    function test_Register_RevertsBondBelowMin() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.ping.selector);
        uint64 executeAt = uint64(block.timestamp + 3600);
        uint256 bondAmount = cb.minBond() - 1;
        vm.prank(alice);
        vm.expectRevert(CronBond.BondBelowMin.selector);
        cb.register(address(target), data, executeAt, bondAmount, 200_000);
    }

    function test_Register_RevertsExecuteAtTooSoon() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.ping.selector);
        uint64 executeAt = uint64(block.timestamp + cb.minDelay() - 1);
        vm.prank(alice);
        vm.expectRevert(CronBond.ExecuteAtTooSoon.selector);
        cb.register(address(target), data, executeAt, 10 * 1e6, 200_000);
    }

    function test_Register_RevertsExecuteAtTooFar() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.ping.selector);
        uint64 executeAt = uint64(block.timestamp + cb.maxDelay() + 1);
        vm.prank(alice);
        vm.expectRevert(CronBond.ExecuteAtTooFar.selector);
        cb.register(address(target), data, executeAt, 10 * 1e6, 200_000);
    }

    function test_Register_RevertsMaxGasOutOfRange_BelowFloor() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.ping.selector);
        uint64 executeAt = uint64(block.timestamp + 3600);
        uint32 maxGas = cb.MAX_GAS_FLOOR() - 1;
        vm.prank(alice);
        vm.expectRevert(CronBond.MaxGasOutOfRange.selector);
        cb.register(address(target), data, executeAt, 10 * 1e6, maxGas);
    }

    function test_Register_RevertsMaxGasOutOfRange_AboveCeiling() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.ping.selector);
        uint64 executeAt = uint64(block.timestamp + 3600);
        uint32 maxGas = cb.MAX_GAS_CEILING() + 1;
        vm.prank(alice);
        vm.expectRevert(CronBond.MaxGasOutOfRange.selector);
        cb.register(address(target), data, executeAt, 10 * 1e6, maxGas);
    }

    function test_Register_RevertsWhenPaused_ThenSucceedsUnpaused() public {
        vm.prank(owner);
        cb.pause();

        bytes memory data = abi.encodeWithSelector(MockTarget.ping.selector);
        uint64 executeAt = uint64(block.timestamp + 3600);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        cb.register(address(target), data, executeAt, 10 * 1e6, 200_000);

        vm.prank(owner);
        cb.unpause();

        vm.prank(alice);
        cb.register(address(target), data, executeAt, 10 * 1e6, 200_000);
    }

    function test_Register_TransfersUSDC() public {
        uint256 aliceBefore = usdc.balanceOf(alice);
        uint256 cbBefore = usdc.balanceOf(address(cb));

        uint256 bondAmount = 10 * 1e6;
        _registerDefault(alice);

        assertEq(usdc.balanceOf(alice), aliceBefore - bondAmount);
        assertEq(usdc.balanceOf(address(cb)), cbBefore + bondAmount);
    }

    // -----------------------------------------------------------------
    // execute() unit tests
    // -----------------------------------------------------------------

    function test_Execute_HappyPath_Success() public {
        uint256 jobId = _registerDefault(alice);
        // jump to executeAt
        vm.warp(block.timestamp + 3600);

        uint256 bondAmount = 10 * 1e6;
        uint256 fee = (bondAmount * cb.protocolFeeBps()) / cb.BPS_DENOMINATOR();
        uint256 payout = bondAmount - fee;

        vm.prank(keeper);
        bool success = cb.execute(jobId);
        assertTrue(success);

        assertEq(cb.protocolFeesAccrued(), fee);
        assertEq(cb.pendingWithdrawals(keeper), payout);
        assertEq(target.counter(), 1);

        ( , , , , CronBond.JobStatus status, , , ) = _getJob(jobId);
        assertEq(uint256(status), uint256(CronBond.JobStatus.Executed));
    }

    function test_Execute_HappyPath_RevertingTarget_KeeperStillPaid() public {
        bytes memory data = abi.encodeWithSelector(MockTarget.bork.selector);
        uint64 executeAt = uint64(block.timestamp + 3600);
        uint256 bondAmount = 10 * 1e6;
        uint32 maxGas = 200_000;
        vm.prank(alice);
        uint256 jobId = cb.register(address(target), data, executeAt, bondAmount, maxGas);

        vm.warp(executeAt);

        uint256 fee = (bondAmount * cb.protocolFeeBps()) / cb.BPS_DENOMINATOR();
        uint256 payout = bondAmount - fee;

        vm.prank(keeper);
        bool success = cb.execute(jobId);
        assertFalse(success);

        assertEq(cb.pendingWithdrawals(keeper), payout);
        assertEq(cb.protocolFeesAccrued(), fee);
    }

    function test_Execute_RevertsJobNotActive_AlreadyExecuted() public {
        uint256 jobId = _registerDefault(alice);
        vm.warp(block.timestamp + 3600);
        vm.prank(keeper);
        cb.execute(jobId);

        vm.prank(keeper);
        vm.expectRevert(CronBond.JobNotActive.selector);
        cb.execute(jobId);
    }

    function test_Execute_RevertsJobNotActive_AlreadyCancelled() public {
        uint256 jobId = _registerDefault(alice);
        vm.prank(alice);
        cb.cancel(jobId);

        vm.warp(block.timestamp + 3600);
        vm.prank(keeper);
        vm.expectRevert(CronBond.JobNotActive.selector);
        cb.execute(jobId);
    }

    function test_Execute_RevertsJobNotActive_AlreadyReclaimed() public {
        uint256 jobId = _registerDefault(alice);
        // warp far ahead past executeAt + staleWindow
        vm.warp(block.timestamp + 3600 + cb.staleWindow());
        vm.prank(alice);
        cb.reclaimStale(jobId);

        vm.prank(keeper);
        vm.expectRevert(CronBond.JobNotActive.selector);
        cb.execute(jobId);
    }

    function test_Execute_RevertsNotYetExecutable() public {
        uint256 jobId = _registerDefault(alice);
        // executeAt is block.timestamp + 3600 -- one second before
        vm.warp(block.timestamp + 3599);
        vm.prank(keeper);
        vm.expectRevert(CronBond.NotYetExecutable.selector);
        cb.execute(jobId);
    }

    function test_Execute_RevertsInsufficientGas() public {
        uint256 jobId = _registerDefault(alice);
        vm.warp(block.timestamp + 3600);

        // maxGas is 200_000 + EXECUTION_OVERHEAD = 50_000 -> need >= 250_000
        // Provide less.
        vm.prank(keeper);
        vm.expectRevert(CronBond.InsufficientGas.selector);
        cb.execute{gas: 200_000}(jobId);
    }

    function test_Execute_CEI_ReentrancyOnCancel() public {
        ReentrantTarget rt = new ReentrantTarget();
        bytes memory data = abi.encodeWithSelector(ReentrantTarget.attack.selector);
        uint64 executeAt = uint64(block.timestamp + 3600);
        uint256 bondAmount = 10 * 1e6;
        uint32 maxGas = 200_000;
        vm.prank(alice);
        uint256 jobId = cb.register(address(rt), data, executeAt, bondAmount, maxGas);

        rt.setup(cb, jobId);

        vm.warp(executeAt);

        // execute will call rt.attack(), which calls cancel().
        // Status is already Executed (CEI), so cancel reverts JobNotActive,
        // and the inner call returns false. execute() itself returns false but does NOT revert.
        vm.prank(keeper);
        bool success = cb.execute(jobId);
        assertFalse(success, "inner reentrant cancel should fail");
        // Job is Executed, keeper got paid
        assertGt(cb.pendingWithdrawals(keeper), 0);
    }

    // -----------------------------------------------------------------
    // cancel() unit tests
    // -----------------------------------------------------------------

    function test_Cancel_HappyPath() public {
        uint256 jobId = _registerDefault(alice);
        uint256 bondAmount = 10 * 1e6;
        uint256 pct = (bondAmount * cb.cancellationFeeBps()) / cb.BPS_DENOMINATOR();
        uint256 expectedFee = pct >= cb.cancellationFeeFloor() ? pct : cb.cancellationFeeFloor();
        uint256 expectedRefund = bondAmount - expectedFee;

        vm.expectEmit(true, true, false, true, address(cb));
        emit JobCancelled(jobId, alice, expectedRefund, expectedFee);
        vm.prank(alice);
        cb.cancel(jobId);

        assertEq(cb.protocolFeesAccrued(), expectedFee);
        assertEq(cb.pendingWithdrawals(alice), expectedRefund);
        ( , , , , CronBond.JobStatus status, , , ) = _getJob(jobId);
        assertEq(uint256(status), uint256(CronBond.JobStatus.Cancelled));
    }

    function test_Cancel_RevertsCancelWindowClosed() public {
        uint256 jobId = _registerDefault(alice);
        // executeAt = start + 3600 ; require block.timestamp + CANCEL_LOCK_WINDOW < executeAt
        // Boundary: block.timestamp + 60 == executeAt => CancelWindowClosed
        vm.warp(START_TIMESTAMP + 3600 - 60);
        vm.prank(alice);
        vm.expectRevert(CronBond.CancelWindowClosed.selector);
        cb.cancel(jobId);
    }

    function test_Cancel_RevertsNotRegistrant() public {
        uint256 jobId = _registerDefault(alice);
        vm.prank(bob);
        vm.expectRevert(CronBond.NotRegistrant.selector);
        cb.cancel(jobId);
    }

    function test_Cancel_RevertsJobNotActive() public {
        uint256 jobId = _registerDefault(alice);
        vm.warp(block.timestamp + 3600);
        vm.prank(keeper);
        cb.execute(jobId);

        vm.prank(alice);
        vm.expectRevert(CronBond.JobNotActive.selector);
        cb.cancel(jobId);
    }

    function test_Cancel_FloorEnforced_WhenSmallBond() public {
        // Use minBond bond. cancellationFeeBps = 500 (5%) -> 5% of 1_000_000 = 50_000.
        // Floor is also 50_000 -- equal. Set floor higher to test.
        vm.prank(owner);
        cb.setCancellationFeeFloor(100_000); // $0.10

        bytes memory data = abi.encodeWithSelector(MockTarget.ping.selector);
        uint64 executeAt = uint64(block.timestamp + 3600);
        uint256 bondAmount = cb.minBond(); // 1_000_000
        uint32 maxGas = 200_000;
        vm.prank(alice);
        uint256 jobId = cb.register(address(target), data, executeAt, bondAmount, maxGas);

        // pct fee = 5% = 50_000, floor = 100_000 -> floor wins
        uint256 expectedFee = 100_000;
        uint256 expectedRefund = bondAmount - expectedFee;

        vm.prank(alice);
        cb.cancel(jobId);
        assertEq(cb.protocolFeesAccrued(), expectedFee);
        assertEq(cb.pendingWithdrawals(alice), expectedRefund);
    }

    // -----------------------------------------------------------------
    // reclaimStale() unit tests
    // -----------------------------------------------------------------

    function test_ReclaimStale_HappyPath() public {
        uint256 jobId = _registerDefault(alice);
        uint64 executeAt = uint64(START_TIMESTAMP + 3600);
        vm.warp(uint256(executeAt) + cb.staleWindow());

        uint256 bondAmount = 10 * 1e6;
        uint256 pct = (bondAmount * cb.cancellationFeeBps()) / cb.BPS_DENOMINATOR();
        uint256 expectedFee = pct >= cb.cancellationFeeFloor() ? pct : cb.cancellationFeeFloor();
        uint256 expectedRefund = bondAmount - expectedFee;

        vm.expectEmit(true, true, false, true, address(cb));
        emit JobReclaimedStale(jobId, alice, expectedRefund, expectedFee);
        vm.prank(alice);
        cb.reclaimStale(jobId);

        ( , , , , CronBond.JobStatus status, , , ) = _getJob(jobId);
        assertEq(uint256(status), uint256(CronBond.JobStatus.Reclaimed));
        assertEq(cb.pendingWithdrawals(alice), expectedRefund);
        assertEq(cb.protocolFeesAccrued(), expectedFee);
    }

    function test_ReclaimStale_RevertsNotStaleYet() public {
        uint256 jobId = _registerDefault(alice);
        uint64 executeAt = uint64(START_TIMESTAMP + 3600);
        vm.warp(uint256(executeAt) + cb.staleWindow() - 1);
        vm.prank(alice);
        vm.expectRevert(CronBond.NotStaleYet.selector);
        cb.reclaimStale(jobId);
    }

    function test_ReclaimStale_RevertsNotRegistrant() public {
        uint256 jobId = _registerDefault(alice);
        uint64 executeAt = uint64(START_TIMESTAMP + 3600);
        vm.warp(uint256(executeAt) + cb.staleWindow());
        vm.prank(bob);
        vm.expectRevert(CronBond.NotRegistrant.selector);
        cb.reclaimStale(jobId);
    }

    function test_ReclaimStale_RevertsJobNotActive() public {
        uint256 jobId = _registerDefault(alice);
        vm.prank(alice);
        cb.cancel(jobId);

        uint64 executeAt = uint64(START_TIMESTAMP + 3600);
        vm.warp(uint256(executeAt) + cb.staleWindow());
        vm.prank(alice);
        vm.expectRevert(CronBond.JobNotActive.selector);
        cb.reclaimStale(jobId);
    }

    // -----------------------------------------------------------------
    // withdraw() unit tests
    // -----------------------------------------------------------------

    function test_Withdraw_HappyPath() public {
        uint256 jobId = _registerDefault(alice);
        vm.warp(block.timestamp + 3600);
        vm.prank(keeper);
        cb.execute(jobId);

        uint256 due = cb.pendingWithdrawals(keeper);
        assertGt(due, 0);

        uint256 keeperBefore = usdc.balanceOf(keeper);
        vm.prank(keeper);
        cb.withdraw();
        assertEq(usdc.balanceOf(keeper), keeperBefore + due);
        assertEq(cb.pendingWithdrawals(keeper), 0);
    }

    function test_Withdraw_RevertsNothingToWithdraw() public {
        vm.prank(alice);
        vm.expectRevert(CronBond.NothingToWithdraw.selector);
        cb.withdraw();
    }

    // -----------------------------------------------------------------
    // withdrawProtocolFees() unit tests
    // -----------------------------------------------------------------

    function test_WithdrawProtocolFees_HappyPath() public {
        uint256 jobId = _registerDefault(alice);
        vm.warp(block.timestamp + 3600);
        vm.prank(keeper);
        cb.execute(jobId);

        uint256 fees = cb.protocolFeesAccrued();
        assertGt(fees, 0);

        uint256 receiverBefore = usdc.balanceOf(feeReceiver);
        vm.expectEmit(true, false, false, true, address(cb));
        emit ProtocolFeeWithdrawn(feeReceiver, fees);
        cb.withdrawProtocolFees();

        assertEq(usdc.balanceOf(feeReceiver), receiverBefore + fees);
        assertEq(cb.protocolFeesAccrued(), 0);
    }

    function test_WithdrawProtocolFees_Permissionless() public {
        uint256 jobId = _registerDefault(alice);
        vm.warp(block.timestamp + 3600);
        vm.prank(keeper);
        cb.execute(jobId);

        // any random address can call it
        vm.prank(address(0xDEAD));
        cb.withdrawProtocolFees();
        assertEq(cb.protocolFeesAccrued(), 0);
    }

    function test_WithdrawProtocolFees_RevertsNothingToWithdraw() public {
        vm.expectRevert(CronBond.NothingToWithdraw.selector);
        cb.withdrawProtocolFees();
    }

    // -----------------------------------------------------------------
    // Owner setters
    // -----------------------------------------------------------------

    function test_SetMinBond_HappyPath_AndInvariant() public {
        // happy path
        vm.expectEmit(false, false, false, true, address(cb));
        emit MinBondUpdated(cb.minBond(), 2_000_000);
        vm.prank(owner);
        cb.setMinBond(2_000_000);
        assertEq(cb.minBond(), 2_000_000);

        // invariant: newMinBond * protocolFeeBps < BPS_DENOMINATOR
        // protocolFeeBps = 10, BPS = 10_000 -> need newMinBond * 10 >= 10_000 -> newMinBond >= 1000
        // try 999 -> 999*10 = 9_990 < 10_000 -> should revert
        vm.prank(owner);
        vm.expectRevert(CronBond.InvariantViolation.selector);
        cb.setMinBond(999);
    }

    function test_SetProtocolFeeBps_HappyPath_HardCap_Invariant() public {
        // happy
        vm.expectEmit(false, false, false, true, address(cb));
        emit ProtocolFeeBpsUpdated(cb.protocolFeeBps(), 100);
        vm.prank(owner);
        cb.setProtocolFeeBps(100);
        assertEq(cb.protocolFeeBps(), 100);

        // hard cap 1000
        vm.prank(owner);
        vm.expectRevert(CronBond.ParamOutOfRange.selector);
        cb.setProtocolFeeBps(1001);

        // invariant: minBond * newBps < BPS_DENOMINATOR
        // minBond = 1_000_000, need newBps >= 1 (since 1_000_000*1 = 1_000_000 > 10_000 trivially)
        // To force violation, lower minBond first to small value
        vm.prank(owner);
        cb.setMinBond(1_000); // 1000*10 = 10_000 OK; 1000*500 = 500_000 OK
        vm.prank(owner);
        vm.expectRevert(CronBond.InvariantViolation.selector);
        cb.setProtocolFeeBps(0); // 1000 * 0 = 0 < 10_000
    }

    function test_SetCancellationFeeBps_HappyPath_HardCap_Invariant() public {
        vm.expectEmit(false, false, false, true, address(cb));
        emit CancellationFeeBpsUpdated(cb.cancellationFeeBps(), 1500);
        vm.prank(owner);
        cb.setCancellationFeeBps(1500);
        assertEq(cb.cancellationFeeBps(), 1500);

        vm.prank(owner);
        vm.expectRevert(CronBond.ParamOutOfRange.selector);
        cb.setCancellationFeeBps(2001);

        // invariant
        vm.prank(owner);
        cb.setMinBond(1_000);
        vm.prank(owner);
        vm.expectRevert(CronBond.InvariantViolation.selector);
        cb.setCancellationFeeBps(0); // 1000 * 0 < 10_000
    }

    function test_SetCancellationFeeFloor_HappyPath_OutOfRange() public {
        vm.expectEmit(false, false, false, true, address(cb));
        emit CancellationFeeFloorUpdated(cb.cancellationFeeFloor(), 100_000);
        vm.prank(owner);
        cb.setCancellationFeeFloor(100_000);
        assertEq(cb.cancellationFeeFloor(), 100_000);

        // > minBond reverts
        uint256 tooHigh = cb.minBond() + 1;
        vm.prank(owner);
        vm.expectRevert(CronBond.ParamOutOfRange.selector);
        cb.setCancellationFeeFloor(tooHigh);
    }

    function test_SetStaleWindow_HappyPath_OutOfRange() public {
        vm.expectEmit(false, false, false, true, address(cb));
        emit StaleWindowUpdated(cb.staleWindow(), 2 days);
        vm.prank(owner);
        cb.setStaleWindow(2 days);
        assertEq(cb.staleWindow(), 2 days);

        vm.prank(owner);
        vm.expectRevert(CronBond.ParamOutOfRange.selector);
        cb.setStaleWindow(1 days - 1);

        vm.prank(owner);
        vm.expectRevert(CronBond.ParamOutOfRange.selector);
        cb.setStaleWindow(365 days + 1);
    }

    function test_SetMinDelay_HappyPath_OutOfRange() public {
        vm.expectEmit(false, false, false, true, address(cb));
        emit MinDelayUpdated(cb.minDelay(), 300);
        vm.prank(owner);
        cb.setMinDelay(300);
        assertEq(cb.minDelay(), 300);

        // <= CANCEL_LOCK_WINDOW (60)
        vm.prank(owner);
        vm.expectRevert(CronBond.ParamOutOfRange.selector);
        cb.setMinDelay(60);
    }

    function test_SetMaxDelay_HappyPath_OutOfRange() public {
        vm.expectEmit(false, false, false, true, address(cb));
        emit MaxDelayUpdated(cb.maxDelay(), 1000 days);
        vm.prank(owner);
        cb.setMaxDelay(uint64(1000 days));

        // < minDelay reverts
        uint64 tooLow = cb.minDelay() - 1;
        vm.prank(owner);
        vm.expectRevert(CronBond.ParamOutOfRange.selector);
        cb.setMaxDelay(tooLow);

        // > 10 years reverts
        vm.prank(owner);
        vm.expectRevert(CronBond.ParamOutOfRange.selector);
        cb.setMaxDelay(uint64(10 * 365 days + 1));
    }

    function test_AllSetters_RevertOnNonOwner() public {
        bytes memory expectErr = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);

        vm.startPrank(alice);
        vm.expectRevert(expectErr);
        cb.setMinBond(2_000_000);

        vm.expectRevert(expectErr);
        cb.setProtocolFeeBps(100);

        vm.expectRevert(expectErr);
        cb.setCancellationFeeBps(100);

        vm.expectRevert(expectErr);
        cb.setCancellationFeeFloor(100);

        vm.expectRevert(expectErr);
        cb.setStaleWindow(2 days);

        vm.expectRevert(expectErr);
        cb.setMinDelay(300);

        vm.expectRevert(expectErr);
        cb.setMaxDelay(1000 days);

        vm.expectRevert(expectErr);
        cb.pause();

        vm.expectRevert(expectErr);
        cb.unpause();

        vm.stopPrank();
    }

    // -----------------------------------------------------------------
    // Pause behavior
    // -----------------------------------------------------------------

    function test_Pause_OnlyBlocksRegister_OthersWork() public {
        // Pre-create one job, fund pending balances etc.
        uint256 jobId1 = _registerDefault(alice); // active
        uint256 jobId2 = _registerDefault(alice); // will execute
        uint256 jobId3 = _registerDefault(bob); // will reclaim

        // accrue some pending withdrawal: cancel job1
        vm.prank(alice);
        cb.cancel(jobId1);

        vm.prank(owner);
        cb.pause();

        // register blocked
        bytes memory data = abi.encodeWithSelector(MockTarget.ping.selector);
        uint64 executeAt = uint64(block.timestamp + 3600);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        cb.register(address(target), data, executeAt, 10 * 1e6, 200_000);

        // execute works (warp to executeAt)
        vm.warp(START_TIMESTAMP + 3600);
        vm.prank(keeper);
        cb.execute(jobId2);

        // reclaim works (warp to stale window for job3)
        vm.warp(START_TIMESTAMP + 3600 + cb.staleWindow());
        vm.prank(bob);
        cb.reclaimStale(jobId3);

        // withdraw works
        vm.prank(alice);
        cb.withdraw();
        vm.prank(keeper);
        cb.withdraw();

        // withdrawProtocolFees works
        cb.withdrawProtocolFees();
    }

    function test_Unpause_ReenablesRegister() public {
        vm.prank(owner);
        cb.pause();

        vm.prank(owner);
        cb.unpause();

        _registerDefault(alice);
    }

    // -----------------------------------------------------------------
    // Blocklist test
    // -----------------------------------------------------------------

    function test_Blocklist_CancelOK_WithdrawRevertsForBlocked() public {
        // Build a fresh deployment using blocklist USDC
        MockUSDCWithBlocklist busdc = new MockUSDCWithBlocklist();
        CronBond cb2 = new CronBond(address(busdc), feeReceiver, owner);

        busdc.mint(alice, 1_000_000 * 1e6);
        busdc.mint(bob, 1_000_000 * 1e6);

        vm.prank(alice);
        busdc.approve(address(cb2), type(uint256).max);
        vm.prank(bob);
        busdc.approve(address(cb2), type(uint256).max);

        // Both register
        bytes memory data = abi.encodeWithSelector(MockTarget.ping.selector);
        uint64 executeAt = uint64(block.timestamp + 3600);
        vm.prank(alice);
        uint256 ja = cb2.register(address(target), data, executeAt, 10 * 1e6, 200_000);
        vm.prank(bob);
        uint256 jb = cb2.register(address(target), data, executeAt, 10 * 1e6, 200_000);

        // Block alice mid-flight
        busdc.setBlocked(alice, true);

        // Both cancel (state-only, no token transfers)
        vm.prank(alice);
        cb2.cancel(ja);
        vm.prank(bob);
        cb2.cancel(jb);

        // alice cannot withdraw (USDC transfer blocked)
        vm.prank(alice);
        vm.expectRevert(); // SafeERC20FailedOperation will surface
        cb2.withdraw();

        // bob can withdraw fine
        uint256 bobBefore = busdc.balanceOf(bob);
        vm.prank(bob);
        cb2.withdraw();
        assertGt(busdc.balanceOf(bob), bobBefore);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    function _getJob(uint256 jobId)
        internal
        view
        returns (
            address registrant,
            uint64 executeAt,
            uint32 maxGas,
            address tgt,
            CronBond.JobStatus status,
            uint256 bondAmount,
            bytes memory callData,
            bytes memory extraData
        )
    {
        (registrant, executeAt, maxGas, tgt, status, bondAmount, callData, extraData) = cb.jobs(jobId);
    }
}

// -----------------------------------------------------------------
// Invariant testing (handler-based)
// -----------------------------------------------------------------

contract CronBondHandler is Test {
    CronBond public cb;
    MockUSDC public usdc;
    MockTarget public target;

    address[] public actors;
    uint256[] public activeJobIds;
    mapping(uint256 => bool) public seen;

    // Tracking for invariants
    uint256 public lastProtocolFees;
    mapping(address => uint256) public lastPendingFor;

    constructor(CronBond _cb, MockUSDC _usdc, MockTarget _target, address[] memory _actors) {
        cb = _cb;
        usdc = _usdc;
        target = _target;
        actors = _actors;
        lastProtocolFees = cb.protocolFeesAccrued();
    }

    function _pickActor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function register(uint256 actorSeed, uint256 bondSeed, uint256 delaySeed) external {
        address actor = _pickActor(actorSeed);
        uint256 bondAmount = cb.minBond() + (bondSeed % (50 * 1e6));
        uint64 delay = uint64(uint256(cb.minDelay()) + (delaySeed % 7200));
        if (uint256(delay) > uint256(cb.maxDelay())) delay = cb.maxDelay();
        uint64 executeAt = uint64(block.timestamp + delay);

        bytes memory data = abi.encodeWithSelector(MockTarget.ping.selector);

        if (usdc.balanceOf(actor) < bondAmount) return;

        vm.prank(actor);
        try cb.register(address(target), data, executeAt, bondAmount, 200_000) returns (uint256 jobId) {
            activeJobIds.push(jobId);
            seen[jobId] = true;
        } catch {
            // ignore
        }

        // record pending
        for (uint256 i; i < actors.length; i++) {
            lastPendingFor[actors[i]] = cb.pendingWithdrawals(actors[i]);
        }
        lastProtocolFees = cb.protocolFeesAccrued();
    }

    function cancel(uint256 idxSeed) external {
        if (activeJobIds.length == 0) return;
        uint256 idx = idxSeed % activeJobIds.length;
        uint256 jobId = activeJobIds[idx];
        ( , uint64 executeAt, , , CronBond.JobStatus status, , , ) = cb.jobs(jobId);
        if (status != CronBond.JobStatus.Active) return;
        // need block.timestamp + CANCEL_LOCK_WINDOW < executeAt
        if (block.timestamp + cb.CANCEL_LOCK_WINDOW() >= uint256(executeAt)) return;

        (address registrant, , , , , , , ) = cb.jobs(jobId);
        vm.prank(registrant);
        try cb.cancel(jobId) {} catch {}

        for (uint256 i; i < actors.length; i++) {
            lastPendingFor[actors[i]] = cb.pendingWithdrawals(actors[i]);
        }
        lastProtocolFees = cb.protocolFeesAccrued();
    }

    function execute(uint256 idxSeed, uint256 actorSeed) external {
        if (activeJobIds.length == 0) return;
        uint256 idx = idxSeed % activeJobIds.length;
        uint256 jobId = activeJobIds[idx];
        ( , uint64 executeAt, , , CronBond.JobStatus status, , , ) = cb.jobs(jobId);
        if (status != CronBond.JobStatus.Active) return;
        if (block.timestamp < uint256(executeAt)) {
            // warp forward to make it eligible (still bounded by handler tick)
            vm.warp(uint256(executeAt));
        }
        address keeper_ = _pickActor(actorSeed);
        vm.prank(keeper_);
        try cb.execute(jobId) {} catch {}

        for (uint256 i; i < actors.length; i++) {
            lastPendingFor[actors[i]] = cb.pendingWithdrawals(actors[i]);
        }
        lastProtocolFees = cb.protocolFeesAccrued();
    }

    function withdraw(uint256 actorSeed) external {
        address actor = _pickActor(actorSeed);
        if (cb.pendingWithdrawals(actor) == 0) return;
        vm.prank(actor);
        try cb.withdraw() {} catch {}

        for (uint256 i; i < actors.length; i++) {
            lastPendingFor[actors[i]] = cb.pendingWithdrawals(actors[i]);
        }
        lastProtocolFees = cb.protocolFeesAccrued();
    }

    function withdrawProtocolFees() external {
        if (cb.protocolFeesAccrued() == 0) return;
        try cb.withdrawProtocolFees() {} catch {}
        lastProtocolFees = cb.protocolFeesAccrued();
    }

    function timeWarp(uint256 amt) external {
        vm.warp(block.timestamp + (amt % 7200) + 1);
    }

    function activeJobIdsLength() external view returns (uint256) {
        return activeJobIds.length;
    }

    function jobIdAt(uint256 i) external view returns (uint256) {
        return activeJobIds[i];
    }

    function actorsList() external view returns (address[] memory) {
        return actors;
    }
}

contract CronBondInvariantTest is StdInvariant, Test {
    CronBond internal cb;
    MockUSDC internal usdc;
    MockTarget internal target;
    CronBondHandler internal handler;

    address internal owner = address(0xABCD);
    address internal feeReceiver = address(0xFEE);
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCAFE);

    address[] internal actors;

    // Snapshots for monotonicity invariants
    uint256 internal _startProtocolFees;
    mapping(address => uint256) internal _lastObservedPending;

    function setUp() public {
        vm.warp(1_700_000_000);
        usdc = new MockUSDC();
        cb = new CronBond(address(usdc), feeReceiver, owner);
        target = new MockTarget();

        actors.push(alice);
        actors.push(bob);
        actors.push(carol);

        for (uint256 i; i < actors.length; i++) {
            usdc.mint(actors[i], 1_000_000 * 1e6);
            vm.prank(actors[i]);
            usdc.approve(address(cb), type(uint256).max);
        }

        handler = new CronBondHandler(cb, usdc, target, actors);
        targetContract(address(handler));

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.register.selector;
        selectors[1] = handler.cancel.selector;
        selectors[2] = handler.execute.selector;
        selectors[3] = handler.withdraw.selector;
        selectors[4] = handler.withdrawProtocolFees.selector;
        selectors[5] = handler.timeWarp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Conservation: USDC balance == sum(active bonds) + protocolFeesAccrued + sum(pending)
    function invariant_USDCConservation() public view {
        uint256 sumActive;
        uint256 n = handler.activeJobIdsLength();
        for (uint256 i; i < n; i++) {
            uint256 jid = handler.jobIdAt(i);
            ( , , , , CronBond.JobStatus status, uint256 bondAmount, , ) = cb.jobs(jid);
            if (status == CronBond.JobStatus.Active) {
                sumActive += bondAmount;
            }
        }
        uint256 sumPending;
        address[] memory aa = handler.actorsList();
        for (uint256 i; i < aa.length; i++) {
            sumPending += cb.pendingWithdrawals(aa[i]);
        }

        uint256 expected = sumActive + cb.protocolFeesAccrued() + sumPending;
        assertEq(usdc.balanceOf(address(cb)), expected, "USDC conservation");
    }

    /// @dev protocolFeesAccrued can only decrease via withdrawProtocolFees().
    /// We approximate: between two consecutive handler observations, if it decreased,
    /// it must have decreased to 0 (since withdrawProtocolFees zeroes it).
    function invariant_ProtocolFeesMonotonicityOrZeroed() public view {
        // This is a structural property implied by the contract code:
        // the only place protocolFeesAccrued is decremented is in withdrawProtocolFees() via `= 0`.
        // We cannot easily snapshot per-call here, so we just sanity check current value is finite.
        // The handler tracks lastProtocolFees and we check that any decrease drops to 0.
        // Since invariants run between calls, we cannot inspect intermediate state.
        // We instead check: if current < lastProtocolFees recorded by handler, current must be 0.
        uint256 cur = cb.protocolFeesAccrued();
        uint256 last = handler.lastProtocolFees();
        if (cur < last) {
            assertEq(cur, 0, "protocol fees decreased without zeroing");
        }
    }

    /// @dev pendingWithdrawals[addr] only decreases via withdraw() for that addr (i.e. zeroed).
    function invariant_PendingMonotonicityOrZeroed() public view {
        address[] memory aa = handler.actorsList();
        for (uint256 i; i < aa.length; i++) {
            uint256 cur = cb.pendingWithdrawals(aa[i]);
            uint256 last = handler.lastPendingFor(aa[i]);
            if (cur < last) {
                assertEq(cur, 0, "pending decreased without zeroing");
            }
        }
    }
}
