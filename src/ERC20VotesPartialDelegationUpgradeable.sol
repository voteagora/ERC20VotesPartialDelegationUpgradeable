// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20PermitUpgradeable} from
  "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {VotesPartialDelegationUpgradeable, NoncesUpgradeable} from "src/VotesPartialDelegationUpgradeable.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @dev ERC20VotesUpgradeable with the addition of partial delegation via VotesPartialDelegationUpgradeable.
 * Supports token supply up to 2^208^ - 1.
 *
 * This extension keeps a history (checkpoints) of each account's vote power. Vote power can be delegated either
 * by calling the {delegate} function directly, or by providing a signature to be used with {delegateBySig} or
 * {delegatePartiallyOnBehalf}.
 * Voting power can be queried through the public accessors {getVotes} and {getPastVotes}.
 *
 * By default, token balance does not account for voting power. This makes transfers cheaper. The downside is that it
 * requires users to delegate to themselves in order to activate checkpoints and have their voting power tracked.
 * @custom:security-contact security@voteagora.com
 */
abstract contract ERC20VotesPartialDelegationUpgradeable is
  Initializable,
  ERC20PermitUpgradeable,
  VotesPartialDelegationUpgradeable
{
  /**
   * @dev Total supply cap has been exceeded, introducing a risk of votes overflowing.
   */
  error ERC20ExceededSafeSupply(uint256 increasedSupply, uint256 cap);

  function __ERC20VotesPartialDelegation_init() internal onlyInitializing {}

  function __ERC20VotesPartialDelegation_init_unchained() internal onlyInitializing {}
  /**
   * @dev Maximum token supply. Defaults to `type(uint208).max` (2^208^ - 1).
   *
   * This maximum is enforced in {_update}. It limits the total supply of the token, which is otherwise a uint256,
   * so that checkpoints can be stored in the Trace208 structure used by {{Votes}}. Increasing this value will not
   * remove the underlying limitation, and will cause {_update} to fail because of a math overflow in
   * {_transferVotingUnits}. An override could be used to further restrict the total supply (to a lower value) if
   * additional logic requires it. When resolving override conflicts on this function, the minimum should be
   * returned.
   */

  function _maxSupply() internal view virtual returns (uint256) {
    return type(uint208).max;
  }

  /**
   * @dev Move voting power when tokens are transferred.
   *
   * Emits one or more {IVotes-DelegateVotesChanged} events.
   */
  function _update(address from, address to, uint256 value) internal virtual override {
    super._update(from, to, value);
    if (from == address(0)) {
      uint256 supply = totalSupply();
      uint256 cap = _maxSupply();
      if (supply > cap) {
        revert ERC20ExceededSafeSupply(supply, cap);
      }
    }
    _transferVotingUnits(from, to, value);
  }

  /**
   * @dev Returns the voting units of an `account`.
   *
   * WARNING: Overriding this function may compromise the internal vote accounting.
   * `ERC20Votes` assumes tokens map to voting units 1:1 and this is not easy to change.
   */
  function _getVotingUnits(address account) internal view virtual override returns (uint256) {
    return balanceOf(account);
  }

  /**
   * @dev Get number of checkpoints for `account`.
   */
  function numCheckpoints(address account) public view virtual returns (uint32) {
    return _numCheckpoints(account);
  }

  /**
   * @dev Get the `pos`-th checkpoint for `account`.
   */
  function checkpoints(address account, uint32 pos) public view virtual returns (Checkpoints.Checkpoint208 memory) {
    return _checkpoints(account, pos);
  }

  /**
   * @inheritdoc NoncesUpgradeable
   */
  function nonces(address owner) public view override(ERC20PermitUpgradeable, NoncesUpgradeable) returns (uint256) {
    return NoncesUpgradeable.nonces(owner);
  }
}
