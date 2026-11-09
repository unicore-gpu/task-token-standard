// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {TaskToken} from "../contracts/TaskToken.sol";
import {ISettlementDeductions} from "../contracts/interfaces/ISettlementDeductions.sol";

/// @notice A public tax schedule: for a reward paid in `asset`, the treasury that
///         receives the tax and the rate in basis points. Read once per tender, at
///         mint, so a later rate change never reaches a tender already minted.
interface ITaxSchedule {
    function taxOf(address asset) external view returns (address treasury, uint16 bps);
}

/// @title  DeductingTaskToken — a TaskToken with a settlement deduction policy (EXPERIMENTAL).
/// @notice Deploys its own SettlementDeductionPolicy and names it for life. Everything
///         else is the unchanged kernel. Kept as thin as possible: the kernel already
///         sits near the 24,576-byte contract size limit, so the rules live in the
///         policy contract, not here. For the same reason there is no getter: the
///         policy's address is announced once, at construction (DeductionPolicyDeployed),
///         and the policy names this contract back (taskToken()).
contract DeductingTaskToken is TaskToken {
    SettlementDeductionPolicy private immutable deductionPolicy;

    event DeductionPolicyDeployed(address indexed policy);

    constructor(string memory name_, string memory symbol_,
                ITaxSchedule schedule, uint16 maxDeductionBps)
        TaskToken(name_, symbol_)
    {
        deductionPolicy = new SettlementDeductionPolicy(schedule, maxDeductionBps);
        emit DeductionPolicyDeployed(address(deductionPolicy));
    }

    function _deductionPolicy() internal view override returns (address) {
        return address(deductionPolicy);
    }
}

/// @title  SettlementDeductionPolicy — tax, premiums and repayments at settlement.
/// @notice Divides each reward before the fulfiller is paid:
///
///           reward 100
///            ├─ tax        (public schedule, locked at mint)    → treasury
///            ├─ premium    (fulfiller's own assignment, a rate)  → insurer
///            ├─ repayment  (fulfiller's own assignment, a sum)   → lender
///            └─ remainder                                        → fulfiller
///
///         Two sources, two consents. The tax belongs to the deployment: its schedule
///         is fixed at construction and snapshotted per tender, so every tender minted
///         on this task contract carries it and nobody can mint around it. Premiums
///         and repayments belong to the fulfiller: only the fulfiller can assign part
///         of its own reward on a tender, and an assignment can never be withdrawn —
///         which is what lets a lender advance money against a won task.
///
///         All deductions together are capped at maxDeductionBps of the reward; a
///         repayment cut by the cap carries over to the fulfiller's next completion.
///         Refunds never reach this policy: a refund is not a payment to the fulfiller.
///
///         The task contract credits the policy one total per settlement; the policy
///         records each recipient's share and pays it out on claim (pull, anyone may
///         trigger it, the money only goes to its recipient).
contract SettlementDeductionPolicy is ISettlementDeductions {
    uint16 public constant BPS = 10_000;
    /// Bounds the work done at settlement, which runs on a fixed gas budget.
    uint256 public constant MAX_ASSIGNMENTS = 4;

    address public immutable taskToken;        // the only caller of the hooks
    ITaxSchedule public immutable taxSchedule; // zero = no tax
    uint16 public immutable maxDeductionBps;   // cap on all deductions together

    struct Tax {
        address treasury;
        uint16 bps;
    }

    /// Either a rate (bps > 0, applied to every reward) or a fixed sum (remaining > 0,
    /// repaid across rewards until exhausted). Never both.
    struct Assignment {
        address recipient;
        uint16 bps;
        uint256 remaining;
    }

    mapping(uint256 => Tax) private _tax;
    mapping(uint256 => address) private _asset; // reward asset, snapshotted at mint
    mapping(uint256 => mapping(address => Assignment[])) private _assignments;
    mapping(uint256 => mapping(address => uint256)) private _owed;

    event TaxLocked(uint256 indexed tokenId, address indexed treasury, uint16 bps);
    event RewardAssigned(uint256 indexed tokenId, address indexed fulfiller,
                         address indexed recipient, uint16 bps, uint256 amount);
    event Deducted(uint256 indexed tokenId, uint256 indexed submissionId,
                   address indexed recipient, uint256 amount);
    event Claimed(uint256 indexed tokenId, address indexed recipient, uint256 amount);

    modifier onlyTaskToken() {
        require(msg.sender == taskToken, "Deductions: not task token");
        _;
    }

    constructor(ITaxSchedule schedule, uint16 maxDeductionBps_) {
        require(maxDeductionBps_ <= BPS, "Deductions: cap above 100%");
        taskToken = msg.sender;
        taxSchedule = schedule;
        maxDeductionBps = maxDeductionBps_;
    }

    // ------------------------------------------------------------------ views
    function taxOf(uint256 tokenId) external view returns (Tax memory) {
        return _tax[tokenId];
    }

    function assignmentsOf(uint256 tokenId, address fulfiller)
        external view returns (Assignment[] memory)
    {
        return _assignments[tokenId][fulfiller];
    }

    /// Deducted for `recipient` on `tokenId` and not yet claimed.
    function owedOf(uint256 tokenId, address recipient) external view returns (uint256) {
        return _owed[tokenId][recipient];
    }

    // ------------------------------------------------------------------ claim
    /// @notice Pay `recipient` what it is owed on `tokenId`. Anyone may call; the money
    ///         only goes to the recipient. Pulls this policy's credit out of the task
    ///         contract first if it is still there.
    function claim(uint256 tokenId, address recipient) external {
        uint256 amount = _owed[tokenId][recipient];
        require(amount > 0, "Deductions: nothing owed");
        _owed[tokenId][recipient] = 0;
        ITaskCredit tt = ITaskCredit(taskToken);
        if (tt.creditOf(tokenId, address(this)) > 0) tt.withdrawCredit(tokenId, address(this));
        emit Claimed(tokenId, recipient, amount);
        address asset = _asset[tokenId];
        bool ok;
        if (asset == address(0)) {
            (ok, ) = payable(recipient).call{value: amount}("");
        } else {
            bytes memory ret;
            (ok, ret) = asset.call(abi.encodeWithSignature("transfer(address,uint256)", recipient, amount));
            ok = ok && (ret.length == 0 || (ret.length >= 32 && abi.decode(ret, (uint256)) != 0));
        }
        require(ok, "Deductions: transfer failed");
    }

    /// Native-asset credit arrives here through withdrawCredit.
    receive() external payable {}

    // ------------------------------------------------------------- assignment
    /// @notice Assign part of the caller's future rewards on `tokenId` to `recipient`:
    ///         a rate (`bps`) for a premium, or a fixed `amount` for a repayment.
    ///         Exactly one of the two is nonzero. Irrevocable.
    function assignReward(uint256 tokenId, address recipient, uint16 bps, uint256 amount) external {
        require(recipient != address(0) && recipient != msg.sender, "Deductions: bad recipient");
        require((bps == 0) != (amount == 0), "Deductions: rate xor amount");
        require(bps <= maxDeductionBps, "Deductions: rate above cap");
        Assignment[] storage list = _assignments[tokenId][msg.sender];
        require(list.length < MAX_ASSIGNMENTS, "Deductions: too many assignments");
        list.push(Assignment(recipient, bps, amount));
        emit RewardAssigned(tokenId, msg.sender, recipient, bps, amount);
    }

    // ------------------------------------------------------------------ hooks
    function onMint(uint256 tokenId, address asset, uint256) external onlyTaskToken {
        _asset[tokenId] = asset;
        if (address(taxSchedule) == address(0)) return;
        (address treasury, uint16 bps) = taxSchedule.taxOf(asset);
        if (bps == 0) return;
        require(treasury != address(0), "Deductions: tax to zero");
        require(bps <= maxDeductionBps, "Deductions: tax above cap");
        _tax[tokenId] = Tax(treasury, bps);
        emit TaxLocked(tokenId, treasury, bps);
    }

    /// Order: tax first, then the fulfiller's assignments in the order made, all
    /// within one budget of maxDeductionBps. Makes no external calls.
    function deductions(uint256 tokenId, uint256 submissionId, address fulfiller, uint256 reward)
        external onlyTaskToken returns (uint256 total)
    {
        uint256 budget = reward * maxDeductionBps / BPS;
        Tax memory tax = _tax[tokenId];
        if (tax.bps > 0) {
            uint256 a = reward * tax.bps / BPS; // <= budget: tax.bps <= cap at mint
            budget -= a;
            total += _record(tokenId, submissionId, tax.treasury, a);
        }
        Assignment[] storage list = _assignments[tokenId][fulfiller];
        for (uint256 k = 0; k < list.length; k++) {
            Assignment storage as_ = list[k];
            uint256 want = as_.bps > 0 ? reward * as_.bps / BPS : as_.remaining;
            uint256 take = want > budget ? budget : want;
            if (as_.bps == 0) as_.remaining -= take;
            budget -= take;
            total += _record(tokenId, submissionId, as_.recipient, take);
        }
    }

    function _record(uint256 tokenId, uint256 submissionId, address to, uint256 amount)
        private returns (uint256)
    {
        if (amount == 0) return 0;
        _owed[tokenId][to] += amount;
        emit Deducted(tokenId, submissionId, to, amount);
        return amount;
    }
}

interface ITaskCredit {
    function creditOf(uint256 tokenId, address account) external view returns (uint256);
    function withdrawCredit(uint256 tokenId, address account) external;
}
