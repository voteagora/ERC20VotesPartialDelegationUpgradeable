// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {console} from "forge-std/console.sol";
import {AddressSet, LibAddressSet} from "./helpers/AddressSet.sol";
import {PartialDelegation, DelegationAdjustment} from "src/IVotesPartialDelegation.sol";
import {FakeERC20VotesPartialDelegationUpgradeable} from "./fakes/FakeERC20VotesPartialDelegationUpgradeable.sol";

contract Handler is CommonBase, StdCheats, StdUtils {
  using LibAddressSet for AddressSet;

  FakeERC20VotesPartialDelegationUpgradeable public tokenImpl;
  FakeERC20VotesPartialDelegationUpgradeable public tokenProxy;

  AddressSet internal _holders;
  AddressSet internal _delegatees;
  AddressSet internal _delegators;
  /// @notice nondelegators are token holders that are not delegators
  AddressSet internal _nondelegators;
  mapping(bytes32 => uint256) public calls;

  // ghost vars
  mapping(address => uint208) public ghost_delegatorVoteRemainder;

  modifier countCall(bytes32 key) {
    calls[key]++;
    _;
  }

  constructor(
    FakeERC20VotesPartialDelegationUpgradeable _tokenImpl,
    FakeERC20VotesPartialDelegationUpgradeable _tokenProxy
  ) {
    tokenImpl = _tokenImpl;
    tokenProxy = _tokenProxy;
  }

  function _boundToNonZeroAddress(address _address) internal pure returns (address) {
    return address(
      uint160(bound(uint256(uint160(_address)), uint256(uint160(address(1))), uint256(uint160(type(uint160).max))))
    );
  }

  function _chooseAddressNotInSet(AddressSet storage _set, address _seed) internal view returns (address) {
    while (_set.contains(_seed)) {
      _seed = address(uint160(uint256(keccak256(abi.encode(_seed)))));
    }
    return _seed;
  }

  function _createActor(AddressSet storage _addressSet) internal returns (address) {
    _addressSet.add(msg.sender);
    return (msg.sender);
  }

  function _useActor(AddressSet storage _set, uint256 _randomActorSeed) internal view returns (address) {
    return _set.rand(_randomActorSeed);
  }

  function _mintToken(address _to, uint256 _amount) internal {
    vm.prank(_to);
    tokenProxy.mint(_amount);
  }

  function _adjustDelegatorRemainder(address _delegator) public {
    (, uint208 _remainder) = _calculateWeightDistributionAndRemainder(
      tokenProxy.delegates(_delegator), uint208(tokenProxy.balanceOf(_delegator))
    );
    ghost_delegatorVoteRemainder[_delegator] = _remainder;
  }

  function _createValidPartialDelegation(uint256 _n, uint256 _seed) internal returns (PartialDelegation[] memory) {
    _seed = bound(
      _seed,
      1,
      /* private key can't be bigger than secp256k1 curve order */
      115_792_089_237_316_195_423_570_985_008_687_907_852_837_564_279_074_904_382_605_163_141_518_161_494_337 - 1
    );
    _n = _n != 0 ? _n : (_seed % tokenProxy.MAX_PARTIAL_DELEGATIONS()) + 1;
    PartialDelegation[] memory delegations = new PartialDelegation[](_n);
    uint96 _totalNumerator;
    for (uint256 i = 0; i < _n; i++) {
      uint96 _numerator = uint96(
        bound(
          uint256(keccak256(abi.encode(_seed + i))) % tokenProxy.DENOMINATOR(),
          1,
          tokenProxy.DENOMINATOR() - _totalNumerator - (_n - i)
        )
      );
      address _delegatee = address(uint160(uint160(vm.addr(_seed)) + i));
      delegations[i] = PartialDelegation(_delegatee, _numerator);
      _delegatees.add(_delegatee);
      _totalNumerator += _numerator;
    }
    return delegations;
  }

  function _calculateWeightDistributionAndRemainder(PartialDelegation[] memory _partialDelegations, uint208 _amount)
    public
    view
    returns (DelegationAdjustment[] memory, uint208)
  {
    DelegationAdjustment[] memory _adjustments =
      tokenProxy.exposed_calculateWeightDistribution(_partialDelegations, _amount);
    uint208 _remainder = _amount;
    for (uint256 i = 0; i < _adjustments.length; i++) {
      _remainder -= _adjustments[i]._amount;
    }
    return (_adjustments, _remainder);
  }

  function handler_mint(address _holder, uint256 _amount) public countCall("handler_mint") {
    _amount = bound(_amount, 1, 100_000_000e18);
    _holder = _boundToNonZeroAddress(_holder);
    _mintToken(_holder, _amount);
    _holders.add(_holder);
    if (!_delegators.contains(_holder)) {
      // holder is also a nondelegator, because there's no delegation
      _nondelegators.add(_holder);
    } else {
      _adjustDelegatorRemainder(_holder);
    }
  }

  function handler_mintAndDelegateSingle(address _holder, uint256 _amount, address _delegatee)
    public
    countCall("handler_mintAndDelegateSingle")
  {
    _amount = bound(_amount, 1, 100_000_000e18);
    _holder = _chooseAddressNotInSet(_nondelegators, _holder);
    _delegatee = _boundToNonZeroAddress(_delegatee);
    _mintToken(_holder, _amount);
    // consider: undelegated vote remainder for a few steps here
    vm.prank(_holder);
    tokenProxy.delegate(_delegatee);
    _holders.add(_holder);
    _delegators.add(_holder);
    _delegatees.add(_delegatee);
    _adjustDelegatorRemainder(_holder);
  }

  function handler_mintAndDelegateMulti(address _holder, uint256 _amount, uint256 _delegationSeed)
    public
    countCall("handler_mintAndDelegateMulti")
  {
    _amount = bound(_amount, 1, 100_000_000e18);
    _holder = _chooseAddressNotInSet(_nondelegators, _holder);
    _mintToken(_holder, _amount);
    // delegatees are added to the set in _createValidPartialDelegation
    PartialDelegation[] memory _delegations = _createValidPartialDelegation(0, _delegationSeed);
    vm.prank(_holder);
    tokenProxy.delegate(_delegations);
    _holders.add(_holder);
    _delegators.add(_holder);
    _adjustDelegatorRemainder(_holder);
  }

  function handler_redelegate(uint256 _actorSeed, uint256 _delegationSeed) public countCall("handler_redelegate") {
    address _delegator = _useActor(_delegators, _actorSeed);
    PartialDelegation[] memory _delegations = _createValidPartialDelegation(0, _delegationSeed);
    vm.prank(_delegator);
    tokenProxy.delegate(_delegations);
    _adjustDelegatorRemainder(_delegator);
  }

  function handler_undelegate(uint256 _actorSeed) public countCall("handler_undelegate") {
    address _holder = _useActor(_delegators, _actorSeed);
    vm.prank(_holder);
    tokenProxy.delegate(address(0));

    // technically address(0) is a delegatee now
    _delegatees.add(address(0));
    // _currentActor is also still technically a delegator delegating to address(0), so we won't add to nondelegates set
    _adjustDelegatorRemainder(_holder);
  }

  function handler_validNonZeroTransferToDelegator(uint256 _amount, uint256 _actorSeed, uint256 _delegatorSeed)
    public
    countCall("validNonZeroTransferToDelegator")
  {
    address _currentActor = _useActor(_holders, _actorSeed);
    _amount = bound(_amount, 0, tokenProxy.balanceOf(_currentActor));
    address _to = _useActor(_delegators, _delegatorSeed);
    vm.prank(_currentActor);
    tokenProxy.transfer(_to, _amount);
    _adjustDelegatorRemainder(_currentActor);
    _adjustDelegatorRemainder(_to);
  }

  function handler_validNonZeroTransferToNonDelegator(uint256 _amount, uint256 _actorSeed, address _to)
    public
    countCall("validNonZeroTransferToNonD")
  {
    address _currentActor = _useActor(_holders, _actorSeed);
    _amount = bound(_amount, 0, tokenProxy.balanceOf(_currentActor));
    _to = _chooseAddressNotInSet(_delegators, _to);
    vm.startPrank(_currentActor);
    tokenProxy.transfer(_to, _amount);
    vm.stopPrank();

    // now, receiving address is a token holder; add them to the set
    _holders.add(_to);
    // we also know they're a nondelegator
    _nondelegators.add(_to);
    _adjustDelegatorRemainder(_currentActor);
  }

  function handler_invalidTransfer(uint256 _amount, address _actor, address _to) public countCall("invalidTransfer") {
    if (uint160(_actor) % 2 == 0) {
      _actor = _useActor(_holders, uint160(_actor));
    }
    _amount = bound(_amount, tokenProxy.balanceOf(_actor) + 1, type(uint256).max);
    _to = _boundToNonZeroAddress(_to);
    vm.prank(_actor);
    // vm.expectRevert();
    tokenProxy.transfer(_to, _amount);
  }

  function handler_invalidDelegation(uint256 _delegationSeed) public countCall("invalidDelegation") {
    PartialDelegation[] memory _delegations =
      _makeDelegationInvalid(_createValidPartialDelegation(0, _delegationSeed), _delegationSeed);
    // vm.expectRevert();
    tokenProxy.delegate(_delegations);
  }

  function _makeDelegationInvalid(PartialDelegation[] memory _delegations, uint256 _seed)
    internal
    view
    returns (PartialDelegation[] memory)
  {
    uint256 _index = _delegations.length % uint256(keccak256(abi.encode(_seed)));
    if (_seed % 3 == 0) {
      // numerator zero
      _delegations[_index]._numerator = 0;
    } else if (_seed % 3 == 1 && _delegations.length > 2) {
      // duplicate delegatee
      address _replacementDelegatee = _index == 0 ? _delegations[1]._delegatee : _delegations[0]._delegatee;
      _delegations[_index]._delegatee = _replacementDelegatee;
    } else {
      // numerators that sum to greater than DENOMINATOR
      uint96 _sum = 0;
      for (uint256 i = 0; i < _delegations.length; i++) {
        _sum += _delegations[i]._numerator;
      }
      _delegations[_index]._numerator = (tokenProxy.DENOMINATOR() - _sum) + uint96(_seed % 100);
    }
    return _delegations;
  }

  function handler_callSummary() external view {
    console.log("\nCall summary:");
    console.log("-------------------");
    console.log("handler_mint", calls["handler_mint"]);
    console.log("handler_mintAndDelegateSingle", calls["handler_mintAndDelegateSingle"]);
    console.log("handler_mintAndDelegateMulti", calls["handler_mintAndDelegateMulti"]);
    console.log("handler_redelegate", calls["handler_redelegate"]);
    console.log("handler_undelegate", calls["handler_undelegate"]);
    console.log("handler_validNonZeroTransferToDelegator", calls["validNonZeroTransferToDelegator"]);
    console.log("handler_validNonZeroTransferToNonDelegator", calls["validNonZeroTransferToNonD"]);
    console.log("handler_invalidTransfer", calls["invalidTransfer"]);
    console.log("handler_invalidDelegation", calls["invalidDelegation"]);
    console.log("-------------------\n");
  }

  function reduceHolders(uint256 _acc, function(uint256, address) external returns (uint) _func)
    external
    returns (uint256)
  {
    return _holders.reduce(_acc, _func);
  }

  function reduceDelegatees(uint256 _acc, function(uint256, address) external returns (uint) _func)
    external
    returns (uint256)
  {
    return _delegatees.reduce(_acc, _func);
  }

  function reduceDelegators(uint256 _acc, function(uint256, address) external returns (uint) _func)
    external
    returns (uint256)
  {
    return _delegators.reduce(_acc, _func);
  }

  function reduceNonDelegators(uint256 _acc, function(uint256, address) external returns (uint) _func)
    external
    returns (uint256)
  {
    return _nondelegators.reduce(_acc, _func);
  }

  receive() external payable {}
}
