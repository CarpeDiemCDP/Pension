// SPDX-License-Identifier: MIT
pragma solidity 0.8.8;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/draft-ERC20Permit.sol";

contract CDPToken is
    ERC20,
    ERC20Burnable,
    ERC20Permit
{
    address public minterAddress;
    uint256 public totalBurned;

    constructor(address pensionAddress)
        ERC20("Carpe Diem Pension", "CDP")
        ERC20Permit("Carpe Diem Pension")
    {
        minterAddress = pensionAddress;
        _mint(msg.sender, 543391647*1e18);
    }

    function mint(address to, uint256 amount) public {
        require(msg.sender == minterAddress, "Account doesn't have the required permission");
        _mint(to, amount);
    }

    function burn(uint256 amount) public override {
        totalBurned += amount;
        _burn(_msgSender(), amount);
    }

    function getBurned() external view returns (uint256) {
        return totalBurned;
    }
}