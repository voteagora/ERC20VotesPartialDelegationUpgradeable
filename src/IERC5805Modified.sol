// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v5.0.0) (interfaces/IERC5805.sol)

pragma solidity ^0.8.20;

import {IVotesFractionalDelegation} from "src/IVotesFractionalDelegation.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";

interface IERC5805Modified is IERC6372, IVotesFractionalDelegation {}
