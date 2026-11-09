// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {TaskToken} from "../contracts/TaskToken.sol";
import {ITaskTender} from "../contracts/interfaces/ITaskTender.sol";
import {ISettlementDeductions, ISettlementCredit} from "../contracts/interfaces/ISettlementDeductions.sol";
import {DeductingTaskToken} from "../companions/DeductingTaskToken.sol";
import {SettlementDeductionPolicy} from "settlement-deductions/SettlementDeductionPolicy.sol";
import {USD, Schedule, PluggableTaskToken} from "./DeductingTaskToken.t.sol";

/// Counts what the kernel asks; takes nothing.
contract CountingPolicy is ISettlementDeductions {
    uint256 public created;
    uint256 public asked;
    address public lastAsset;
    uint256 public lastAmountPerSettlement;
    function onTaskCreated(uint256, address asset, uint256 amountPerSettlement) external {
        created++;
        lastAsset = asset;
        lastAmountPerSettlement = amountPerSettlement;
    }
    function deductions(uint256, uint256, address, uint256) external returns (uint256) {
        asked++;
        return 0;
    }
}

contract TwoWordPolicy {
    function onTaskCreated(uint256, address, uint256) external {}
    function deductions(uint256, uint256, address, uint256) external pure returns (uint256, uint256) {
        return (1, 1);
    }
}

contract LoudPolicy {
    function onTaskCreated(uint256, address, uint256) external {}
    function deductions(uint256, uint256, address, uint256) external pure returns (uint256) {
        assembly { revert(0, 300000) } // revert with ~300 KB of return data
    }
}

/// The ERC-8414 kernel on this branch, checked against the escrow requirements of the
/// Settlement Deductions ERC (section 5), one test per requirement not already pinned
/// down in DeductingTaskToken.t.sol.
contract DeductionConformanceTest is Test {
    DeductingTaskToken t;
    SettlementDeductionPolicy p;
    Schedule schedule;
    USD usd;

    address owner    = address(0xA11CE);
    address pub      = address(0xB0B);
    address judge    = address(0x1CDE);
    address funder   = address(0xF00D);
    address worker   = address(0xCAFE);
    address treasury = address(0x7EA5);
    address insurer  = address(0x1A5);
    address lender   = address(0x10A1);
    address rando    = address(0xBAD);

    uint256 constant U = 1e6;
    bytes32 TD = sha256("TASK.md");
    bytes32 TH = sha256("root");
    bytes32 RES = sha256("deliverable");

    function setUp() public {
        schedule = new Schedule();
        schedule.set(treasury, 100); // 1%
        t = new DeductingTaskToken("Task", "TASK", schedule, 5000);
        p = SettlementDeductionPolicy(payable(vm.computeCreateAddress(address(t), 1)));
        usd = new USD();
        usd.mint(funder, 1_000 * U);
        vm.deal(funder, 100 ether);
    }

    function _terms(address asset, uint256 reward, uint64 maxC)
        internal pure returns (ITaskTender.TenderTerms memory)
    {
        return ITaskTender.TenderTerms(asset, reward, maxC, 0, 0, 0, 0, 7 days);
    }

    function _usdTask(uint256 reward, uint64 maxC) internal returns (uint256 id) {
        id = t.mintTask(owner, pub, judge, TD, TH, "u", _terms(address(usd), reward, maxC));
        vm.startPrank(funder);
        usd.approve(address(t), reward * maxC);
        t.fundTask(id, reward * maxC);
        vm.stopPrank();
    }

    function _submit(TaskToken k, uint256 id) internal returns (uint256 sid) {
        vm.prank(worker);
        sid = k.submitFulfillment(id, RES, "r");
    }

    function _plugged(address policy, uint256 reward, uint64 maxC)
        internal returns (PluggableTaskToken k, uint256 id)
    {
        k = new PluggableTaskToken(policy);
        id = k.mintTask(owner, pub, judge, TD, TH, "u", _terms(address(0), reward, maxC));
        vm.prank(funder);
        k.fundTask{value: reward * maxC}(id, reward * maxC);
    }

    // ------------------------------------------------ 5.2 the policy hears about every task
    function test_task_creation_tells_the_policy() public {
        CountingPolicy c = new CountingPolicy();
        _plugged(address(c), 1 ether, 3);
        assertEq(c.created(), 1);
        assertEq(c.lastAsset(), address(0));
        assertEq(c.lastAmountPerSettlement(), 1 ether);
    }

    // ------------------------------------------------ 5.3 every payout asks, nothing else does
    function test_no_refund_or_rejection_path_asks_the_policy() public {
        CountingPolicy c = new CountingPolicy();
        (PluggableTaskToken k, uint256 id) = _plugged(address(c), 1 ether, 3);
        (bool ok, ) = payable(k.vaultOf(id)).call{value: 2 ether}(""); // an anonymous gift
        assertTrue(ok);

        uint256 s1 = _submit(k, id);
        vm.prank(judge);
        k.rejectFulfillment(id, s1);
        assertEq(c.asked(), 0, "rejection is not a payout");

        uint256 s2 = _submit(k, id);
        vm.prank(judge);
        k.acceptFulfillment(id, s2);
        assertEq(c.asked(), 1, "acceptance is a payout");

        vm.prank(pub);
        k.cancelTask(id);
        vm.prank(funder);
        k.reclaimEscrow(id);
        vm.prank(owner);
        k.reclaimResidual(id);
        assertEq(c.asked(), 1, "reclaims are refunds");
        assertEq(address(k.vaultOf(id)).balance, 0, "everything left the vault");
    }

    // ------------------------------------------------ 5.4 no gas value skips the deductions
    function test_no_gas_value_settles_without_the_deductions() public {
        uint256 id = _usdTask(100 * U, 1);
        vm.prank(worker);
        p.assignPayment(id, lender, 0, 30 * U);
        uint256 sid = _submit(t, id);
        vm.warp(block.timestamp + 7 days + 1);
        uint256 lo = 100_000;
        uint256 hi = 2_000_000;
        assertTrue(_claimWith(id, sid, hi), "a large budget settles");
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_claimWith(id, sid, mid)) hi = mid; else lo = mid;
        }
        for (uint256 g = hi - 1_000; g <= hi + 1_000; g++) _claimWith(id, sid, g);
        // Just below the smallest budget that settles, the refusal is the kernel's own
        // starvation check, not an incidental out-of-gas.
        (bool ok, bytes memory ret) = address(t).call{gas: hi - 1}(abi.encodeCall(t.claimUnjudged, (id, sid)));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSignature("Error(string)", "TaskToken: gas"), "starvation check");
    }

    function _claimWith(uint256 id, uint256 sid, uint256 g) internal returns (bool ok) {
        uint256 snap = vm.snapshotState();
        (ok, ) = address(t).call{gas: g}(abi.encodeCall(t.claimUnjudged, (id, sid)));
        if (ok) assertEq(p.owedOf(id, lender), 30 * U, "settled, so the lender must be in");
        vm.revertToState(snap);
    }

    // ------------------------------------------------ 5.5 invalid answers
    function test_two_word_answer_pays_in_full() public {
        (PluggableTaskToken k, uint256 id) = _plugged(address(new TwoWordPolicy()), 1 ether, 1);
        uint256 sid = _submit(k, id);
        vm.expectEmit(address(k));
        emit ISettlementCredit.DeductionsSkipped(id, sid);
        vm.prank(judge);
        k.acceptFulfillment(id, sid);
        assertEq(worker.balance, 1 ether);
    }

    function test_large_return_data_costs_the_settlement_nothing() public {
        uint256 quiet = _minGasToAccept(address(new TwoWordPolicy()));
        uint256 loud = _minGasToAccept(address(new LoudPolicy()));
        emit log_named_uint("smallest settling budget, two-word policy", quiet);
        emit log_named_uint("smallest settling budget, 300 KB policy ", loud);
        assertLt(loud, quiet + 20_000, "only one word is copied back");
    }

    /// The smallest gas limit with which the judge's acceptance goes through.
    function _minGasToAccept(address policy) internal returns (uint256 hi) {
        (PluggableTaskToken k, uint256 id) = _plugged(policy, 1 ether, 1);
        uint256 sid = _submit(k, id);
        uint256 lo = 100_000;
        hi = 3_000_000;
        while (lo + 1 < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(judge);
            (bool ok, ) = address(k).call{gas: mid}(abi.encodeCall(k.acceptFulfillment, (id, sid)));
            if (ok) assertEq(worker.balance, 1 ether);
            vm.revertToState(snap);
            if (ok) hi = mid; else lo = mid;
        }
    }

    // ------------------------------------------------ 4 and 5.6 the ERC's own events
    function test_events_are_the_ercs() public {
        uint256 id = _usdTask(100 * U, 1);
        uint256 sid = _submit(t, id);
        vm.expectEmit(address(t));
        emit ISettlementCredit.SettlementDeducted(id, sid, address(p), 1 * U);
        vm.prank(judge);
        t.acceptFulfillment(id, sid);
    }

    // ------------------------------------------------ 5.7 withdrawal by anyone, then claims
    function test_a_stranger_withdrawing_the_policys_credit_changes_nothing() public {
        uint256 id = _usdTask(100 * U, 1);
        vm.startPrank(worker);
        p.assignPayment(id, insurer, 200, 0);
        p.assignPayment(id, lender, 0, 30 * U);
        vm.stopPrank();
        uint256 sid = _submit(t, id);
        vm.prank(judge);
        t.acceptFulfillment(id, sid);
        vm.prank(rando);
        t.withdrawCredit(id, address(p)); // permissionless; the money goes to the policy
        assertEq(usd.balanceOf(rando), 0);
        assertEq(t.creditOf(id, address(p)), 0);
        p.claim(id, treasury);
        p.claim(id, insurer);
        p.claim(id, lender);
        assertEq(usd.balanceOf(treasury), 1 * U);
        assertEq(usd.balanceOf(insurer), 2 * U);
        assertEq(usd.balanceOf(lender), 30 * U);
        assertEq(usd.balanceOf(worker), 67 * U);
        assertEq(usd.balanceOf(address(p)), 0, "policy keeps nothing");
    }

    // ------------------------------------------------ no money created or lost
    function test_money_is_conserved_across_payouts_and_reclaim() public {
        uint256 id = _usdTask(100 * U, 3);
        vm.prank(worker);
        p.assignPayment(id, lender, 0, 50 * U);
        for (uint256 i = 0; i < 2; i++) {
            uint256 sid = _submit(t, id);
            vm.prank(judge);
            t.acceptFulfillment(id, sid);
        }
        vm.prank(pub);
        t.cancelTask(id);
        vm.prank(funder);
        t.reclaimEscrow(id);
        p.claim(id, treasury);
        p.claim(id, lender);
        address vault = t.vaultOf(id);
        assertEq(usd.balanceOf(vault), 0, "vault empty");
        assertEq(usd.balanceOf(address(p)), 0, "policy empty");
        assertEq(usd.balanceOf(worker), 200 * U - 2 * U - 50 * U);
        assertEq(usd.balanceOf(lender), 50 * U);
        assertEq(usd.balanceOf(treasury), 2 * U);
        assertEq(usd.balanceOf(funder), 1_000 * U - 200 * U, "the unused third came back whole");
    }
}
