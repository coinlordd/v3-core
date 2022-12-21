// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.16;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MasterStorage, Position } from "../MasterStorage.sol";
import { ConstantsInternal } from "../../constants/ConstantsInternal.sol";

library AccountsInternal {
    using MasterStorage for MasterStorage.Layout;

    /* ========== VIEWS ========== */

    function getAccountBalance(address party) internal view returns (uint256) {
        return MasterStorage.layout().accountBalances[party];
    }

    function getMarginBalance(address party) internal view returns (uint256) {
        return MasterStorage.layout().marginBalances[party];
    }

    function getLockedMargin(address party) internal view returns (uint256) {
        return MasterStorage.layout().crossLockedMargin[party];
    }

    function getLockedMarginReserved(address party) internal view returns (uint256) {
        return MasterStorage.layout().crossLockedMarginReserved[party];
    }

    /* ========== WRITES ========== */

    function deposit(address party, uint256 amount) internal {
        MasterStorage.Layout storage s = MasterStorage.layout();

        IERC20 collateral = IERC20(ConstantsInternal.getCollateral());
        require(collateral.balanceOf(party) >= amount, "Insufficient collateral balance");

        bool success = collateral.transferFrom(party, address(this), amount);
        require(success, "Failed to deposit collateral");
        s.accountBalances[party] += amount;
    }

    function withdraw(address party, uint256 amount) internal {
        MasterStorage.Layout storage s = MasterStorage.layout();

        require(s.accountBalances[party] >= amount, "Insufficient account balance");
        s.accountBalances[party] -= amount;
        bool success = IERC20(ConstantsInternal.getCollateral()).transfer(party, amount);
        require(success, "Failed to withdraw collateral");
    }

    function allocate(address party, uint256 amount) internal {
        MasterStorage.Layout storage s = MasterStorage.layout();

        require(s.accountBalances[party] >= amount, "Insufficient account balance");
        s.accountBalances[party] -= amount;
        s.marginBalances[party] += amount;
    }

    function deallocate(address party, uint256 amount) internal {
        MasterStorage.Layout storage s = MasterStorage.layout();

        require(s.marginBalances[party] >= amount, "Insufficient margin balance");
        s.marginBalances[party] -= amount;
        s.accountBalances[party] += amount;
    }

    function addFreeMarginIsolated(address party, uint256 amount, uint256 positionId) internal {
        MasterStorage.Layout storage s = MasterStorage.layout();

        Position storage position = s.allPositionsMap[positionId];
        require(position.partyB == party, "Not partyB");

        require(s.marginBalances[party] >= amount, "Insufficient margin balance");
        s.marginBalances[party] -= amount;
        position.lockedMarginB += amount;
    }

    function addFreeMarginCross(address party, uint256 amount) internal {
        MasterStorage.Layout storage s = MasterStorage.layout();

        require(s.marginBalances[party] >= amount, "Insufficient margin balance");
        s.marginBalances[party] -= amount;
        s.crossLockedMargin[party] += amount;
    }

    function removeFreeMarginCross(address party) internal returns (uint256 removedAmount) {
        MasterStorage.Layout storage s = MasterStorage.layout();

        require(s.openPositionsCrossLength[party] == 0, "Removal denied");
        require(s.crossLockedMargin[party] > 0, "No locked margin");

        uint256 amount = s.crossLockedMargin[party];
        s.crossLockedMargin[party] = 0;
        s.marginBalances[party] += amount;

        return amount;
    }
}
