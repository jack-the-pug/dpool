// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";


contract WETH is ERC20 {
  constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

  // Mocks WETH deposit fn
  function deposit() external payable {
    _mint(msg.sender, msg.value);
  }
  function withdraw(uint256 amount) public {
    _burn(msg.sender, amount);
    payable(msg.sender).transfer(amount);
  }

}