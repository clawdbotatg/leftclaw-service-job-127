// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CronBond
/// @notice Bonded scheduled-execution registry. Registrants lock USDC bonds for jobs,
///         keepers execute when due and earn the bond minus a small protocol fee.
contract CronBond is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------
    // Constants & immutables
    // -----------------------------------------------------------------

    IERC20 public immutable USDC;
    address public immutable PROTOCOL_FEE_RECEIVER;

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint64 public constant CANCEL_LOCK_WINDOW = 60;
    uint32 public constant MAX_GAS_FLOOR = 50_000;
    uint32 public constant MAX_GAS_CEILING = 5_000_000;
    uint256 public constant MAX_CALLDATA_SIZE = 4096;
    uint256 public constant EXECUTION_OVERHEAD = 50_000;

    // -----------------------------------------------------------------
    // Owner-configurable storage
    // -----------------------------------------------------------------

    uint256 public minBond = 1_000_000; // $1.00 USDC (6 decimals)
    uint256 public protocolFeeBps = 10; // 0.10%
    uint256 public cancellationFeeBps = 500; // 5%
    uint256 public cancellationFeeFloor = 50_000; // $0.05 USDC
    uint256 public staleWindow = 604_800; // 7 days
    uint64 public minDelay = 120; // 2 minutes
    uint64 public maxDelay = 157_680_000; // ~5 years

    // -----------------------------------------------------------------
    // Job model
    // -----------------------------------------------------------------

    enum JobStatus {
        Active,
        Executed,
        Cancelled,
        Reclaimed
    }

    struct Job {
        address registrant; // slot 0 (20 bytes)
        uint64 executeAt; // slot 0 (8 bytes)
        uint32 maxGas; // slot 0 (4 bytes)
        address target; // slot 1 (20 bytes)
        JobStatus status; // slot 1 (1 byte)
        uint256 bondAmount;
        bytes callData;
        bytes extraData; // forward-compat for v1; empty in v0
    }

    mapping(uint256 => Job) public jobs;
    uint256 public nextJobId;
    mapping(address => uint256) public pendingWithdrawals;
    uint256 public protocolFeesAccrued;

    // -----------------------------------------------------------------
    // Events
    // -----------------------------------------------------------------

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
    event JobCancelled(
        uint256 indexed jobId, address indexed registrant, uint256 refunded, uint256 cancellationFee
    );
    event JobReclaimedStale(
        uint256 indexed jobId, address indexed registrant, uint256 refunded, uint256 fee
    );
    event ProtocolFeeWithdrawn(address indexed to, uint256 amount);

    event MinBondUpdated(uint256 oldValue, uint256 newValue);
    event ProtocolFeeBpsUpdated(uint256 oldValue, uint256 newValue);
    event CancellationFeeBpsUpdated(uint256 oldValue, uint256 newValue);
    event CancellationFeeFloorUpdated(uint256 oldValue, uint256 newValue);
    event StaleWindowUpdated(uint256 oldValue, uint256 newValue);
    event MinDelayUpdated(uint64 oldValue, uint64 newValue);
    event MaxDelayUpdated(uint64 oldValue, uint64 newValue);

    // -----------------------------------------------------------------
    // Custom errors
    // -----------------------------------------------------------------

    error BannedTarget();
    error ZeroTarget();
    error CalldataTooLarge();
    error BondBelowMin();
    error ExecuteAtTooSoon();
    error ExecuteAtTooFar();
    error MaxGasOutOfRange();
    error InsufficientGas();
    error JobNotActive();
    error NotRegistrant();
    error NotYetExecutable();
    error CancelWindowClosed();
    error NotStaleYet();
    error NothingToWithdraw();
    error ParamOutOfRange();
    error InvariantViolation();

    // -----------------------------------------------------------------
    // Constructor
    // -----------------------------------------------------------------

    constructor(address usdc, address feeReceiver, address initialOwner) Ownable(initialOwner) {
        USDC = IERC20(usdc);
        PROTOCOL_FEE_RECEIVER = feeReceiver;
    }

    // -----------------------------------------------------------------
    // Registrant: register
    // -----------------------------------------------------------------

    function register(
        address target,
        bytes calldata callData,
        uint64 executeAt,
        uint256 bondAmount,
        uint32 maxGas
    ) external whenNotPaused returns (uint256) {
        if (target == address(this)) revert BannedTarget();
        if (target == address(0)) revert ZeroTarget();
        if (callData.length > MAX_CALLDATA_SIZE) revert CalldataTooLarge();
        if (bondAmount < minBond) revert BondBelowMin();
        if (executeAt < block.timestamp + minDelay) revert ExecuteAtTooSoon();
        if (executeAt > block.timestamp + maxDelay) revert ExecuteAtTooFar();
        if (maxGas < MAX_GAS_FLOOR || maxGas > MAX_GAS_CEILING) revert MaxGasOutOfRange();

        USDC.safeTransferFrom(msg.sender, address(this), bondAmount);

        uint256 jobId = nextJobId++;
        Job storage j = jobs[jobId];
        j.registrant = msg.sender;
        j.executeAt = executeAt;
        j.maxGas = maxGas;
        j.target = target;
        j.status = JobStatus.Active;
        j.bondAmount = bondAmount;
        j.callData = callData;
        // extraData defaults to empty bytes in v0

        emit JobRegistered(
            jobId, msg.sender, target, executeAt, bondAmount, maxGas, keccak256(callData)
        );

        return jobId;
    }

    // -----------------------------------------------------------------
    // Keeper: execute
    // -----------------------------------------------------------------

    function execute(uint256 jobId) external nonReentrant returns (bool) {
        Job storage job = jobs[jobId];

        if (job.status != JobStatus.Active) revert JobNotActive();
        if (block.timestamp < job.executeAt) revert NotYetExecutable();
        if (gasleft() < uint256(job.maxGas) + EXECUTION_OVERHEAD) revert InsufficientGas();

        uint256 fee = (job.bondAmount * protocolFeeBps) / BPS_DENOMINATOR;
        uint256 payout = job.bondAmount - fee;

        // CEI: state changes BEFORE external call
        job.status = JobStatus.Executed;
        protocolFeesAccrued += fee;
        pendingWithdrawals[msg.sender] += payout;

        // Cache before-call state we need locally
        address target = job.target;
        uint32 gasCap = job.maxGas;
        bytes memory data = job.callData;
        bytes32 cdHash = keccak256(data);

        uint256 gasStart = gasleft();
        (bool success,) = target.call{gas: gasCap}(data);
        uint64 gasUsed = uint64(gasStart - gasleft());

        emit JobExecuted(jobId, msg.sender, success, cdHash, payout, gasUsed);
        return success;
    }

    // -----------------------------------------------------------------
    // Registrant: cancel
    // -----------------------------------------------------------------

    function cancel(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];

        if (job.status != JobStatus.Active) revert JobNotActive();
        if (msg.sender != job.registrant) revert NotRegistrant();
        if (block.timestamp + CANCEL_LOCK_WINDOW >= job.executeAt) revert CancelWindowClosed();

        (uint256 refund, uint256 fee) = _applyCancellationFee(job.bondAmount);

        job.status = JobStatus.Cancelled;
        protocolFeesAccrued += fee;
        pendingWithdrawals[msg.sender] += refund;

        emit JobCancelled(jobId, msg.sender, refund, fee);
    }

    // -----------------------------------------------------------------
    // Registrant: reclaimStale
    // -----------------------------------------------------------------

    function reclaimStale(uint256 jobId) external nonReentrant {
        Job storage job = jobs[jobId];

        if (job.status != JobStatus.Active) revert JobNotActive();
        if (msg.sender != job.registrant) revert NotRegistrant();
        if (block.timestamp < uint256(job.executeAt) + staleWindow) revert NotStaleYet();

        (uint256 refund, uint256 fee) = _applyCancellationFee(job.bondAmount);

        job.status = JobStatus.Reclaimed;
        protocolFeesAccrued += fee;
        pendingWithdrawals[msg.sender] += refund;

        emit JobReclaimedStale(jobId, msg.sender, refund, fee);
    }

    function _applyCancellationFee(uint256 bondAmount)
        internal
        view
        returns (uint256 refund, uint256 fee)
    {
        uint256 pct = (bondAmount * cancellationFeeBps) / BPS_DENOMINATOR;
        fee = pct >= cancellationFeeFloor ? pct : cancellationFeeFloor;
        refund = bondAmount - fee;
    }

    // -----------------------------------------------------------------
    // Pull-pattern withdrawals
    // -----------------------------------------------------------------

    function withdraw() external nonReentrant {
        uint256 amount = pendingWithdrawals[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        pendingWithdrawals[msg.sender] = 0;
        USDC.safeTransfer(msg.sender, amount);
    }

    function withdrawProtocolFees() external {
        uint256 amount = protocolFeesAccrued;
        if (amount == 0) revert NothingToWithdraw();
        protocolFeesAccrued = 0;
        USDC.safeTransfer(PROTOCOL_FEE_RECEIVER, amount);
        emit ProtocolFeeWithdrawn(PROTOCOL_FEE_RECEIVER, amount);
    }

    // -----------------------------------------------------------------
    // Owner functions
    // -----------------------------------------------------------------

    function setMinBond(uint256 newMinBond) external onlyOwner {
        if (
            newMinBond * protocolFeeBps < BPS_DENOMINATOR
                || newMinBond * cancellationFeeBps < BPS_DENOMINATOR
        ) revert InvariantViolation();
        uint256 old = minBond;
        minBond = newMinBond;
        emit MinBondUpdated(old, newMinBond);
    }

    function setProtocolFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > 1000) revert ParamOutOfRange();
        if (minBond * newBps < BPS_DENOMINATOR) revert InvariantViolation();
        uint256 old = protocolFeeBps;
        protocolFeeBps = newBps;
        emit ProtocolFeeBpsUpdated(old, newBps);
    }

    function setCancellationFeeBps(uint256 newBps) external onlyOwner {
        if (newBps > 2000) revert ParamOutOfRange();
        if (minBond * newBps < BPS_DENOMINATOR) revert InvariantViolation();
        uint256 old = cancellationFeeBps;
        cancellationFeeBps = newBps;
        emit CancellationFeeBpsUpdated(old, newBps);
    }

    function setCancellationFeeFloor(uint256 newFloor) external onlyOwner {
        if (newFloor > minBond) revert ParamOutOfRange();
        uint256 old = cancellationFeeFloor;
        cancellationFeeFloor = newFloor;
        emit CancellationFeeFloorUpdated(old, newFloor);
    }

    function setStaleWindow(uint256 newWindow) external onlyOwner {
        if (newWindow < 1 days || newWindow > 365 days) revert ParamOutOfRange();
        uint256 old = staleWindow;
        staleWindow = newWindow;
        emit StaleWindowUpdated(old, newWindow);
    }

    function setMinDelay(uint64 newDelay) external onlyOwner {
        if (newDelay <= CANCEL_LOCK_WINDOW) revert ParamOutOfRange();
        uint64 old = minDelay;
        minDelay = newDelay;
        emit MinDelayUpdated(old, newDelay);
    }

    function setMaxDelay(uint64 newDelay) external onlyOwner {
        if (newDelay < minDelay || newDelay > 10 * 365 days) revert ParamOutOfRange();
        uint64 old = maxDelay;
        maxDelay = newDelay;
        emit MaxDelayUpdated(old, newDelay);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
