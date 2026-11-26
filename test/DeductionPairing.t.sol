// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {TaskToken} from "../contracts/TaskToken.sol";
import {ITaskTender} from "../contracts/interfaces/ITaskTender.sol";
import {ISettlementCredit, ISettlementVault} from "../contracts/interfaces/ISettlementDeductions.sol";
import {DeductingTaskToken} from "../companions/DeductingTaskToken.sol";
import {SettlementDeductionPolicy} from "settlement-deductions/SettlementDeductionPolicy.sol";
import {Schedule} from "./DeductingTaskToken.t.sol";

/// A token that logs its transfers.
contract LoggedUSD {
    event Transfer(address indexed from, address indexed to, uint256 value);
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) { return _move(msg.sender, to, a); }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        return _move(f, to, a);
    }
    function _move(address f, address to, uint256 a) private returns (bool) {
        balanceOf[f] -= a;
        balanceOf[to] += a;
        emit Transfer(f, to, a);
        return true;
    }
}

/// An acceptance authority that accepts several submissions in one transaction.
contract BatchJudge {
    function acceptAll(TaskToken t, uint256 id, uint256[] calldata sids) external {
        for (uint256 i = 0; i < sids.length; i++) t.acceptFulfillment(id, sids[i]);
    }
}

/// The token-bound task tender kernel emits the Settlement Deductions events itself, while
/// the funds leave from each task's own vault. A reader that knows only that ERC finds the
/// vault with `vaultOf` (section 5, requirement 13) and the asset in the task's terms, and
/// pairs each event with its transfer (requirement 14).
contract DeductionPairingTest is Test {
    DeductingTaskToken t;
    SettlementDeductionPolicy p;
    LoggedUSD usd;
    BatchJudge judge;
    address owner  = address(0xA11CE);
    address pub    = address(0xB0B);
    address funder = address(0xF00D);
    address worker = address(0xCAFE);
    address lender = address(0x10A1);
    uint256 constant U = 1e6;

    function setUp() public {
        Schedule schedule = new Schedule();
        schedule.set(address(0x7EA5), 100); // 1%
        t = new DeductingTaskToken("Task", "TASK", schedule, 5000);
        p = SettlementDeductionPolicy(payable(vm.computeCreateAddress(address(t), 1)));
        usd = new LoggedUSD();
        usd.mint(funder, 1_000 * U);
        judge = new BatchJudge();
    }

    function _task(uint256 reward, uint64 maxC) internal returns (uint256 id) {
        id = t.mintTask(owner, pub, address(judge), sha256("TASK.md"), sha256("root"), "u",
                        ITaskTender.TenderTerms(address(usd), reward, maxC, 0, 0, 0, 0, 7 days));
        vm.startPrank(funder);
        usd.approve(address(t), reward * maxC);
        t.fundTask(id, reward * maxC);
        vm.stopPrank();
    }

    function _is(Vm.Log memory l, bytes32 topic) internal view returns (bool) {
        return l.emitter == address(t) && l.topics[0] == topic;
    }

    /// Pairs each PayoutSettled and PayoutWithdrawn with the first transfer of the asset from
    /// the vault to its recipient, or the PayoutCredited, before the next of either event.
    function _pair(Vm.Log[] memory logs, uint256 id) internal view returns (uint256 paired) {
        address vault = ISettlementVault(address(t)).vaultOf(id);
        address asset = t.tenderTermsOf(id).asset;
        for (uint256 i = 0; i < logs.length; i++) {
            address to;
            uint256 net;
            if (_is(logs[i], ISettlementCredit.PayoutSettled.selector)) {
                to = address(uint160(uint256(logs[i].topics[3])));
                (uint256 amount, uint256 deducted) = abi.decode(logs[i].data, (uint256, uint256));
                net = amount - deducted;
            } else if (_is(logs[i], ISettlementCredit.PayoutWithdrawn.selector)) {
                to = address(uint160(uint256(logs[i].topics[2])));
                net = abi.decode(logs[i].data, (uint256));
            } else {
                continue;
            }
            bool found;
            for (uint256 j = i + 1; j < logs.length && !found; j++) {
                Vm.Log memory l = logs[j];
                if (_is(l, ISettlementCredit.PayoutSettled.selector) || _is(l, ISettlementCredit.PayoutWithdrawn.selector)) break;
                if (l.emitter == asset && l.topics[0] == LoggedUSD.Transfer.selector
                    && address(uint160(uint256(l.topics[1]))) == vault
                    && address(uint160(uint256(l.topics[2]))) == to) {
                    assertEq(abi.decode(l.data, (uint256)), net, "transfer matches the event");
                    found = true;
                } else if (_is(l, ISettlementCredit.PayoutCredited.selector)) {
                    assertEq(abi.decode(l.data, (uint256)), net, "credit matches the event");
                    found = true;
                }
            }
            assertTrue(found, "every event paired");
            paired++;
        }
    }

    function test_vault_is_the_tenders_and_fixed() public {
        uint256 id = _task(100 * U, 1);
        address vault = ISettlementVault(address(t)).vaultOf(id);
        assertTrue(vault != address(t), "the funds are not held by the emitter");
        assertEq(usd.balanceOf(vault), 100 * U);
        assertEq(vault, t.vaultOf(id), "the tender draft's own getter");
    }

    function test_payouts_and_withdrawal_in_one_transaction_pair_from_the_vault() public {
        uint256 id = _task(100 * U, 3);
        vm.prank(worker);
        p.assignPayment(id, lender, 0, 30 * U);
        uint256[] memory sids = new uint256[](3);
        for (uint256 i = 0; i < 3; i++) {
            bytes32 result = sha256(abi.encode(i)); // before the prank: sha256 is a call
            vm.prank(worker);
            sids[i] = t.submitFulfillment(id, result, "r");
        }
        vm.recordLogs();
        judge.acceptAll(t, id, sids);        // nets 69, 99, 99 to one payee (tax 1 each, repayment 30 on the first)
        t.withdrawCredit(id, address(p));    // 3 tax + 30 repayment, from the vault
        assertEq(_pair(vm.getRecordedLogs(), id), 4);
        assertEq(usd.balanceOf(worker), 267 * U);
        assertEq(usd.balanceOf(address(p)), 33 * U);
    }
}
