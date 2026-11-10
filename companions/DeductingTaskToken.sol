// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {TaskToken} from "../contracts/TaskToken.sol";
import {SettlementDeductionPolicy} from "settlement-deductions/SettlementDeductionPolicy.sol";
import {ITaxSchedule} from "settlement-deductions/interfaces/ITaxSchedule.sol";

/// @title  DeductingTaskToken — an ERC-8414 task contract with a settlement deduction
///         policy (EXPERIMENTAL companion).
/// @notice Deploys the reference SettlementDeductionPolicy (tax, referral fees, repayments —
///         see the settlement-deductions repository) and names it for life. Everything else
///         is the unchanged kernel; the kernel credits the policy and the policy withdraws
///         through the kernel's existing creditOf / withdrawCredit.
///
///         Kept as thin as possible: the kernel sits near the 24,576-byte contract size
///         limit. For the same reason there is no getter: the policy's address is announced
///         once, at construction (DeductionPolicyDeployed), and the policy names this
///         contract back (escrow()).
contract DeductingTaskToken is TaskToken {
    SettlementDeductionPolicy private immutable deductionPolicy;

    event DeductionPolicyDeployed(address indexed policy);

    constructor(string memory name_, string memory symbol_,
                ITaxSchedule schedule, uint16 maxDeductionBps)
        TaskToken(name_, symbol_)
    {
        deductionPolicy = new SettlementDeductionPolicy(address(this), schedule, maxDeductionBps);
        emit DeductionPolicyDeployed(address(deductionPolicy));
    }

    function _deductionPolicy() internal view override returns (address) {
        return address(deductionPolicy);
    }
}
