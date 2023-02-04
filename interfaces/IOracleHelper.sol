// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

interface IOracleHelper {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function OUTPUT_DECIMALS() external view returns (uint8);

    function getPrice(address token) external view returns (uint256);

    function getPriceOfXInYUnits(address tokenX, address tokenY) external view returns (uint256);

    function owner() external view returns (address);

    function renounceOwnership() external;

    function setFeedForToken(address token, address feed) external;

    function tokenToFeed(address) external view returns (address);

    function transferOwnership(address newOwner) external;
}
