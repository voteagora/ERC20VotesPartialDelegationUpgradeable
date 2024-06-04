// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC5805.sol)

pragma solidity ^0.8.20;

import {IVotesPartialDelegation} from "src/IVotesPartialDelegation.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";

/**
 * @dev Interface that mostly supports the ERC5805 standard, but with a modified IVotes that more appropriately
 * describes
 * partial delegation.
 */
interface IERC5805Modified is IERC6372, IVotesPartialDelegation {}
