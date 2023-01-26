// SPDX-License-Identifier: MIT
pragma solidity 0.8.7;

interface IOracle {
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function __Oracle_init() external;

    function getPrice(address token) external view returns (uint256);

    function owner() external view returns (address);

    function precision() external view returns (uint256);

    function price() external view returns (uint256);

    function renounceOwnership() external;

    function setPrice(uint256 _price) external;

    function transferOwnership(address newOwner) external;
}
