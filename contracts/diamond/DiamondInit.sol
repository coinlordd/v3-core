// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.16;

/******************************************************************************\
* Author: Nick Mudge <nick@perfectabstractions.com> (https://twitter.com/mudgen)
* EIP-2535 Diamonds: https://eips.ethereum.org/EIPS/eip-2535
/******************************************************************************/

import { DiamondStorage } from "../diamond/DiamondStorage.sol";
import { OracleInternal } from "../oracle/OracleInternal.sol";
import { ConstantsInternal } from "../constants/ConstantsInternal.sol";

contract DiamondInit {
    function init() external {
        ConstantsInternal.setCollateral(0xDE1E704dae0B4051e80DAbB26ab6ad6c12262DA0); // DEI
        ConstantsInternal.setLiquidationFee(0.0005e18); // 0.05%
        ConstantsInternal.setProtocolLiquidationShare(0.5e18); // 50%
        ConstantsInternal.setCVA(0.01e18); // 1%
        ConstantsInternal.setRequestTimeout(2 minutes);
        ConstantsInternal.setMaxOpenPositionsCross(5);
    }
}
