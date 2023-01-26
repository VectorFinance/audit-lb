// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import "@openzeppelinUpgradeable/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelinUpgradeable/contracts/proxy/utils/Initializable.sol";

contract Oracle is Initializable, OwnableUpgradeable {
    uint256 public price;
    uint256 public precision;

    function __Oracle_init() public initializer {
        __Ownable_init();
    }

    function setPrice(uint256 _price) external onlyOwner {
        price = _price;
    }

    function getPrice(address token) external view returns (uint256) {
        return price;
    }
}
