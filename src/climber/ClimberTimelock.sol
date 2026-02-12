// SPDX-License-Identifier: MIT
// Damn Vulnerable DeFi v4 (https://damnvulnerabledefi.xyz)
pragma solidity =0.8.25;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ClimberTimelockBase} from "./ClimberTimelockBase.sol";
import {ADMIN_ROLE, PROPOSER_ROLE, MAX_TARGETS, MIN_TARGETS, MAX_DELAY} from "./ClimberConstants.sol";
import {
    InvalidTargetsCount,
    InvalidDataElementsCount,
    InvalidValuesCount,
    OperationAlreadyKnown,
    NotReadyForExecution,
    CallerNotTimelock,
    NewDelayAboveMax
} from "./ClimberErrors.sol";

/**
 * @title ClimberTimelock
 * @author
 */
contract ClimberTimelock is ClimberTimelockBase {
    using Address for address;

    /**
     * @notice Initial setup for roles and timelock delay.
     * @param admin address of the account that will hold the ADMIN_ROLE role
     * @param proposer address of the account that will hold the PROPOSER_ROLE role
     */
    constructor(address admin, address proposer) {
        _setRoleAdmin(ADMIN_ROLE, ADMIN_ROLE);
        _setRoleAdmin(PROPOSER_ROLE, ADMIN_ROLE);

        _grantRole(ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, address(this)); // self administration
        _grantRole(PROPOSER_ROLE, proposer);

        delay = 1 hours;
    }

    function schedule(
        address[] calldata targets,
        uint256[] calldata values,
        bytes[] calldata dataElements,
        bytes32 salt
    ) external onlyRole(PROPOSER_ROLE) {
        if (targets.length == MIN_TARGETS || targets.length >= MAX_TARGETS) {
            revert InvalidTargetsCount();
        }

        if (targets.length != values.length) {
            revert InvalidValuesCount();
        }

        if (targets.length != dataElements.length) {
            revert InvalidDataElementsCount();
        }

        bytes32 id = getOperationId(targets, values, dataElements, salt);

        if (getOperationState(id) != OperationState.Unknown) {
            revert OperationAlreadyKnown(id);
        }

        operations[id].readyAtTimestamp = uint64(block.timestamp) + delay;
        operations[id].known = true;
    }

    /**
     * Anyone can execute what's been scheduled via `schedule`
     */
    function execute(address[] calldata targets, uint256[] calldata values, bytes[] calldata dataElements, bytes32 salt)
        external
        payable
    {
        if (targets.length <= MIN_TARGETS) {
            revert InvalidTargetsCount();
        }

        if (targets.length != values.length) {
            revert InvalidValuesCount();
        }

        if (targets.length != dataElements.length) {
            revert InvalidDataElementsCount();
        }

        bytes32 id = getOperationId(targets, values, dataElements, salt);

        // @audit - Critical - Timelock Allows Self-Authorization During Execution
        // The ClimberTimelock.execute() function performs all external calls associated with an operation before validating that the operation is in the ReadyForExecution state.
        // This allows an attacker to include state-mutating timelock calls within the same execution batch, enabling the operation to schedule and authorize itself mid-execution.
        // As a result, an attacker can bypass the intended scheduling and delay mechanism and execute arbitrary privileged actions immediately.
        //
        // - Impact:
        // An attacker can:
        //      - Reduce the timelock delay to zero
        //      - Grant the proposer role to a chosen address
        //      - Schedule the currently executing operation
        //      - Execute arbitrary privileged calls (upgrade a UUPS vault implementation)
        // This enables full protocol takeover and arbitrary asset extraction.
        // In this challenge context, the attacker upgrades the vault implementation and drains all tokens.
        // In a production system, this would result in complete loss of control over the governed contract.
        //
        // - Root cause:
        // ClimberTimelock.execute() follows this structure:
        //  1) Compute operation ID.
        //  2) Perform all external calls in a loop.
        //  3) Only then check whether the operation is ReadyForExecution.
        // This violates the Checks–Effects–Interactions (CEI) pattern.
        // Because the validation occurs after the calls, the batched actions may modify timelock state (delay, roles, scheduling status) such that the final state check passes, even if the operation was not previously scheduled or authorized.
        //
        // - Recommended fix:
        // Reorder logic in ClimberTimelock.execute() to validate operation state before performing any external calls.
        // Specifically, the following check:
        //
        // if (getOperationState(id) != OperationState.ReadyForExecution) {
        //     revert NotReadyForExecution(id);
        // }
        //
        // should occur before executing the batched calls.
        // Optionally:
        // Mark the operation as executed before external calls to reduce reentrancy/state-manipulation surface.
        // Consider separating role administration from executable timelock actions.
        for (uint8 i = 0; i < targets.length; ++i) {
            targets[i].functionCallWithValue(dataElements[i], values[i]);
        }

        if (getOperationState(id) != OperationState.ReadyForExecution) {
            revert NotReadyForExecution(id);
        }

        operations[id].executed = true;
    }

    function updateDelay(uint64 newDelay) external {
        if (msg.sender != address(this)) {
            revert CallerNotTimelock();
        }

        if (newDelay > MAX_DELAY) {
            revert NewDelayAboveMax();
        }

        delay = newDelay;
    }
}
