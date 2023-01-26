// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

interface IViewHelper {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function __LBPool_init(
        address _tokenX,
        address _tokenY,
        uint256 _binStep,
        address _router,
        address _receipt
    ) external;

    function computeAmountsForWithdrawX(uint256 amount)
        external
        view
        returns (uint256[] memory finalAmounts, uint256[] memory finalIds);

    function computeAmountsForWithdrawY(uint256 amount)
        external
        view
        returns (uint256[] memory finalAmounts, uint256[] memory finalIds);

    function computeDistributionToRespectRatio(
        uint256 amountX,
        uint256 amountY,
        uint256 ratio,
        int256[] calldata _deltaIds,
        uint256[] calldata _distributionX,
        uint256[] calldata _distributionY
    )
        external
        view
        returns (
            int256[] memory finalIds,
            uint256[] memory finalDistributionX,
            uint256[] memory finalDistributionY
        );

    function computeWithdrawAmountsFromActiveBin(
        uint256 amountX,
        uint256 amountY,
        uint256 reservesX,
        uint256 reservesY,
        uint256 activeId
    ) external view returns (uint256 finalAmount, uint256 amountOtherToken);

    function getReserveForBin(address pair, uint256 bin)
        external
        view
        returns (
            uint256 reserveX,
            uint256 reserveY,
            uint256 receiptBalance
        );

    function owner() external view returns (address);

    function renounceOwnership() external;

    function transferOwnership(address newOwner) external;

    function getDepositTokensYForShares(uint256 amount, uint256 priceX)
        external
        view
        returns (uint256 totalAmount, uint256 totalReserveYAvailable);

    function getDepositTokensXForShares(uint256 amount, uint256 priceX)
        external
        view
        returns (uint256 totalAmount, uint256 totalReserveXAvailable);

    function getPriceFromBin(uint256 activeId, uint256 binStep)
        external
        view
        returns (uint256 price);

    function getMaximumWithdrawalTokenYWithoutSwapping(address vault, address user)
        external
        view
        returns (uint256 finalAmountX, uint256 finalAmountY);

    function getMaximumWithdrawalTokenXWithoutSwapping(address vault, address user)
        external
        view
        returns (uint256 finalAmountX, uint256 finalAmountY);
}
