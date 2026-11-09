// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title  ISettlementDeductions — the optional settlement exit of a task contract.
/// @notice A deduction policy is fixed for the lifetime of a task contract. The task
///         contract tells it about each new tender (so per-tender terms can be locked)
///         and asks it, at every settlement, how much of the reward it takes. That
///         amount is credited to the policy inside the task contract and withdrawn
///         later with withdrawCredit; the policy divides it among its own recipients.
///         No recipient is ever called on the payout path.
interface ISettlementDeductions {
    /// Called by the task contract at the end of mintTask.
    function onMint(uint256 tokenId, address asset, uint256 rewardPerCompletion) external;

    /// Called by the task contract on every payout path (judged accept, machine settle,
    /// default after the judgment window) with a fixed gas budget. Returns the total
    /// taken out of `reward`; the remainder goes to the fulfiller. A failed call, or an
    /// answer larger than the reward, settles with no deduction — settlement never
    /// stalls on the policy.
    function deductions(uint256 tokenId, uint256 submissionId, address fulfiller, uint256 reward)
        external returns (uint256 total);
}
