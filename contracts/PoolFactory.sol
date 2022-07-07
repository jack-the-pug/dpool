// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.15;

import "@openzeppelin/contracts/proxy/Clones.sol";

import "./DistributionPool.sol";

/// @title The PoolFactory allows users to create own dPool very cheaply.
contract PoolFactory {
    /// @notice The instance to which all proxies will point.
    DistributionPool public immutable distributionPoolImp;

    /// contract _owner => dPool contract address
    mapping(address => address) public distributionPoolOf;
    
    event DistributionPoolCreated(
        address indexed creator,
        address contractAddress
    );

    /// @notice Contract constructor.
    constructor(address _wNATIVE) {
        distributionPoolImp = new DistributionPool(_wNATIVE);
        distributionPoolImp.initialize(address(this));
    }

    /**
     * @notice Creates a clone.
     * @return The newly created contract address
     */
    function create() external returns (address) {
        address _dPool = Clones.clone(address(distributionPoolImp));
        DistributionPool(payable(_dPool)).initialize(msg.sender);

        distributionPoolOf[msg.sender] = _dPool;
        emit DistributionPoolCreated(msg.sender, _dPool);

        return _dPool;
    }
}
