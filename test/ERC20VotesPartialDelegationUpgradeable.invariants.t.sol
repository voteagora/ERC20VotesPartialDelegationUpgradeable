// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

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

    bytes4[] memory selectors = new bytes4[](7);
    selectors[0] = Handler.handler_mint.selector;
    selectors[1] = Handler.handler_mintAndDelegateSingle.selector;
    selectors[2] = Handler.handler_mintAndDelegateMulti.selector;
    selectors[3] = Handler.handler_redelegate.selector;
    selectors[4] = Handler.handler_undelegate.selector;
    selectors[5] = Handler.handler_validNonZeroTransferToNonDelegator.selector;
    selectors[6] = Handler.handler_validNonZeroTransferToDelegator.selector;
    targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

    targetContract(address(handler));
  }

  // Invariants

  function invariant_SumOfBalancesEqualsTotalSupply() public {
    uint256 _sumOfBalances = handler.reduceHolders(0, this.accumulateBalances);
    assertEq(_sumOfBalances, tokenProxy.totalSupply(), "sum of balances does not equal total supply");
  }

  function invariant_SumOfVotesPlusSumOfNonDelegateBalancesEqualsTotalSupply() public {
    uint256 _sumOfVotesPlusSumOfNonDelegateBalances =
      handler.reduceDelegatees(0, this.accumulateVotes) + handler.reduceNonDelegators(0, this.accumulateBalances);
    assertEq(
      _sumOfVotesPlusSumOfNonDelegateBalances,
      tokenProxy.totalSupply(),
      "sum of votes plus sum of non-delegate balances does not equal total supply"
    );
  }

  function invariant_SumOfVotesEqualsPastTotalSupply() public {
    uint256 blockNum = vm.getBlockNumber();
    vm.roll(blockNum + 1);
    uint256 _sumOfVotes =
      handler.reduceDelegatees(0, this.accumulateVotes) + handler.reduceNonDelegators(0, this.accumulateBalances);
    assertEq(_sumOfVotes, tokenProxy.getPastTotalSupply(blockNum), "sum of votes does not equal past total supply");
  }

  // Used to see distribution of non-reverting calls
  function invariant_callSummary() external view {
    handler.handler_callSummary();
  }

  function accumulateBalances(uint256 acc, address holder) public view returns (uint256) {
    return acc + tokenProxy.balanceOf(holder);
  }

  function accumulateVotes(uint256 acc, address delegator) public view returns (uint256) {
    return acc + tokenProxy.getVotes(delegator);
  }

  // this sequence originally failed the invariant suite because we were using a "nondelegator" to delegate. We fixed by
  // insisting in the handler that a delegation call would not choose a nondelegator address.
  function test_failedInvariantSequence0() public {
    handler.handler_mintAndDelegateMulti(
      0x000000000000000003E039DF9a15c44618bAbe94,
      1_368_607_983_737_114_171_096_165_722_857_003_722_448_737_526_549,
      13_809_774_740_327_122_930_825_391_953_334_113_695_731_543_212_108_407_090_779_824_671_289_280_260_352
    );
    handler.handler_validNonZeroTransferToNonDelegator(
      109_606_036_096_319_016_917_839_093_649_372_298_999_054_231_802_973_046_257_082_932_217_391_862_368_008,
      692_600_176_643_282_132_292_583_435,
      0x000000000000000001597dadbeedb4caA389875E
    );
    handler.handler_mintAndDelegateSingle(
      0x000000000000000001597dadbeedb4caA389875E,
      1_392_525_594_766_980_135_378_320_930_067_821_030_844_291_681_746,
      0x000000000000000001d29bb080bbCE6bd12Dab32
    );
    invariant_SumOfBalancesEqualsTotalSupply();
    invariant_SumOfVotesEqualsPastTotalSupply();
    invariant_SumOfVotesPlusSumOfNonDelegateBalancesEqualsTotalSupply();
  }
}
