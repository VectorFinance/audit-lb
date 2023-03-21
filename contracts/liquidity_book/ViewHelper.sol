// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelinUpgradeable/contracts/proxy/utils/Initializable.sol";
import "@openzeppelinUpgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelinUpgradeable/contracts/security/PausableUpgradeable.sol";
import "@openzeppelinUpgradeable/contracts/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelinUpgradeable/contracts/token/ERC20/ERC20Upgradeable.sol";

import "./../../interfaces/ILBPair.sol";
import "./../../interfaces/ILBRouter.sol";
import "./../../interfaces/ILBFactory.sol";
import "./../../interfaces/ILBToken.sol";
import "./../../interfaces/IStrategy.sol";
import "./../../interfaces/ILBPool.sol";
import "./BinHelper.sol";

/// @title Locker
/// @author Vector Team
contract ViewHelper is Initializable, OwnableUpgradeable {
    using EnumerableSet for EnumerableSet.UintSet;

    function __ViewHelper_init() external initializer {
        __Ownable_init();
    }

    function getPriceFromBin(uint256 activeId, uint256 binStep)
        public
        view
        returns (uint256 price)
    {
        price = (BinHelper.getPriceFromId(activeId, binStep) * 10**18) >> 128;
    }

    /**
     * @notice Calculate amount of tokenX for a given amount of receipt tokens
     * @param amount receipt tokens
     * @return totalAmount tokenX
     * @return totalReserveXAvailable tokenX
     */
    function getDepositTokensXForShares(
        uint256 amount,
        uint256 priceX,
        ILBPool vault
    ) public view returns (uint256 totalAmount, uint256 totalReserveXAvailable) {
        (uint256 totalReserveX, uint256 totalReserveY) = vault.getTotalFunds();
        uint256 totalDeposits = ((totalReserveX * priceX) / 10**18) + totalReserveY;
        uint256 totalSupply = vault.totalSupply();
        totalReserveXAvailable = totalReserveX;
        if (totalSupply == 0 || totalDeposits == 0) {
            totalAmount = 0;
        } else {
            totalAmount = (((amount * totalDeposits) / totalSupply) * 10**18) / priceX;
        }
    }

    /**
     * @notice Calculate amount of tokenY for a given amount of receipt tokens
     * @param amount receipt tokens
     * @return totalAmount tokenY
     * @return totalReserveYAvailable tokenY
     */
    function getDepositTokensYForShares(
        uint256 amount,
        uint256 priceX,
        ILBPool vault
    ) public view returns (uint256 totalAmount, uint256 totalReserveYAvailable) {
        (uint256 totalReserveX, uint256 totalReserveY) = vault.getTotalFunds();
        uint256 totalDeposits = (totalReserveY + ((totalReserveX * priceX) / 10**18));
        uint256 totalSupply = vault.totalSupply();
        totalReserveYAvailable = totalReserveY;
        if (totalSupply == 0 || totalDeposits == 0) {
            totalAmount = 0;
        } else {
            totalAmount = (amount * totalDeposits) / totalSupply;
        }
    }

    function getMaximumWithdrawalTokenXWithoutSwapping(ILBPool vault, address user)
        external
        view
        returns (uint256 finalAmountX, uint256 finalAmountY)
    {
        uint256 shares = vault.balanceOf(user);
        if (shares < 2) {
            return (finalAmountX, finalAmountY);
        }
        shares -= 1;
        uint256 priceX = vault.getOraclePrice();
        (uint256 totalAmountXWithdrawable, uint256 reserveX) = getDepositTokensXForShares(
            shares,
            priceX,
            vault
        );
        if (totalAmountXWithdrawable > reserveX) {
            finalAmountX = reserveX;
            uint256 neededShares = vault.getSharesForDepositTokens(
                (reserveX * priceX) / 10**18 + 1,
                priceX
            ) + 1;
            (finalAmountY, ) = getDepositTokensYForShares(shares - neededShares, priceX, vault);
        } else {
            finalAmountX = totalAmountXWithdrawable - 1;
        }
    }

    function getMaximumWithdrawalTokenYWithoutSwapping(ILBPool vault, address user)
        external
        view
        returns (uint256 finalAmountX, uint256 finalAmountY)
    {
        uint256 shares = vault.balanceOf(user);
        uint256 priceX = vault.getOraclePrice();
        uint256 sharesForOneY = vault.getSharesForDepositTokens(1, priceX);

        if (shares < sharesForOneY + 1) {
            return (finalAmountX, finalAmountY);
        }
        shares -= sharesForOneY + 1;

        (uint256 totalAmountYWithdrawable, uint256 reserveY) = getDepositTokensYForShares(
            shares,
            priceX,
            vault
        );

        if (reserveY == 0) {
            (finalAmountX, ) = getDepositTokensXForShares(shares, priceX, vault);
        } else if (totalAmountYWithdrawable > reserveY) {
            finalAmountY = reserveY;
            uint256 neededShares = vault.getSharesForDepositTokens(finalAmountY, priceX);
            (finalAmountX, ) = getDepositTokensXForShares(shares - neededShares, priceX, vault);
        } else {
            finalAmountY = totalAmountYWithdrawable;
        }
    }

    // function getMaximumWithdrawalTokenYWithoutSwapping(ILBPool vault, address user)
    //     external
    //     view
    //     returns (uint256 finalAmountX, uint256 finalAmountY)
    // {
    //     uint256 shares = vault.balanceOf(user);
    //     if (shares < 2) {
    //         return (finalAmountX, finalAmountY);
    //     }
    //     uint256 priceX = vault.getOraclePrice();
    //     (uint256 totalAmountYWithdrawable, uint256 reserveY) = getDepositTokensYForShares(
    //         shares,
    //         priceX,
    //         vault
    //     );
    //     if (reserveY == 0) {
    //         (finalAmountX, ) = getDepositTokensXForShares(shares - 2, priceX, vault);
    //     } else if (totalAmountYWithdrawable > reserveY) {
    //         finalAmountY = reserveY;
    //         uint256 neededShares = vault.getSharesForDepositTokens(finalAmountY, priceX) + 1;
    //         (finalAmountX, ) = getDepositTokensXForShares(shares - neededShares, priceX, vault);
    //         if (
    //             finalAmountY > 0 &&
    //             (vault.getSharesForDepositTokens(
    //                 (finalAmountX * priceX) / 10**18 + finalAmountY + 1,
    //                 priceX
    //             ) >= shares)
    //         ) {
    //             finalAmountY -= 1;
    //         }
    //     } else {
    //         if (totalAmountYWithdrawable > 1) {
    //             finalAmountY = totalAmountYWithdrawable - 2;
    //         }
    //     }
    // }

    function getReserveForBin(
        address pair,
        uint256 bin,
        address vault
    )
        public
        view
        returns (
            uint256 reserveX,
            uint256 reserveY,
            uint256 receiptBalance
        )
    {
        (reserveX, reserveY, receiptBalance) = _getReserveForBin(pair, bin, vault);
    }

    function _getReserveForBin(
        address pair,
        uint256 bin,
        address vault
    )
        public
        view
        returns (
            uint256 reserveX,
            uint256 reserveY,
            uint256 receiptBalance
        )
    {
        ILBToken receiptToken = ILBToken(pair);
        receiptBalance = receiptToken.balanceOf(vault, bin);
        if (receiptBalance == 0) {
            return (0, 0, 0);
        }
        uint256 binSupply = receiptToken.totalSupply(bin);
        (uint256 pairReserveX, uint256 pairReserveY) = ILBPair(pair).getBin(uint24(bin));
        if (binSupply > 0) {
            reserveX = (pairReserveX * receiptBalance) / binSupply;
            reserveY = (pairReserveY * receiptBalance) / binSupply;
        }
    }

    /**
     * @notice View in order to respect the ratio and avoid fees when depositing into the active bin
     * @param amountX see ILBRouter.LiquidityParameters
     * @param amountY see ILBRouter.LiquidityParameters
     * @param _deltaIds see ILBRouter.LiquidityParameters
     * @param _distributionX see ILBRouter.LiquidityParameters
     * @param _distributionY see ILBRouter.LiquidityParameters
     * @return finalIds modified distribution to avoid fees see ILBRouter.LiquidityParameters
     * @return finalDistributionX modified distribution to avoid fees see ILBRouter.LiquidityParameters
     * @return finalDistributionY modified distribution to avoid fees see ILBRouter.LiquidityParameters
     */
    function computeDistributionToRespectRatio(
        uint256 amountX,
        uint256 amountY,
        uint256 ratio,
        int256[] memory _deltaIds,
        uint256[] memory _distributionX,
        uint256[] memory _distributionY
    )
        public
        view
        returns (
            int256[] memory finalIds,
            uint256[] memory finalDistributionX,
            uint256[] memory finalDistributionY
        )
    {
        uint256 distXOutsideActive;
        uint256 distYOutsideActive;
        for (uint256 i; i < _deltaIds.length; i++) {
            if (_deltaIds[i] == 0) {
                distXOutsideActive = 10**18 - _distributionX[i];
                distYOutsideActive = 10**18 - _distributionY[i];
                break;
            }
        }
        uint256 amountXNeeded = (((amountY * (10**18 - distYOutsideActive)) / 10**18) * ratio) /
            10**18;

        finalIds = new int256[](_deltaIds.length);
        finalDistributionX = new uint256[](_deltaIds.length);
        finalDistributionY = new uint256[](_deltaIds.length);
        if (amountX >= amountXNeeded) {
            // enough X deposited globally
            uint256 targetDistInActive = (amountXNeeded * 10**18) / amountX;
            uint256 remainingDist = 10**18 - targetDistInActive;
            uint256 totalDistXOutsideActive;
            for (uint256 i; i < _deltaIds.length; i++) {
                finalIds[i] = _deltaIds[i];
                uint256 newDistX;
                if (_distributionX[i] > 0) {
                    if (_deltaIds[i] == 0) {
                        newDistX = targetDistInActive;
                    } else if (i == _deltaIds.length - 1) {
                        newDistX = remainingDist - totalDistXOutsideActive;
                    } else {
                        newDistX = (_distributionX[i] * remainingDist) / distXOutsideActive;
                    }
                }
                finalDistributionX[i] = newDistX;
                if (_deltaIds[i] != 0) {
                    totalDistXOutsideActive += newDistX;
                }
            }
            finalDistributionY = _distributionY;
        } else {
            uint256 amountYNeeded = ((amountX * (10**18 - distXOutsideActive)) / ratio);
            uint256 targetDistInActive = (amountYNeeded * 10**18) / amountY;
            uint256 remainingDist = 10**18 - targetDistInActive;
            uint256 totalDistYOutsideActive;
            for (uint256 i = _deltaIds.length - 1; i >= 0; i--) {
                finalIds[i] = _deltaIds[i];
                uint256 newDistY;
                if (_distributionY[i] > 0) {
                    if (_deltaIds[i] == 0) {
                        newDistY = targetDistInActive;
                    } else if (i == 0) {
                        newDistY = remainingDist - totalDistYOutsideActive;
                    } else {
                        newDistY = (_distributionY[i] * remainingDist) / distYOutsideActive;
                    }
                }

                finalDistributionY[i] = newDistY;

                if (_deltaIds[i] != 0) {
                    totalDistYOutsideActive += newDistY;
                }
                if (i == 0) {
                    break;
                }
            }
            finalDistributionX = _distributionX;
        }
    }

    /**
     * @notice Computes the amounts of receipt token and the bins from where to burn them to withdraw amount of the tokenX
     * @param amount amount of token X to withdraw
     * @return finalAmounts amounts of receipt token to burn
     * @return finalIds bins to burn from
     */
    function computeAmountsForWithdrawY(uint256 amount)
        public
        view
        returns (uint256[] memory finalAmounts, uint256[] memory finalIds)
    {
        (finalAmounts, finalIds) = _computeAmountsForWithdrawY(amount, ILBPool(msg.sender));
    }

    /**
     * @notice Computes the amounts of receipt token and the bins from where to burn them to withdraw amount of the tokenX
     * @param amount amount of token X to withdraw
     * @return finalAmounts amounts of receipt token to burn
     * @return finalIds bins to burn from
     */
    function _computeAmountsForWithdrawY(uint256 amount, ILBPool vault)
        public
        view
        returns (uint256[] memory finalAmounts, uint256[] memory finalIds)
    {
        uint256 reserve;
        ILBToken receiptToken;
        uint256 lowestBin;
        uint256 activeId;
        {
            receiptToken = ILBToken(address(vault.pair()));
            (, lowestBin) = vault.getHighestAndLowestBin();
            (, , activeId) = vault.getPairInfos();
        }
        uint256[] memory amounts = new uint256[](activeId - lowestBin);
        uint256[] memory ids = new uint256[](activeId - lowestBin);
        // in the case of a withdraw from the active bin, we get both tokens. this is not handled here
        uint256 finalLength;
        for (uint256 i = lowestBin; i < activeId; i++) {
            (, uint256 binReserve, uint256 receiptTokenAmount) = getReserveForBin(
                address(receiptToken),
                i,
                vault.receiptsManager()
            );
            if (receiptTokenAmount > 0 && binReserve > 0) {
                if (reserve + binReserve >= amount) {
                    uint256 neededFromBin = amount - reserve;
                    uint256 neededShares = (neededFromBin * receiptTokenAmount) / binReserve;
                    amounts[finalLength] = neededShares;
                    ids[finalLength] = i;
                    finalLength += 1;
                    break;
                }
                reserve += binReserve;
                amounts[finalLength] = receiptTokenAmount;
                ids[finalLength] = i;
                finalLength += 1;
            }
        }
        finalAmounts = new uint256[](finalLength);
        finalIds = new uint256[](finalLength);
        for (uint256 k; k < finalLength; k++) {
            finalAmounts[k] = amounts[k];
            finalIds[k] = ids[k];
        }
    }

    /**
     * @notice Computes the amounts of receipt token and the bins from where to burn them to withdraw amount of the tokenY
     * @param amount amount of token Y to withdraw
     * @return finalAmounts amounts of receipt token to burn
     * @return finalIds bins to burn from
     */
    function computeAmountsForWithdrawX(uint256 amount)
        public
        view
        returns (uint256[] memory finalAmounts, uint256[] memory finalIds)
    {
        (finalAmounts, finalIds) = _computeAmountsForWithdrawX(amount, ILBPool(msg.sender));
    }

    /**
     * @notice Computes the amounts of receipt token and the bins from where to burn them to withdraw amount of the tokenY
     * @param amount amount of token Y to withdraw
     * @return finalAmounts amounts of receipt token to burn
     * @return finalIds bins to burn from
     */
    function _computeAmountsForWithdrawX(uint256 amount, ILBPool vault)
        public
        view
        returns (uint256[] memory finalAmounts, uint256[] memory finalIds)
    {
        uint256 reserve;
        ILBToken receiptToken;
        uint256 highestBin;
        uint256 activeId;
        {
            receiptToken = ILBToken(address(vault.pair()));
            (highestBin, ) = vault.getHighestAndLowestBin();
            (, , activeId) = vault.getPairInfos();
        }
        uint256[] memory amounts = new uint256[](highestBin - activeId);
        uint256[] memory ids = new uint256[](highestBin - activeId);
        // in the case of a withdraw from the active bin, we get both tokens. this is not handled here
        uint256 finalLength;
        for (uint256 i = highestBin; i > activeId; i--) {
            (uint256 binReserve, , uint256 receiptTokenAmount) = getReserveForBin(
                address(receiptToken),
                i,
                vault.receiptsManager()
            );
            if (receiptTokenAmount > 0 && binReserve > 0) {
                if (reserve + binReserve >= amount) {
                    uint256 neededFromBin = amount - reserve;
                    uint256 neededShares = (neededFromBin * receiptTokenAmount) / binReserve;
                    amounts[finalLength] = neededShares;
                    ids[finalLength] = i;
                    finalLength += 1;
                    break;
                }
                reserve += binReserve;
                amounts[finalLength] = receiptTokenAmount;
                ids[finalLength] = i;
                finalLength += 1;
            }
        }
        finalAmounts = new uint256[](finalLength);
        finalIds = new uint256[](finalLength);
        for (uint256 k; k < finalLength; k++) {
            finalAmounts[k] = amounts[k];
            finalIds[k] = ids[k];
        }
    }

    /**
     * @notice Computes the amount to be withdrawn from active Bin. One of the tokens is implicitely calculated and thus must be 0.
     * @dev The returned amount is for the token that is automatically handeld
     * @dev amountX * amountY == 0
     * @param amountX amount of token X to withdraw
     * @param amountY amount of token Y to withdraw
     * @param activeId id of the active bin
     * @return finalAmount amounts of receipt token to burn
     * @return amountOtherToken amount of token that will be withdrawn
     */
    function computeWithdrawAmountsFromActiveBin(
        uint256 amountX,
        uint256 amountY,
        uint256 activeId
    ) public view returns (uint256 finalAmount, uint256 amountOtherToken) {
        (finalAmount, amountOtherToken) = _computeWithdrawAmountsFromActiveBin(
            amountX,
            amountY,
            activeId,
            ILBPool(msg.sender)
        );
    }

    /**
     * @notice Computes the amount to be withdrawn from active Bin. One of the tokens is implicitely calculated and thus must be 0.
     * @dev The returned amount is for the token that is automatically handeld
     * @dev amountX * amountY == 0
     * @param amountX amount of token X to withdraw
     * @param amountY amount of token Y to withdraw
     * @param activeId id of the active bin
     * @return finalAmount amounts of receipt token to burn
     * @return amountOtherToken amount of token that will be withdrawn
     */
    function _computeWithdrawAmountsFromActiveBin(
        uint256 amountX,
        uint256 amountY,
        uint256 activeId,
        ILBPool vault
    ) public view returns (uint256 finalAmount, uint256 amountOtherToken) {
        address pair = address(vault.pair());
        ILBToken receiptToken = ILBToken(pair);
        (uint256 binReserveX, uint256 binReserveY, ) = getReserveForBin(
            pair,
            activeId,
            address(vault)
        );
        require(amountX == 0 || amountY == 0, "One must be 0");
        uint256 binSupply = receiptToken.balanceOf(address(vault), activeId);
        if (amountX > 0) {
            finalAmount = (amountX * binSupply) / binReserveX;
            amountOtherToken = (binReserveY * finalAmount) / binSupply;
        } else {
            finalAmount = (amountY * binSupply) / binReserveY;
            amountOtherToken = (binReserveX * finalAmount) / binSupply;
        }
    }
}
