// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity >=0.8.16;

import { AppStorage, Position } from "../../libraries/LibAppStorage.sol";
import { SchnorrSign } from "../../interfaces/IMuonV03.sol";
import { LibOracle, PositionPrice } from "../../libraries/LibOracle.sol";
import { LibMaster } from "../../libraries/LibMaster.sol";
import { Decimal } from "../../libraries/LibDecimal.sol";
import { LibDiamond } from "../../libraries/LibDiamond.sol";
import { C } from "../../C.sol";
import "../../libraries/LibEnums.sol";

contract LiquidationFacet {
    using Decimal for Decimal.D256;

    AppStorage internal s;

    /*------------------------*
     * PUBLIC WRITE FUNCTIONS *
     *------------------------*/

    /**
     * @dev Unlike a cross liquidation, we don't check for major deficits here.
     *      Counterparties should put limit sell orders at the liquidation price
     *      of the user, in order to mitigate the deficit. Failure to do so
     *      would result in the counterParty paying for the deficit.
     * @dev The above describes 'major' deficits. There's always a deficit,
     *      however the CVA aims to cover that.
     * @dev Cross positions are ALLOWED in order to liquidate partyB.
     */
    function liquidatePositionIsolated(
        uint256 positionId,
        uint256 bidPrice,
        uint256 askPrice,
        bytes calldata reqId,
        uint256 timestamp,
        SchnorrSign[] calldata sigs
    ) external {
        // Verify oracle signatures
        // LibOracle.verifyPositionPriceOrThrow(positionId, bidPrice, askPrice, reqId, timestamp, sigs);

        Position memory position = s.ma._allPositionsMap[positionId];

        // Check if the position should be liquidated
        (bool shouldBeLiquidated, int256 uPnLA, ) = LibMaster.positionShouldBeLiquidatedIsolated(
            positionId,
            bidPrice,
            askPrice
        );
        require(shouldBeLiquidated, "Not liquidatable");
        require(
            position.state != PositionState.LIQUIDATED && position.state != PositionState.CLOSED,
            "Position already closed"
        );

        /**
         * -PnL = position.lockedMargin(AorB) + a deficit
         *
         * Note: we're NOT dealing with PnL here for distribution, because
         * the PnL implies that a deficit is possible. However, since this
         * is an isolated liquidation, the (hidden) deficit is covered by
         * the CVA where its remainder (although not calculated) goes to
         * the counterParty.
         *
         * The liquidation takes form through not returning any funds to
         * to the counterParty because it's all strictly Isolated.
         **/
        if (position.positionType == PositionType.ISOLATED) {
            // We are liquidating either PartyA or PartyB.
            uint256 amount = position.lockedMarginA +
                position.lockedMarginB +
                (position.cva * 2) +
                position.liquidationFee;

            // PartyA is in profit, thus we're liquidating PartyB.
            if (uPnLA >= 0) {
                s.ma._marginBalances[position.partyA] += amount;
            } else {
                s.ma._marginBalances[position.partyB] += amount;
            }
        } else {
            // We are liquidating PartyB as Isolated, despite PartyA being Cross.
            require(uPnLA >= 0, "PartyA should be profitable");
            // Amount excludes lockedMarginA, because he already has a claim to that.
            uint256 amount = position.lockedMarginB + (position.cva * 2) + position.liquidationFee;
            // PartyA receives money as CrossLockedMargin, thus improving his health.
            s.ma._crossLockedMargin[position.partyA] += amount;
        }

        // Reward the liquidator + protocol
        uint256 protocolShare = Decimal.mul(C.getProtocolLiquidationShare(), position.liquidationFee).asUint256();
        s.ma._accountBalances[msg.sender] += (position.liquidationFee - protocolShare);
        s.ma._accountBalances[LibDiamond.contractOwner()] += protocolShare;

        // Update mappings
        _updatePositionDataIsolated(position, LibOracle.createPositionPrice(positionId, bidPrice, askPrice));
    }

    function liquidatePartyCross(
        address partyA,
        uint256[] calldata positionIds,
        uint256[] calldata bidPrices,
        uint256[] calldata askPrices,
        bytes calldata reqId,
        uint256 timestamp,
        SchnorrSign[] calldata sigs
    ) external {
        // Verify oracle signatures
        // LibOracle.verifyPositionPricesOrThrow(positionIds, bidPrices, askPrices, reqId, timestamp, sigs);

        // Check if all positionIds are provided by length
        require(positionIds.length == s.ma._openPositionsCrossLength[partyA], "Invalid positionIds length");

        // Create structs for positionIds and prices
        PositionPrice[] memory positionPrices = LibOracle.createPositionPrices(positionIds, bidPrices, askPrices);

        /**
         * The below checks whether the party should be liquidated. We can do that based
         * on malicious inputs. If malicious then the next `for` loop will revert it regardless.
         */
        int256 uPnLCross = LibMaster.calculateUPnLCross(positionPrices, partyA);
        bool shouldBeLiquidated = LibMaster.partyShouldBeLiquidatedCross(partyA, uPnLCross);
        require(shouldBeLiquidated, "Not liquidatable");

        /**
         * At this point the positionIds can still be malicious in nature. They can be:
         * - tied to a different party
         * - arbitrary positionIds
         * - no longer be valid (e.g. Muon is n-blocks behind)
         *
         * They can NOT:
         * - have a different length than the open positions list, see earlier `require`
         *
         * _calculateRealizedDistribution will catch & revert on any of the above issues.
         */
        uint256 debit = 0;
        uint256 credit = 0;
        int256 lastPnL = 0;
        uint256 totalSingleLiquidationFees = 0;
        uint256 totalDoubleCVA = 0;

        for (uint256 i = 0; i < positionPrices.length; i++) {
            (
                int256 pnl,
                uint256 _debit,
                uint256 _credit,
                uint256 singleLiquidationFee,
                uint256 doubleCVA
            ) = _calculateRealizedDistribution(partyA, positionPrices[i]);
            debit += _debit;
            credit += _credit;

            if (i != 0) {
                require(pnl <= lastPnL, "PNL must be in descending order");
            }
            lastPnL = pnl;
            totalSingleLiquidationFees += singleLiquidationFee;
            totalDoubleCVA += doubleCVA;
        }

        /**
         * Debit vs. Credit is basically the same as PnLA.
         * If we owe less than what we should receive then
         * technically the party should not be liquidated.
         * */
        require(credit >= debit, "PartyA should have more credit");
        uint256 deficit = credit - debit - s.ma._crossLockedMargin[partyA];

        /**
         * We have a deficit that needs to be covered:
         * 1) Covered by the total CVA of all parties involved.
         * 2) Option 1 isn't sufficient. Covered by the PNL of all profitable PartyB's.
         */
        if (deficit < totalDoubleCVA) {
            Decimal.D256 memory doubleCVARatio = Decimal.ratio(totalDoubleCVA - deficit, totalDoubleCVA);
            for (uint256 i = 0; i < positionPrices.length; i++) {
                _distributePnLDeficitThroughCVA(positionPrices[i], doubleCVARatio);
                _updatePositionDataCross(positionPrices[i].positionId, positionPrices[i]);
            }
        } else {
            // The deficit is too high, profitable PartyB's will receive a reduced PNL.
            uint256 pendingDeficit = deficit - totalDoubleCVA;
            Decimal.D256 memory creditRatio = pendingDeficit >= credit
                ? Decimal.ratio(0, 1) // Nobody gets ANY pnl, extremely unlikely.
                : Decimal.ratio(credit - pendingDeficit, credit);

            for (uint256 i = 0; i < positionPrices.length; i++) {
                _distributePnLDeficitThroughCredit(positionPrices[i], creditRatio);
                _updatePositionDataCross(positionPrices[i].positionId, positionPrices[i]);
            }
        }

        // Ultimately, reset the liquidated party his lockedMargin.
        s.ma._crossLockedMargin[partyA] = 0;

        // Reward the liquidator + protocol
        uint256 protocolShare = Decimal.mul(C.getProtocolLiquidationShare(), totalSingleLiquidationFees).asUint256();
        s.ma._accountBalances[msg.sender] += (totalSingleLiquidationFees - protocolShare);
        s.ma._accountBalances[LibDiamond.contractOwner()] += protocolShare;
    }

    /*-------------------------*
     * PRIVATE WRITE FUNCTIONS *
     *-------------------------*/

    function _distributePnLDeficitThroughCVA(
        PositionPrice memory positionPrice,
        Decimal.D256 memory doubleCVARatio
    ) private {
        Position memory position = s.ma._allPositionsMap[positionPrice.positionId];

        // Calculate the PnL of PartyA.
        (int256 uPnLA, ) = LibMaster.calculateUPnLIsolated(
            position.positionId,
            positionPrice.bidPrice,
            positionPrice.askPrice
        );

        uint256 bonusAmount = Decimal.mul(doubleCVARatio, position.cva * 2).asUint256() + position.liquidationFee;

        if (uPnLA >= 0) {
            uint256 pnl = uint256(uPnLA);
            // PartyB gets his lockedMargin back minus the PnL that PartyA has earned.
            uint256 marginAmount = pnl >= position.lockedMarginB
                ? 0 // PartyB should've been liquidated here already.
                : position.lockedMarginB - pnl;
            s.ma._marginBalances[position.partyB] += marginAmount + bonusAmount;
        } else {
            uint256 amount = bonusAmount + uint256(-uPnLA) + position.lockedMarginB;
            s.ma._marginBalances[position.partyB] += amount;
        }
    }

    function _distributePnLDeficitThroughCredit(
        PositionPrice memory positionPrice,
        Decimal.D256 memory creditRatio
    ) private {
        Position memory position = s.ma._allPositionsMap[positionPrice.positionId];

        // Calculate the PnL of PartyA.
        (int256 uPnLA, ) = LibMaster.calculateUPnLIsolated(
            position.positionId,
            positionPrice.bidPrice,
            positionPrice.askPrice
        );

        if (uPnLA >= 0) {
            uint256 pnl = uint256(uPnLA);
            uint256 marginAmount = pnl >= position.lockedMarginB
                ? 0 // PartyB should've been liquidated here already.
                : position.lockedMarginB - pnl;
            s.ma._marginBalances[position.partyB] += marginAmount + position.liquidationFee;
        } else {
            // PartyB gets a reduced PNL, where -uPnLA == credit.
            uint256 amount = position.lockedMarginB +
                Decimal.mul(creditRatio, uint256(-uPnLA)).asUint256() +
                position.liquidationFee;
            s.ma._marginBalances[position.partyB] += amount;
        }
    }

    function _updatePositionDataIsolated(Position memory position, PositionPrice memory positionPrice) private {
        _updatePositionDataTemplate(position.positionId, positionPrice);
        s.ma._openPositionsIsolatedLength[position.partyA]--;
        s.ma._openPositionsIsolatedLength[position.partyB]--;
    }

    function _updatePositionDataCross(uint256 positionId, PositionPrice memory positionPrice) private {
        Position memory position = s.ma._allPositionsMap[positionId];
        _updatePositionDataTemplate(positionId, positionPrice);
        s.ma._openPositionsCrossLength[position.partyA]--;
        s.ma._openPositionsIsolatedLength[position.partyB]--;
    }

    function _updatePositionDataTemplate(uint256 positionId, PositionPrice memory positionPrice) private {
        Position storage position = s.ma._allPositionsMap[positionId];

        // Emit the Fill
        LibMaster.emitFill(
            position.positionId,
            position.side == Side.BUY ? Side.SELL : Side.BUY,
            position.currentBalanceUnits,
            position.side == Side.BUY ? positionPrice.bidPrice : positionPrice.askPrice
        );

        // Update the position state
        position.state = PositionState.LIQUIDATED;
        position.currentBalanceUnits = 0;
        position.mutableTimestamp = block.timestamp;
    }

    /*------------------------*
     * PRIVATE VIEW FUNCTIONS *
     *------------------------*/

    /**
     * @dev Calculates the realized distribution for a single position to uncover deficits.
     * @dev Strictly limited to Cross positions.
     * @dev Strictly targetting partyA (the liquidated party).
     */
    function _calculateRealizedDistribution(
        address partyA,
        PositionPrice memory positionPrice
    )
        private
        view
        returns (int256 uPnLA, uint256 debit, uint256 credit, uint256 singleLiquidationFee, uint256 doubleCVA)
    {
        Position memory position = s.ma._allPositionsMap[positionPrice.positionId];

        require(
            position.state != PositionState.LIQUIDATED && position.state != PositionState.CLOSED,
            "Position already closed"
        );
        require(position.partyA == partyA, "Invalid party");
        require(position.positionType == PositionType.CROSS, "Invalid position type");

        // Calculate the PnL of PartyA
        (uPnLA, ) = LibMaster.calculateUPnLIsolated(
            position.positionId,
            positionPrice.bidPrice,
            positionPrice.askPrice
        );

        /**
         * Note: 'single' implies the half that PartyA locked into
         * the position, which he will now lose.
         *
         * His half + the other half (together 'double') will be:
         * - used for the global deficit (CVA)
         * - used to reward the liquidator (LiquidationFee)
         * - returned to PartyB
         **/
        singleLiquidationFee = position.liquidationFee;
        doubleCVA = position.cva * 2;

        if (uPnLA >= 0) {
            // PartyA receives the PNL.
            uint256 amount = uint256(uPnLA);
            debit = amount >= position.lockedMarginB
                ? position.lockedMarginB // PartyB should've been liquidated here already.
                : amount;
            credit = 0;
        } else {
            // PartyA has to pay PartyB.
            debit = 0;
            credit = uint256(-uPnLA);
        }
    }
}
