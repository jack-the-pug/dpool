// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.15;

import {IERC20} from "./interfaces/IERC20.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import "./BasePool.sol";

contract DistributionPool is BasePool {
    using SafeTransferLib for IERC20;

    enum PoolStatus {
        None, // not exists
        Initialized, // unfunded
        Funded, // funded
        Closed // canceled or fully distributed
    }

    struct PoolData {
        string name;
        address distributor;
        IERC20 token;
        uint48 startTime;
        uint48 deadline;
        uint128 totalAmount;
        uint128 claimedAmount;
        uint128 fundedAmount;
        address[] claimers;
        uint128[] amounts;
    }

    struct PoolInfo {
        string name;
        IERC20 token;
        address distributor;
        bool fundNow;
        address[] claimers;
        uint128[] amounts;
        uint48 startTime;
        uint48 deadline;
    }

    uint256 private locked = 1;

    uint256 public lastPoolId;

    mapping(uint256 => PoolData) public pools;
    mapping(uint256 => PoolStatus) public poolsStatus;
    mapping(address => mapping(uint256 => uint256)) public userClaimedAmount;

    event Created(uint256 indexed poolId);
    event Canceled(uint256 indexed poolId);
    event Claimed(uint256 indexed poolId, address claimer);
    event Funded(uint256 indexed poolId, address funder);
    event Distributed(uint256 indexed poolId);

    constructor(address _wNATIVE) BasePool(_wNATIVE) {
    }

    function initialize(address _owner) override public {
        super.initialize(_owner);
        // initialize ReentrancyGuard
        locked = 1;
    }

    modifier nonReentrant() {
        require(locked == 1, "REENTRANCY");
        locked = 2;
        _;
        locked = 1;
    }

    /// Create a new distribution pool
    function create(PoolInfo calldata poolInfo)
        external
        payable
        nonReentrant
        onlyOwner
        returns (uint256)
    {
        return _create(poolInfo);
    }

    function createWithPermit(
        PoolInfo calldata poolInfo,
        PermitData calldata permitData
    ) 
        external
        payable
        nonReentrant
        onlyOwner
        returns (uint256)
    {
        selfPermit(permitData);
        return _create(poolInfo);
    }

    function batchCreate(PoolInfo[] calldata poolInfos)
        external
        payable
        nonReentrant
        onlyOwner
        returns (uint256[] memory)
    {
        return _batchCreate(poolInfos);
    }

    function batchCreateWithPermit(PoolInfo[] calldata poolInfos, PermitData[] calldata permitDatas)
        external
        payable
        nonReentrant
        onlyOwner
        returns (uint256[] memory)
    {
        batchSelfPermit(permitDatas);
        return _batchCreate(poolInfos);
    }

    function _create(PoolInfo calldata poolInfo)
        internal
        returns (uint256 poolId)
    {
        require(
            poolInfo.startTime > block.timestamp,
            "startTime must be in the future"
        );
        require(
            poolInfo.deadline > poolInfo.startTime,
            "deadline must be after startTime"
        );
        uint128 totalAmount;
        {
            uint256 claimersLength = poolInfo.claimers.length;
            require(claimersLength > 0, "must specify at least one claimer");
            uint256 amountsLength = poolInfo.amounts.length;
            require(
                claimersLength == amountsLength,
                "length of claimers and amounts must be equal"
            );
            require(
                poolInfo.claimers[0] != address(0),
                "claimer must be a valid address"
            );
            require(
                poolInfo.amounts[0] > 0,
                "amount must be greater than 0"
            );

            // set totalAmount to first claimer
            totalAmount = poolInfo.amounts[0];
            
            // then start iterating from second claimer onwards (if claimersLength >= 2)
            for (uint256 i = 1; i < claimersLength; ++i) {
                require(
                    poolInfo.amounts[i] > 0,
                    "amount must be greater than 0"
                );
                // address 0 check is not needed because the first claimer address already checked above 
                require(
                    poolInfo.claimers[i] > poolInfo.claimers[i - 1],
                    "Not sorted or duplicate"
                );
                // will revert on overflow when `totalAmount + poolInfo.amounts[i] > type(uint128).max`
                totalAmount += poolInfo.amounts[i];
            }
        }
        poolId = ++lastPoolId;
        uint128 receivedAmount;
        if (poolInfo.fundNow) {
            receivedAmount = _receiveOrPullFundsFromMsgSender(
                poolInfo.token,
                totalAmount
            );
            poolsStatus[poolId] = PoolStatus.Funded;
        } else {
            poolsStatus[poolId] = PoolStatus.Initialized;
        }
        pools[poolId] = PoolData({
            name: poolInfo.name,
            distributor: poolInfo.distributor,
            token: poolInfo.token,
            startTime: poolInfo.startTime,
            deadline: poolInfo.deadline,
            totalAmount: totalAmount,
            fundedAmount: receivedAmount,
            claimedAmount: 0,
            claimers: poolInfo.claimers,
            amounts: poolInfo.amounts
        });
        emit Created(poolId);
        return poolId;
    }

    function _batchCreate(PoolInfo[] calldata poolInfos)
        internal
        returns (uint256[] memory)
    {
        uint256 poolCount = poolInfos.length;
        uint256[] memory poolIds = new uint256[](poolCount);
        bool nativePoolAlreadyExist;
        for (uint256 i = 0; i < poolCount; ++i) {
            // only one native pool is allowed in batch create
            // because `msg.value` is used to fund the pool
            if (address(poolInfos[i].token) == address(0)) {
                if (nativePoolAlreadyExist) revert("Only one native pool is allowed");
                nativePoolAlreadyExist = true;
            }
            poolIds[i] = _create(poolInfos[i]);
        }
        return poolIds;
    }

    /// @notice claim tokens from a pool
    /// @dev nonReentrant check in single method.
    function claim(uint256[] calldata _poolIds, uint256[] calldata _indexes) external nonReentrant {
        uint256 poolIdsLength = _poolIds.length;
        for (uint256 i = 0; i < poolIdsLength; ++i) {
            _claimSinglePool(_poolIds[i], _indexes[i]);
        }
    }

    function claimSinglePool(uint256 _poolId, uint256 _index) external nonReentrant {
        _claimSinglePool(_poolId, _index);
    }

    function _claimSinglePool(uint256 _poolId, uint256 _index) internal {
        require(
            poolsStatus[_poolId] == PoolStatus.Funded,
            "pool must be funded"
        );
        PoolData storage pool = pools[_poolId];
        require(block.timestamp > pool.startTime, "claim not started yet");
        require(block.timestamp < pool.deadline, "claim deadline passed");
        if (pool.claimers[_index] == msg.sender) {
            return
                _claimTokenIfUnclaimed(
                    _poolId,
                    msg.sender,
                    pool.amounts[_index],
                    pool
                );
        }
    }

    function _claimTokenIfUnclaimed(
        uint256 _poolId,
        address _claimer,
        uint128 _amount,
        PoolData storage pool
    ) internal {
        if (userClaimedAmount[_claimer][_poolId] == 0) {
            pool.claimedAmount += _amount;
            // if all the tokens are claimed, so we can close the pool (in some cases there may left some tokens, owner can make a `sweepToken` to get them back)
            if (pool.claimedAmount == pool.totalAmount) {
                poolsStatus[_poolId] = PoolStatus.Closed;
            }
            userClaimedAmount[_claimer][_poolId] = _amount;
            if (address(pool.token) == address(0)) {
                _safeTransferETHWithFallback(_claimer, _amount);
            } else {
                pool.token.safeTransfer(_claimer, _amount);
            }
            emit Claimed(_poolId, _claimer);
        }
    }

    /// fund a pool
    function fund(uint256 _poolId) external payable nonReentrant {
        _fundSinglePool(pools[_poolId], _poolId);
    }

    function fundWithPermit(
        uint256 _poolId,
        PermitData calldata permitData
    )
        external
        payable
        nonReentrant
    {
        selfPermit(permitData);
        _fundSinglePool(pools[_poolId], _poolId);
    }

    function batchFund(uint256[] calldata _poolIds) external payable nonReentrant {
        _batchFund(_poolIds);
    }

    function batchFundWithPermit(
        uint256[] calldata _poolIds,
        PermitData[] calldata permitDatas
    )
        external
        payable
        nonReentrant
    {
        batchSelfPermit(permitDatas);
        return _batchFund(_poolIds);
    }

    function _fundSinglePool(PoolData storage pool, uint256 _poolId) internal {
        require(
            poolsStatus[_poolId] == PoolStatus.Initialized,
            "pool must be pending"
        );
        pool.fundedAmount = _receiveOrPullFundsFromMsgSender(
            pool.token,
            pool.totalAmount
        );
        poolsStatus[_poolId] = PoolStatus.Funded;
        emit Funded(_poolId, msg.sender);
    }

    function _batchFund(uint256[] calldata _poolIds)
        internal
    {
        bool nativePoolAlreadyExist;
        for (uint256 i = 0; i < _poolIds.length; ++i) {
            PoolData storage pool = pools[_poolIds[i]];
            if (address(pool.token) == address(0)) {
                if (nativePoolAlreadyExist) revert("Only one native is allowed");
                nativePoolAlreadyExist = true;
            }
            _fundSinglePool(pool, _poolIds[i]);
        }
    }

    /// distribute tokens
    function distribute(uint256 _poolId) external payable nonReentrant {
        _distributeSinglePool(_poolId);
    }

    function distributeWithPermit(
        uint256 _poolId,
        PermitData calldata permitData
    )
        external
        payable
        nonReentrant
    {
        selfPermit(permitData);
        _distributeSinglePool(_poolId);
    }

    function batchDistribute(uint256[] calldata _poolIds) external nonReentrant {
        for (uint256 i = 0; i < _poolIds.length; ++i) {
            _distributeSinglePool(_poolIds[i]);
        }
    }

    function _distributeSinglePool(uint256 _poolId) internal {
        PoolData storage pool = pools[_poolId];
        require(
            pool.distributor == msg.sender,
            "only distributor can distribute"
        );
        if (poolsStatus[_poolId] == PoolStatus.Initialized) {
            _fundSinglePool(pool, _poolId);
        } else {
            require(
                poolsStatus[_poolId] == PoolStatus.Funded,
                "pool must be funded"
            );
        }
        uint256 claimerLength = pool.claimers.length;
        for (uint256 i = 0; i < claimerLength; ++i) {
            _claimTokenIfUnclaimed(
                _poolId,
                pool.claimers[i],
                pool.amounts[i],
                pool
            );
        }
        emit Distributed(_poolId);
    }

    /// @dev cancel a pool and get unclaimed tokens back
    function cancel(uint256[] calldata _poolIds) external onlyOwner nonReentrant {
        for (uint256 i = 0; i < _poolIds.length; ++i) {
            _cancelSinglePool(_poolIds[i]);
        }
    }

    /// @notice refundable tokens will return to msg.sender
    function _cancelSinglePool(uint256 _poolId) internal {
        require(
            poolsStatus[_poolId] != PoolStatus.Closed,
            "pool already closed"
        );
        PoolData storage pool = pools[_poolId];
        require(
            pool.startTime > block.timestamp || pool.deadline < block.timestamp,
            "ongoing pool can not be canceled"
        );
        poolsStatus[_poolId] = PoolStatus.Closed;
        uint128 refundableAmount = pool.fundedAmount - pool.claimedAmount;
        if (refundableAmount > 0) {
            if (address(pool.token) == address(0)) {
                _safeTransferETHWithFallback(msg.sender, refundableAmount);
            } else {
                pool.token.safeTransfer(msg.sender, refundableAmount);
            }
        }
        emit Canceled(_poolId);
    }

    function _receiveOrPullFundsFromMsgSender(IERC20 token, uint128 wantAmount)
        internal
        returns (uint128 receivedAmount)
    {
        if (address(token) == address(0)) {
            require(msg.value == wantAmount, "!msg.value");
            receivedAmount = wantAmount;
        } else {
            // no need to require msg.value == 0 here
            // the owner can always use `sweepToken` to get eth back
            uint128 tokenBalanceBefore = _safeUint128(
                token.balanceOf(address(this))
            );
            token.safeTransferFrom(msg.sender, address(this), wantAmount);
            receivedAmount =
                _safeUint128(token.balanceOf(address(this))) -
                tokenBalanceBefore;
            // this check ensures the token is not a fee-on-transfer token
            // which is not supported yet
            require(
                receivedAmount >= wantAmount,
                "received token amount must be greater than or equal to wantAmount"
            );
        }
    }

    // internal utils
    function _safeUint128(uint256 x) internal pure returns (uint128) {
        require(x < type(uint128).max, "!uint128.max");
        return uint128(x);
    }

    function getPoolById(uint256 poolId)
        external
        view
        returns (PoolData memory, PoolStatus)
    {
        return (pools[poolId], poolsStatus[poolId]);
    }
}