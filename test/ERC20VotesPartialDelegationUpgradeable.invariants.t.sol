// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console2} from "forge-std/Test.sol";
import {FakeERC20VotesPartialDelegationUpgradeable} from "./fakes/FakeERC20VotesPartialDelegationUpgradeable.sol";
import {Handler} from "./Handler.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract ERC20VotesPartialDelegationUpgradeableInvariants is Test {
  Handler public handler;
  FakeERC20VotesPartialDelegationUpgradeable tokenImpl;
  FakeERC20VotesPartialDelegationUpgradeable tokenProxy;

  function setUp() public virtual {
    tokenImpl = new FakeERC20VotesPartialDelegationUpgradeable();
    tokenProxy = FakeERC20VotesPartialDelegationUpgradeable(address(new ERC1967Proxy(address(tokenImpl), "")));
    tokenProxy.initialize();
    handler = new Handler(tokenImpl, tokenProxy);
    vm.label(address(handler), "Handler contract");

    bytes4[] memory selectors = new bytes4[](9);
    selectors[0] = Handler.handler_mint.selector;
    selectors[1] = Handler.handler_mintAndDelegateSingle.selector;
    selectors[2] = Handler.handler_mintAndDelegateMulti.selector;
    selectors[3] = Handler.handler_redelegate.selector;
    selectors[4] = Handler.handler_undelegate.selector;
    selectors[5] = Handler.handler_validNonZeroTransferToNonDelegator.selector;
    selectors[6] = Handler.handler_validNonZeroTransferToDelegator.selector;
    selectors[7] = Handler.handler_invalidTransfer.selector;
    selectors[8] = Handler.handler_invalidDelegation.selector;
    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

    targetContract(address(handler));
  }

  // Invariants

  function invariant_SumOfBalancesEqualsTotalSupply() public {
    uint256 _sumOfBalances = handler.reduceHolders(0, this.accumulateBalances);
    assertEq(_sumOfBalances, tokenProxy.totalSupply(), "sum of balances does not equal total supply");
  }

  function invariant_SumOfVotesPlusRemainderVotesPlusSumOfNonDelegateBalancesEqualsTotalSupply() public {
    uint256 _sumOfVotes = handler.reduceDelegatees(0, this.accumulateVotes);
    uint256 _sumOfRemainders = handler.reduceDelegators(0, this.accumulateRemainders);
    uint256 _sumOfNonDelegateBalances = handler.reduceNonDelegators(0, this.accumulateBalances);
    assertEq(
      _sumOfVotes + _sumOfRemainders + _sumOfNonDelegateBalances,
      tokenProxy.totalSupply(),
      "sum of votes plus undelegated remainders plus sum of non-delegate balances does not equal total supply"
    );
  }

  function invariant_SumOfVotesPlusRemainderVotesEqualsSumOfDelegatorBalances() public {
    uint256 _sumOfVotes = handler.reduceDelegatees(0, this.accumulateVotes);
    uint256 _sumOfRemainders = handler.reduceDelegators(0, this.accumulateRemainders);
    uint256 _sumOfDelegatorBalances = handler.reduceDelegators(0, this.accumulateBalances);
    assertEq(
      _sumOfVotes + _sumOfRemainders,
      _sumOfDelegatorBalances,
      "sum of votes plus undelegated remainders does not equal sum of delegator balances"
    );
  }

  function invariant_SumOfVotesEqualsPastTotalSupply() public {
    uint256 blockNum = vm.getBlockNumber();
    vm.roll(blockNum + 1);
    uint256 _sumOfVotes = handler.reduceDelegatees(0, this.accumulateVotes)
      + handler.reduceDelegators(0, this.accumulateRemainders) + handler.reduceNonDelegators(0, this.accumulateBalances);
    assertEq(_sumOfVotes, tokenProxy.getPastTotalSupply(blockNum), "sum of votes does not equal past total supply");
  }

  // Used to see distribution of non-reverting calls
  function invariant_callSummary() external view {
    handler.handler_callSummary();
  }

  function accumulateBalances(uint256 acc, address holder) public view returns (uint256) {
    return acc + tokenProxy.balanceOf(holder);
  }

  function accumulateVotes(uint256 acc, address delegatee) public view returns (uint256) {
    return acc + tokenProxy.getVotes(delegatee);
  }

  function accumulateRemainders(uint256 acc, address delegator) public view returns (uint256) {
    return acc + handler.ghost_delegatorVoteRemainder(delegator);
  }
}
