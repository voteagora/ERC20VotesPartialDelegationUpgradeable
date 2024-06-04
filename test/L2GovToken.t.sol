// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {L2GovToken} from "../src/L2GovToken.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {PartialDelegation, DelegationAdjustment} from "../src/IVotesPartialDelegation.sol";
import {FakeERC20VotesPartialDelegationUpgradeable} from "./fakes/FakeERC20VotesPartialDelegationUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract L2GovTestPreInit is Test {
  L2GovToken public tokenImpl;
  L2GovToken public tokenProxy;

  function setUp() public virtual {
    tokenImpl = new L2GovToken();
    tokenProxy = L2GovToken(address(new ERC1967Proxy(address(tokenImpl), "")));
  }
}

contract L2GovTest is L2GovTestPreInit {
  event DelegateVotesChanged(address indexed delegate, uint256 previousVotes, uint256 newVotes);

  address admin = makeAddr("admin");
  address minter = makeAddr("minter");
  address burner = makeAddr("burner");

  function setUp() public override {
    super.setUp();
    tokenProxy.initialize(admin);
    vm.startPrank(admin);
    tokenProxy.grantRole(tokenProxy.MINTER_ROLE(), minter);
    tokenProxy.grantRole(tokenProxy.BURNER_ROLE(), burner);
    vm.stopPrank();
  }

  function _createValidPartialDelegation(uint256 _n, uint256 _seed) internal view returns (PartialDelegation[] memory) {
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
          uint256(keccak256(abi.encode(_seed + i))) % tokenProxy.DENOMINATOR(), // initial value of the numerator
          1,
          tokenProxy.DENOMINATOR() - _totalNumerator - (_n - i) // ensure that there is enough numerator left for the
            // remaining delegations
        )
      );
      delegations[i] = PartialDelegation(address(uint160(uint160(vm.addr(_seed)) + i)), _numerator);
      _totalNumerator += _numerator;
    }
    return delegations;
  }

  function _expectEmitDelegateVotesChangedEvents(
    uint256 _amount,
    PartialDelegation[] memory _fromPartialDelegations,
    PartialDelegation[] memory _toPartialDelegations
  ) internal {
    FakeERC20VotesPartialDelegationUpgradeable utils = new FakeERC20VotesPartialDelegationUpgradeable();
    DelegationAdjustment[] memory _initialVotes =
      utils.exposed_calculateWeightDistribution(_fromPartialDelegations, _amount);
    DelegationAdjustment[] memory _votes = utils.exposed_calculateWeightDistribution(_toPartialDelegations, _amount);

    uint256 i;
    uint256 j;
    while (i < _fromPartialDelegations.length || j < _toPartialDelegations.length) {
      // If both delegations have the same delegatee
      if (
        i < _fromPartialDelegations.length && j < _toPartialDelegations.length
          && _fromPartialDelegations[i]._delegatee == _toPartialDelegations[j]._delegatee
      ) {
        // if the numerator is different
        if (_fromPartialDelegations[i]._numerator != _toPartialDelegations[j]._numerator) {
          if (_votes[j]._amount != 0 || _initialVotes[j]._amount != 0) {
            vm.expectEmit();
            emit DelegateVotesChanged(
              _fromPartialDelegations[i]._delegatee, _initialVotes[j]._amount, _votes[j]._amount
            );
          }
        }
        i++;
        j++;
        // Old delegatee comes before the new delegatee OR new delegatees have been exhausted
      } else if (
        j == _toPartialDelegations.length
          || (
            i != _fromPartialDelegations.length
              && _fromPartialDelegations[i]._delegatee < _toPartialDelegations[j]._delegatee
          )
      ) {
        if (_initialVotes[i]._amount != 0) {
          vm.expectEmit();
          emit DelegateVotesChanged(_fromPartialDelegations[i]._delegatee, _initialVotes[i]._amount, 0);
        }
        i++;
        // If new delegatee comes before the old delegatee OR old delegatees have been exhausted
      } else {
        if (_votes[j]._amount != 0) {
          vm.expectEmit();
          emit DelegateVotesChanged(_toPartialDelegations[j]._delegatee, 0, _votes[j]._amount);
        }
        j++;
      }
    }
  }
}

contract Initialize is L2GovTestPreInit {
  /// @notice Emitted when address zero is provided as admin.
  error InvalidAddressZero();

  function testInitialize(address _admin) public {
    vm.assume(_admin != address(0));
    assertEq(tokenProxy.name(), "");
    assertEq(tokenProxy.symbol(), "");
    tokenProxy.initialize(_admin);
    assertEq(tokenProxy.name(), "L2 Governance Token");
    assertEq(tokenProxy.symbol(), "gL2");
  }

  function test_RevertIf_InitializeTwice(address _admin) public {
    vm.assume(_admin != address(0));
    tokenProxy.initialize(_admin);
    vm.expectRevert(Initializable.InvalidInitialization.selector);
    tokenProxy.initialize(_admin);
  }

  function test_RevertIf_InvalidAddressZero() public {
    vm.expectRevert(InvalidAddressZero.selector);
    tokenProxy.initialize(address(0));
  }
}

contract Mint is L2GovTest {
  function testFuzz_Mints(address _actor, address _account, uint208 _amount) public {
    vm.assume(_actor != address(0));
    vm.assume(_account != address(0));
    vm.startPrank(admin);
    tokenProxy.grantRole(tokenProxy.MINTER_ROLE(), _actor);
    vm.stopPrank();
    vm.prank(_actor);
    tokenProxy.mint(_account, _amount);
    assertEq(tokenProxy.balanceOf(_account), _amount);
  }

  function testFuzz_EmitsDelegateVotesChanged(address _actor, address _account, uint208 _amount) public {
    vm.assume(_actor != address(0));
    vm.assume(_account != address(0));
    vm.startPrank(admin);
    tokenProxy.grantRole(tokenProxy.MINTER_ROLE(), _actor);
    vm.stopPrank();

    PartialDelegation[] memory _toDelegations = _createValidPartialDelegation(0, uint256(keccak256(abi.encode(_actor))));
    vm.prank(_account);
    tokenProxy.delegate(_toDelegations);

    _expectEmitDelegateVotesChangedEvents(_amount, tokenProxy.delegates(address(0)), _toDelegations);
    vm.prank(_actor);
    tokenProxy.mint(_account, _amount);
  }

  function testFuzz_RevertIf_NotMinter(address _actor, address _account, uint208 _amount) public {
    vm.assume(_account != address(0));
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _actor, tokenProxy.MINTER_ROLE())
    );
    vm.prank(_actor);
    tokenProxy.mint(_account, _amount);
  }
}

contract Burn is L2GovTest {
  function testFuzz_Burns(address _actor, address _account, uint208 _amount) public {
    vm.assume(_actor != address(0));
    vm.assume(_account != address(0));
    vm.startPrank(admin);
    tokenProxy.grantRole(tokenProxy.BURNER_ROLE(), _actor);
    vm.stopPrank();
    vm.prank(minter);
    tokenProxy.mint(_account, _amount);
    vm.prank(_actor);
    tokenProxy.burn(_account, _amount);
    assertEq(tokenProxy.balanceOf(_account), 0);
  }

  function testFuzz_EmitsDelegateVotesChanged(address _actor, address _account, uint208 _amount) public {
    vm.assume(_actor != address(0));
    vm.assume(_account != address(0));
    vm.startPrank(admin);
    tokenProxy.grantRole(tokenProxy.BURNER_ROLE(), _actor);
    vm.stopPrank();
    vm.prank(minter);
    tokenProxy.mint(_account, _amount);

    PartialDelegation[] memory _fromDelegations =
      _createValidPartialDelegation(0, uint256(keccak256(abi.encode(_actor))));
    vm.prank(_account);
    tokenProxy.delegate(_fromDelegations);

    _expectEmitDelegateVotesChangedEvents(_amount, _fromDelegations, tokenProxy.delegates(address(0)));
    vm.prank(_actor);
    tokenProxy.burn(_account, _amount);
  }

  function testFuzz_RevertIf_NotBurner(address _actor, address _account, uint208 _amount) public {
    vm.assume(_account != address(0));
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _actor, tokenProxy.BURNER_ROLE())
    );
    vm.prank(_actor);
    tokenProxy.burn(_account, _amount);
  }
}
