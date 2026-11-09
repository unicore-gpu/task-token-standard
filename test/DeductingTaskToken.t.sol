// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {TaskToken} from "../contracts/TaskToken.sol";
import {ITaskTender} from "../contracts/interfaces/ITaskTender.sol";
import {HashlockVerifier} from "../contracts/verifiers/HashlockVerifier.sol";
import {DeductingTaskToken, SettlementDeductionPolicy, ITaxSchedule} from "../companions/DeductingTaskToken.sol";
import {ISettlementDeductions} from "../contracts/interfaces/ISettlementDeductions.sol";

contract USD {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function approve(address s, uint256 a) external returns (bool) { allowance[msg.sender][s] = a; return true; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a; balanceOf[f] -= a; balanceOf[to] += a; return true;
    }
}

contract Schedule is ITaxSchedule {
    address public treasury;
    uint16 public bps;
    function set(address t, uint16 b) external { treasury = t; bps = b; }
    function taxOf(address) external view returns (address, uint16) { return (treasury, bps); }
}

contract RejectsEther {
    receive() external payable { revert("no"); }
}


/// Test-only: a TaskToken whose deduction policy is whatever the test plugs in.
contract PluggableTaskToken is TaskToken {
    address public policy;
    constructor(address p) TaskToken("P", "P") { policy = p; }
    function _deductionPolicy() internal view override returns (address) { return policy; }
}

contract RevertingPolicy is ISettlementDeductions {
    function onMint(uint256, address, uint256) external {}
    function deductions(uint256, uint256, address, uint256) external pure returns (uint256) {
        revert("boom");
    }
}

contract GreedyPolicy is ISettlementDeductions {
    function onMint(uint256, address, uint256) external {}
    function deductions(uint256, uint256, address, uint256 reward) external pure returns (uint256) {
        return reward + 1; // more than the reward
    }
}

/// Answers with no return data at all.
contract MutePolicy {
    function onMint(uint256, address, uint256) external {}
    fallback() external {}
}

contract GasHogPolicy is ISettlementDeductions {
    function onMint(uint256, address, uint256) external {}
    function deductions(uint256, uint256, address, uint256) external pure returns (uint256) {
        while (true) {}
        return 0;
    }
}

contract DeductingTaskTokenTest is Test {
    event SettlementDeducted(uint256 indexed tokenId, uint256 indexed submissionId,
                             address indexed policy, uint256 amount);
    event DeductionsSkipped(uint256 indexed tokenId, uint256 indexed submissionId);

    DeductingTaskToken t;
    SettlementDeductionPolicy p;
    Schedule schedule;
    USD usd;
    HashlockVerifier hashlock;

    address owner    = address(0xA11CE);
    address pub      = address(0xB0B);
    address judge    = address(0x1CDE);
    address funder   = address(0xF00D);
    address worker   = address(0xCAFE);
    address treasury = address(0x7EA5);
    address insurer  = address(0x1A5);
    address lender   = address(0x10A1);
    address rando    = address(0xBAD);

    uint256 constant U = 1e6; // one USD in a 6-decimal stablecoin
    bytes32 TD = sha256("TASK.md");
    bytes32 TH = sha256("root");
    bytes32 RES = sha256("deliverable");

    function setUp() public {
        schedule = new Schedule();
        schedule.set(treasury, 100); // 1%
        t = new DeductingTaskToken("Task", "TASK", schedule, 5000); // cap 50%
        p = _policyOf(t);
        usd = new USD();
        hashlock = new HashlockVerifier();
        usd.mint(funder, 1_000 * U);
        vm.deal(funder, 100 ether);
    }

    /// The policy is the first contract the task token creates (its nonce 1).
    function _policyOf(DeductingTaskToken tt) internal pure returns (SettlementDeductionPolicy) {
        return SettlementDeductionPolicy(payable(vm.computeCreateAddress(address(tt), 1)));
    }

    function _terms(address asset, uint256 reward, uint64 maxC)
        internal pure returns (ITaskTender.TenderTerms memory)
    {
        return ITaskTender.TenderTerms(asset, reward, maxC, 0, 0, 0, 0, 7 days);
    }

    function _usdTask(DeductingTaskToken tt, address auth, uint256 reward, uint64 maxC)
        internal returns (uint256 id)
    {
        id = tt.mintTask(owner, pub, auth, TD, TH, "u", _terms(address(usd), reward, maxC));
        vm.startPrank(funder);
        usd.approve(address(tt), reward * maxC);
        tt.fundTask(id, reward * maxC);
        vm.stopPrank();
    }

    function _submit(DeductingTaskToken tt, uint256 id) internal returns (uint256 sid) {
        vm.prank(worker);
        sid = tt.submitFulfillment(id, RES, "r");
    }

    function _claimAll(SettlementDeductionPolicy pp, uint256 id) internal {
        address[3] memory who = [treasury, insurer, lender];
        for (uint256 i = 0; i < 3; i++) {
            if (pp.owedOf(id, who[i]) > 0) pp.claim(id, who[i]);
        }
    }

    // ------------------------------------------------ the design example: 1 / 2 / 30 / 67
    function test_design_example() public {
        uint256 id = _usdTask(t, judge, 100 * U, 1);
        vm.startPrank(worker);
        p.assignReward(id, insurer, 200, 0);     // premium 2%
        p.assignReward(id, lender, 0, 30 * U);   // repay 30
        vm.stopPrank();
        uint256 sid = _submit(t, id);

        vm.expectEmit(true, true, true, true, address(t));
        emit SettlementDeducted(id, sid, address(p), 33 * U);
        vm.prank(judge);
        t.acceptFulfillment(id, sid);

        assertEq(usd.balanceOf(worker), 67 * U, "worker gets the remainder");
        assertEq(t.creditOf(id, address(p)), 33 * U, "one lump credited to the policy");
        assertEq(p.owedOf(id, treasury), 1 * U);
        assertEq(p.owedOf(id, insurer), 2 * U);
        assertEq(p.owedOf(id, lender), 30 * U);

        _claimAll(p, id);
        assertEq(usd.balanceOf(treasury), 1 * U);
        assertEq(usd.balanceOf(insurer), 2 * U);
        assertEq(usd.balanceOf(lender), 30 * U);
        assertEq(usd.balanceOf(t.vaultOf(id)), 0, "vault fully distributed");
        assertEq(usd.balanceOf(address(p)), 0, "policy keeps nothing");
        assertEq(p.assignmentsOf(id, worker)[1].remaining, 0, "loan repaid");
    }

    // ------------------------------------------------ no schedule, no assignment: unchanged
    function test_plain_deployment_pays_in_full() public {
        DeductingTaskToken plain = new DeductingTaskToken("T", "T", ITaxSchedule(address(0)), 5000);
        uint256 id = _usdTask(plain, judge, 100 * U, 1);
        uint256 sid = _submit(plain, id);
        vm.prank(judge);
        plain.acceptFulfillment(id, sid);
        assertEq(usd.balanceOf(worker), 100 * U);
    }

    // ------------------------------------------------ tax is locked at mint
    function test_tax_rate_change_does_not_reach_minted_tender() public {
        uint256 id = _usdTask(t, judge, 100 * U, 1);
        schedule.set(treasury, 900); // 9% after mint
        uint256 sid = _submit(t, id);
        vm.prank(judge);
        t.acceptFulfillment(id, sid);
        assertEq(p.owedOf(id, treasury), 1 * U, "still 1%");
        assertEq(usd.balanceOf(worker), 99 * U);

        uint256 id2 = _usdTask(t, judge, 100 * U, 1); // a new tender sees the new rate
        assertEq(p.taxOf(id2).bps, 900);
    }

    function test_tax_above_cap_blocks_mint() public {
        schedule.set(treasury, 6000);
        vm.expectRevert("Deductions: tax above cap");
        t.mintTask(owner, pub, judge, TD, TH, "u", _terms(address(usd), 100 * U, 1));
    }

    // ------------------------------------------------ cap, and carry-over of a fixed sum
    function test_cap_carries_repayment_to_next_completion() public {
        DeductingTaskToken c = new DeductingTaskToken("T", "T", schedule, 3000); // cap 30%
        SettlementDeductionPolicy pc = _policyOf(c);
        uint256 id = _usdTask(c, judge, 100 * U, 2);
        vm.prank(worker);
        pc.assignReward(id, lender, 0, 50 * U);

        uint256 s1 = _submit(c, id);
        vm.prank(judge);
        c.acceptFulfillment(id, s1);
        assertEq(pc.owedOf(id, treasury), 1 * U);
        assertEq(pc.owedOf(id, lender), 29 * U, "cut by the cap");
        assertEq(usd.balanceOf(worker), 70 * U, "worker keeps at least 70%");

        uint256 s2 = _submit(c, id);
        vm.prank(judge);
        c.acceptFulfillment(id, s2);
        assertEq(pc.owedOf(id, lender), 50 * U, "rest repaid on the next completion");
        assertEq(usd.balanceOf(worker), 70 * U + 78 * U);
        assertEq(pc.assignmentsOf(id, worker)[0].remaining, 0);
    }

    // ------------------------------------------------ all three payout paths deduct
    function test_default_after_window_deducts() public {
        uint256 id = _usdTask(t, judge, 100 * U, 1);
        uint256 sid = _submit(t, id);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(rando);
        t.claimUnjudged(id, sid);
        assertEq(p.owedOf(id, treasury), 1 * U);
        assertEq(usd.balanceOf(worker), 99 * U);
    }

    function test_machine_path_deducts() public {
        uint256 id = _usdTask(t, address(hashlock), 100 * U, 1);
        bytes memory answer = "42";
        bytes32 answerHash = sha256(answer); // hash before prank: sha256 is a precompile call
        bytes32 result = sha256(abi.encodePacked(answer, worker));
        vm.prank(pub);
        hashlock.commitAnswer(address(t), id, answerHash);
        vm.prank(worker);
        uint256 sid = t.submitFulfillment(id, result, "r");
        vm.prank(rando);
        t.settleFulfillment(id, sid, answer);
        assertEq(p.owedOf(id, treasury), 1 * U);
        assertEq(usd.balanceOf(worker), 99 * U);
    }

    // ------------------------------------------------ refunds are never deducted
    function test_refund_not_deducted() public {
        uint256 id = _usdTask(t, judge, 100 * U, 1);
        vm.prank(pub);
        t.cancelTask(id);
        uint256 before = usd.balanceOf(funder);
        vm.prank(funder);
        t.reclaimEscrow(id);
        assertEq(usd.balanceOf(funder) - before, 100 * U);
        assertEq(p.owedOf(id, treasury), 0);
        assertEq(t.creditOf(id, address(p)), 0);
    }

    // ------------------------------------------------ only the fulfiller can assign its own reward
    function test_others_cannot_assign_fulfillers_reward() public {
        uint256 id = _usdTask(t, judge, 100 * U, 1);
        vm.prank(rando);
        p.assignReward(id, lender, 0, 90 * U); // binds rando's rewards, not the worker's
        uint256 sid = _submit(t, id);
        vm.prank(judge);
        t.acceptFulfillment(id, sid);
        assertEq(p.owedOf(id, lender), 0);
        assertEq(usd.balanceOf(worker), 99 * U);
    }

    function test_assignment_rules() public {
        uint256 id = _usdTask(t, judge, 100 * U, 1);
        vm.startPrank(worker);
        vm.expectRevert("Deductions: rate xor amount");
        p.assignReward(id, lender, 0, 0);
        vm.expectRevert("Deductions: rate xor amount");
        p.assignReward(id, lender, 100, 1);
        vm.expectRevert("Deductions: rate above cap");
        p.assignReward(id, lender, 5001, 0);
        vm.expectRevert("Deductions: bad recipient");
        p.assignReward(id, address(0), 100, 0);
        vm.expectRevert("Deductions: bad recipient");
        p.assignReward(id, worker, 100, 0);
        for (uint256 i = 0; i < 4; i++) p.assignReward(id, lender, 0, 1);
        vm.expectRevert("Deductions: too many assignments");
        p.assignReward(id, lender, 0, 1);
        vm.stopPrank();
    }

    // ------------------------------------------------ unreceivable fulfiller: net is credited
    function test_unreceivable_fulfiller_credited_net() public {
        RejectsEther w = new RejectsEther();
        uint256 id = t.mintTask(owner, pub, judge, TD, TH, "u", _terms(address(0), 1 ether, 1));
        vm.prank(funder);
        t.fundTask{value: 1 ether}(id, 1 ether);
        vm.prank(address(w));
        uint256 sid = t.submitFulfillment(id, RES, "r");
        vm.prank(judge);
        t.acceptFulfillment(id, sid);
        assertEq(t.creditOf(id, address(w)), 0.99 ether, "net, not gross");
        assertEq(p.owedOf(id, treasury), 0.01 ether);
        p.claim(id, treasury);
        assertEq(treasury.balance, 0.01 ether);
    }

    // ------------------------------------------------ base kernel: hooks default to nothing
    function test_kernel_default_has_no_deductions() public {
        TaskToken k = new TaskToken("K", "K");
        uint256 id = k.mintTask(owner, pub, judge, TD, TH, "u", _terms(address(0), 1 ether, 1));
        vm.prank(funder);
        k.fundTask{value: 1 ether}(id, 1 ether);
        vm.prank(worker);
        uint256 sid = k.submitFulfillment(id, RES, "r");
        vm.prank(judge);
        k.acceptFulfillment(id, sid);
        assertEq(worker.balance, 1 ether);
    }

    // ------------------------------------------------ a failing policy cannot stall settlement
    function _plugged(address policy) internal returns (PluggableTaskToken k, uint256 id, uint256 sid) {
        k = new PluggableTaskToken(policy);
        id = k.mintTask(owner, pub, judge, TD, TH, "u", _terms(address(0), 1 ether, 1));
        vm.prank(funder);
        k.fundTask{value: 1 ether}(id, 1 ether);
        vm.prank(worker);
        sid = k.submitFulfillment(id, RES, "r");
    }

    function test_reverting_policy_pays_in_full() public {
        (PluggableTaskToken k, uint256 id, uint256 sid) = _plugged(address(new RevertingPolicy()));
        vm.prank(judge);
        k.acceptFulfillment(id, sid);
        assertEq(worker.balance, 1 ether);
    }

    function test_invalid_answer_pays_in_full() public {
        (PluggableTaskToken k, uint256 id, uint256 sid) = _plugged(address(new GreedyPolicy()));
        vm.prank(judge);
        k.acceptFulfillment(id, sid);
        assertEq(worker.balance, 1 ether);
        assertEq(k.creditOf(id, k.policy()), 0);
    }

    function test_gas_hog_policy_pays_in_full() public {
        (PluggableTaskToken k, uint256 id, uint256 sid) = _plugged(address(new GasHogPolicy()));
        vm.prank(judge);
        k.acceptFulfillment(id, sid);
        assertEq(worker.balance, 1 ether);
    }

    // ------------------------------------------------ starving the policy reverts, never skips
    function test_starving_the_policy_reverts() public {
        uint256 id = _usdTask(t, judge, 100 * U, 1);
        vm.prank(worker);
        p.assignReward(id, lender, 0, 30 * U);
        uint256 sid = _submit(t, id);
        vm.warp(block.timestamp + 7 days + 1);
        // just enough gas for everything except the policy's full budget
        (bool ok, ) = address(t).call{gas: 200_000}(abi.encodeCall(t.claimUnjudged, (id, sid)));
        assertFalse(ok, "a starved settlement must not go through without deductions");
        assertEq(t.pendingOf(id), 1);
        t.claimUnjudged(id, sid);
        assertEq(p.owedOf(id, lender), 30 * U, "with enough gas, the lender is repaid");
    }

    // ------------------------------------------------ only the task token drives the policy
    function test_policy_hooks_only_from_task_token() public {
        vm.expectRevert("Deductions: not task token");
        p.onMint(1, address(usd), 1);
        vm.expectRevert("Deductions: not task token");
        p.deductions(1, 1, worker, 100);
        vm.expectRevert("Deductions: nothing owed");
        p.claim(1, treasury);
    }

    function test_mute_policy_pays_in_full() public {
        (PluggableTaskToken k, uint256 id, uint256 sid) = _plugged(address(new MutePolicy()));
        vm.expectEmit(true, true, false, false, address(k));
        emit DeductionsSkipped(id, sid);
        vm.prank(judge);
        k.acceptFulfillment(id, sid);
        assertEq(worker.balance, 1 ether);
    }

    // ------------------------------------------------ worst case fits the policy's gas budget
    function test_max_assignments_fit_gas_budget() public {
        uint256 id = _usdTask(t, judge, 100 * U, 1);
        vm.startPrank(worker);
        p.assignReward(id, insurer, 100, 0);
        p.assignReward(id, address(0x1001), 100, 0);
        p.assignReward(id, lender, 0, 10 * U);
        p.assignReward(id, address(0x1002), 0, 10 * U);
        vm.stopPrank();
        uint256 sid = _submit(t, id);
        vm.prank(judge);
        t.acceptFulfillment(id, sid);
        assertEq(t.creditOf(id, address(p)), 23 * U, "tax 1 + 1 + 1 + 10 + 10, nothing skipped");
        assertEq(usd.balanceOf(worker), 77 * U);
    }

    // ------------------------------------------------ deployability: under the 24,576-byte limit
    function test_policy_is_bound_to_its_task_token() public view {
        assertEq(p.taskToken(), address(t));
    }

    function test_runtime_sizes_deployable() public view {
        assertLe(address(t).code.length, 24_576, "task token");
        assertLe(address(p).code.length, 24_576, "policy");
    }
}
