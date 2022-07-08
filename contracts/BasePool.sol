// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.15;

import {SafeTransferLib} from "./libs/SafeTransferLib.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IERC20Permit} from "./interfaces/IERC20Permit.sol";

contract BasePool {
    using SafeTransferLib for IERC20;

    struct DisperseData {
        address token;
        address payable[] recipients;
        uint256[] values;
    }

    struct PermitData {
        address token;
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    IWETH immutable wNATIVE;

    /// @notice Contract owner.
    // can not be transferred to another address
    address public owner;


    event DisperseToken(address token, uint256 totalAmount);

    constructor(address _wNATIVE) {
        wNATIVE = IWETH(_wNATIVE);
    }

    receive() external payable {}

    /// @notice Modifier to only allow the contract owner to call a function
    modifier onlyOwner() {
        require(msg.sender == owner, "only-owner");
        _;
    }

    function initialize(address _owner) virtual public {
        require(owner == address(0), "initialized");
        owner = _owner;
    }

    function disperseEther(
        address payable[] calldata recipients,
        uint256[] calldata values
    ) external payable onlyOwner {
        _disperseEther(recipients, values);
    }

    function _disperseEther(
        address payable[] calldata recipients,
        uint256[] calldata values
    ) internal {
        uint256 total = 0;
        for (uint256 i = 0; i < recipients.length; ++i) total += values[i];
        emit DisperseToken(address(0), total);

        // if (total > msg.value), tx will revert
        uint256 ethToRefund = msg.value - total;

        for (uint256 i = 0; i < recipients.length; ++i)
            _safeTransferETHWithFallback(recipients[i], values[i]);

        if (ethToRefund > 0) _safeTransferETHWithFallback(msg.sender, ethToRefund);
    }

    function disperseToken(
        IERC20 token,
        address payable[] calldata recipients,
        uint256[] calldata values
    ) external onlyOwner {
        _disperseToken(token, recipients, values);
    }

    function disperseTokenWithPermit(
        IERC20 token,
        address payable[] calldata recipients,
        uint256[] calldata values, 
        PermitData calldata permitData
    )
        external
        payable
        onlyOwner
    {
        selfPermit(permitData);
        _disperseToken(token, recipients, values);
    }

    function _disperseToken(
        IERC20 token,
        address payable[] calldata recipients,
        uint256[] calldata values
    ) internal {
        uint256 total = 0;
        for (uint256 i = 0; i < recipients.length; ++i) total += values[i];
        token.safeTransferFrom(msg.sender, address(this), total);
        emit DisperseToken(address(token), total);
        for (uint256 i = 0; i < recipients.length; ++i)
            token.safeTransfer(recipients[i], values[i]);
    }

    function batchDisperse(DisperseData[] calldata disperseDatas)
        external
        payable
        onlyOwner
    {
        _batchDisperse(disperseDatas);
    }

    function batchDisperseWithPermit(
        DisperseData[] calldata disperseDatas,
        PermitData[] calldata permitDatas
    ) 
        external
        payable
        onlyOwner
    {
        batchSelfPermit(permitDatas);
        _batchDisperse(disperseDatas);
    }

    function _batchDisperse(DisperseData[] calldata disperseDatas) internal {
        uint256 disperseCount = disperseDatas.length;
        bool nativePoolAlreadyExist;
        for (uint256 i = 0; i < disperseCount; ++i) {
            if (address(disperseDatas[i].token) == address(0)) {
                if (nativePoolAlreadyExist) revert("Only one native disperse is allowed");
                nativePoolAlreadyExist = true;
                _disperseEther(
                    disperseDatas[i].recipients,
                    disperseDatas[i].values
                );
            } else {
                _disperseToken(
                    IERC20(disperseDatas[i].token),
                    disperseDatas[i].recipients,
                    disperseDatas[i].values
                );
            }
        }
    }

    // this method is identical to `disperseToken()` feature wise
    // the difference between `disperseToken()` and this method is that: 
    // instead of `transferFrom()` the caller only once, and using `transfer()` for each of the recipients; this method will call `transferFrom()` for each recipients.
    // `disperseToken()` choose to use `transfer()` for the recipients to save the gas costs for allowance checks, at the cost of one extra external call (`transferFrom` the caller to `address(this)`)
    // however, the saved amount can be less than the cost of the extra `transferFrom()`
    // this is where `disperseTokenSimple()` comes in, when the number of recipients is rather small, this method will be cheaper than `disperseToken()`
    // and the frontend should compare the gas costs of the two methods to choose which one to be used.
    function disperseTokenSimple(
        IERC20 token,
        address[] calldata recipients,
        uint256[] calldata values
    ) external onlyOwner {
        for (uint256 i = 0; i < recipients.length; ++i)
            token.transferFrom(msg.sender, recipients[i], values[i]);
    }

    // Functionality to call permit on any EIP-2612-compliant token
    function selfPermit(PermitData calldata permitData) public {
        IERC20Permit(permitData.token).permit(
            msg.sender,
            address(this),
            permitData.value,
            permitData.deadline,
            permitData.v,
            permitData.r,
            permitData.s
        );
    }

    function batchSelfPermit(
        PermitData[] calldata permitDatas
    ) public {
        for (uint256 i = 0; i < permitDatas.length; ++i) {
            selfPermit(permitDatas[i]);
        }
    }

    // arbitrary call for retrieving tokens, airdrops, and etc
    function ownerCall(
        address to,
        uint256 value,
        bytes calldata data
    ) external payable onlyOwner returns (bool success, bytes memory result) {
        (success, result) = to.call{value: value}(data);
    }

    /**
     * @notice Transfer ETH. If the ETH transfer fails, wrap the ETH and try send it as WETH.
     * @param to account who to send the ETH or WETH to
     * @param amount uint256 how much ETH or WETH to send
     */
    function _safeTransferETHWithFallback(address to, uint256 amount) internal {
        if (!_safeTransferETH(to, amount)) {
            wNATIVE.deposit{value: amount}();
            wNATIVE.transfer(to, amount);
        }
    }

    /**
     * @notice Transfer ETH and return the success status.
     * @dev This function only forwards 30,000 gas to the callee.
     * @param to account who to send the ETH to
     * @param value uint256 how much ETH to send
     */
    function _safeTransferETH(address to, uint256 value)
        internal
        returns (bool)
    {
        (bool success, ) = to.call{value: value, gas: 30_000}(new bytes(0));
        return success;
    }
}
