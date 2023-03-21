// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

import "interfaces/ILBRouter.sol";

interface IReceiptsHolder {
    event FeeDistributed(address indexed user, uint256 amount, address token);
    event Harvest(address indexed user, uint256 amountX, uint256 amountY);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Paused(address account);
    event Unpaused(address account);

    function CALLER_FEE() external view returns (uint256);

    function MANAGER_FEE() external view returns (uint256);

    function PRECISION() external view returns (uint256);

    function PROTOCOL_FEE() external view returns (uint256);

    function __ReceiptsHolder_init(
        address _tokenX,
        address _tokenY,
        uint256 _binStep,
        address _router,
        address _pair,
        address _viewHelper
    ) external;

    function addLiquidity(ILBRouter.LiquidityParameters calldata parameters)
        external
        returns (uint256[] memory depositIds);

    function binStep() external view returns (uint256);

    function getReserveForBin(uint256 bin)
        external
        view
        returns (
            uint256 reserveX,
            uint256 reserveY,
            uint256 receiptBalance
        );

    function harvest(uint256[] calldata depositedBins, address caller) external;

    function owner() external view returns (address);

    function pair() external view returns (address);

    function paused() external view returns (bool);

    function protocolFeeRecipient() external view returns (address);

    function receiptToken() external view returns (address);

    function removeLiquidity(uint256[] calldata ids, uint256[] calldata amounts) external;

    function renounceOwnership() external;

    function router() external view returns (address);

    function setCallerFee(uint256 _value) external;

    function setManagerFee(uint256 _value) external;

    function setProtocolFee(uint256 _value) external;

    function setProtocolFeeRecipient(address _value) external;

    function setStrategy(address _strategy) external;

    function strategy() external view returns (address);

    function tokenX() external view returns (address);

    function tokenY() external view returns (address);

    function transferOwnership(address newOwner) external;

    function vault() external view returns (address);

    function viewHelper() external view returns (address);
}
