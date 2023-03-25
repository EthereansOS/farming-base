///SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IERC20Token {
    function balanceOf(address owner) external view returns (uint);
    function transfer(address to, uint value) external returns (bool);
}

library SafeMath {
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x, 'ds-math-add-overflow');
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x, 'ds-math-sub-underflow');
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, 'ds-math-mul-overflow');
    }
}

interface IFarmingLiquidityProvider {
    function totalFarmingLiquidity() external view returns(uint256);
    function setNextRebalanceEvent(uint256 nextRebalanceEvent) external;
}

contract BaseFarming {
    using SafeMath for uint256;

    struct FarmingPosition {
        uint256 rewardTokenToRedeem;
        uint256 rewardPerTokenPaid;
        uint256 lastLiquidityBalance;
    }

    uint256 public constant FULL_PRECISION = 1e18;
    uint256 public constant TIME_SLOT_IN_SECONDS = 15;

    address public farmingLiquidityProvider;
    address public rewardToken;
    uint256 public rebalanceIntervalInEventSlots;
    uint256 public startEvent;
    uint256 public lastUpdateEvent;
    uint256 public nextRebalanceEvent;

    uint256 private _rewardPerEvent;
    uint256 private _rewardPerTokenStored;
    uint256 private _reservedBalance;
    uint256 private _previousLiquidityPoolTotalSupply;

    bool internal _resetOnly;
    bool internal _inhibitCallback;

    uint256 public totalFarmingLiquidity;

    mapping(address => FarmingPosition) private _positions;

    /// @notice Get the reward per event for the current season
    /// divided by the farming additional precision
    function rewardPerEvent() public view returns(uint256) {
        return _rewardPerEvent / FULL_PRECISION;
    }

    /// @notice Get the reserved balance for the current season
    /// divided by the farming additional precision
    function reservedBalance() public view returns(uint256) {
        return _reservedBalance / FULL_PRECISION;
    }

    function _increaseReservedBalance(uint256 amount) internal {
        _reservedBalance = _reservedBalance.add(amount * FULL_PRECISION);
    }

    function _decreaseReservedBalance(uint256 amount) internal {
        _reservedBalance = _reservedBalance.sub(amount * FULL_PRECISION);
    }

    function calculateIfThereIsMoreReward() external view returns(uint256 seasonReward) {
        return _calculateIfThereIsMoreReward(_resetOnly);
    }

    function _claimReward(address account, address[] memory rewardReceivers, uint256[] memory rewardReceiversPercentage) internal returns(uint256 claimedReward, uint256 _nextRebalanceEvent, uint256 rewardPerEvent_) {
        uint lastLiquidityBalance = _positions[account].lastLiquidityBalance;
        (_nextRebalanceEvent, rewardPerEvent_) = _tryRebalance(_totalSupply(), lastLiquidityBalance == 0, false);
        claimedReward = _syncPosition(
            account,
            lastLiquidityBalance,
            rewardReceivers,
            rewardReceiversPercentage
        );
    }

    /// @notice Sync positions and try to rebalance and start farming seasons
    function _sync(
        address from,
        address to,
        uint256 fromLiquidityPoolTokenBalance,
        uint256 toLiquidityPoolTokenBalance,
        uint256 liquidityPoolTotalSupply
    ) internal returns(uint256 _nextRebalanceEvent) {

        (_nextRebalanceEvent,) = _tryRebalance(liquidityPoolTotalSupply, false, false);

        address[] memory voidRewardReceivers = new address[](0);
        uint256[] memory voidRewardReceiversPercentage = new uint256[](0);

        if (from != address(0)) _syncPosition(from, fromLiquidityPoolTokenBalance, voidRewardReceivers, voidRewardReceiversPercentage);
        if (to != address(0)) _syncPosition(to, toLiquidityPoolTokenBalance, voidRewardReceivers, voidRewardReceiversPercentage);
    }

    /// @notice Start and stop the farming perpetual seasons. If the season is started compute the _rewardPerTokenStored
    /// @param _nextRebalanceEvent is updated after season is started (or stopped)
    /// @param rewardPerEvent_ is returned in his correct precision, so is divided by PRECISION
    function _tryRebalance(uint256 liquidityPoolTotalSupply, bool inhibit, bool reset) internal returns(uint256 _nextRebalanceEvent, uint256 rewardPerEvent_) {
        /// @dev Gas savings for Optimism L1 blocks static call
        /// and variables that are loaded from storage
        uint256 blockEventstamp = block.timestamp;
        uint256 previousLiquidityPoolTotalSupply = _previousLiquidityPoolTotalSupply;
        uint256 _startEvent = startEvent;
        uint256 _lastUpdateEvent = lastUpdateEvent;

        /// @dev Gas savings reusing output variables
        _nextRebalanceEvent = nextRebalanceEvent;
        rewardPerEvent_ = _rewardPerEvent;

        /// @notice Compute the rewards for the time interval (if the season is started)
        if(_nextRebalanceEvent != 0) {
            uint256 currentEvent = blockEventstamp < _nextRebalanceEvent ? blockEventstamp : _nextRebalanceEvent;

            /// @dev Inhibit the _rewardPerTokenStored update when inhibit variable is true.
            /// This is used for bypass incorrect _rewardPerTokenStored updates in the _tryRebalance function.
            if(!inhibit && previousLiquidityPoolTotalSupply != 0) {
                uint256 computedLastUpdateEvent = _lastUpdateEvent < _startEvent ? _startEvent : _lastUpdateEvent;
                _rewardPerTokenStored = _rewardPerTokenStored.add(((((currentEvent.sub(computedLastUpdateEvent)))).mul(rewardPerEvent_)) / previousLiquidityPoolTotalSupply);
                lastUpdateEvent = currentEvent;
            }
        }

        _previousLiquidityPoolTotalSupply = liquidityPoolTotalSupply;

        /// @notice Start (or stop) the new season
        if(reset || blockEventstamp >= _nextRebalanceEvent || liquidityPoolTotalSupply == 0) {
            uint256 reservedBalance_ = _reservedBalance;

            if (_nextRebalanceEvent > blockEventstamp) {
                reservedBalance_ = reservedBalance_.sub((((_nextRebalanceEvent.sub(blockEventstamp))).mul(rewardPerEvent_)));
            }

            /// @dev Using lastUpdateEvent storage variable to store the value
            lastUpdateEvent = 0;

            /// @dev Gas savings using memory variables
            _startEvent = 0;
            _nextRebalanceEvent = 0;
            rewardPerEvent_ = 0;

            uint256 seasonReward = _calculateIfThereIsMoreReward(reset);

            /// @notice Update the _nextRebalanceEvent, _rewardPerEvent, _reservedBalance
            /// for the new starting season
            if(seasonReward > 0 && liquidityPoolTotalSupply != 0) {
                uint256 _rebalanceIntervalInEvents = rebalanceIntervalInEventSlots.mul(TIME_SLOT_IN_SECONDS);

                _startEvent = blockEventstamp;
                reservedBalance_ = reservedBalance_.add(seasonReward);
                _nextRebalanceEvent = blockEventstamp.add(_rebalanceIntervalInEvents);
                rewardPerEvent_ = seasonReward / _rebalanceIntervalInEvents;
            }

            /// @dev Update storage output variables after changing values
            startEvent = _startEvent;
            _reservedBalance = reservedBalance_;
            nextRebalanceEvent = _nextRebalanceEvent;
            _rewardPerEvent = rewardPerEvent_;

            _tryNotifyNewRebalanceEvent(_nextRebalanceEvent);

        }

        /// @notice Output variables
        /// _rewardPerEvent is returned in his correct precision, so is divided by PRECISION
        /// nextRebalanceEvent is updated after season is started (or stopped)
        rewardPerEvent_ = rewardPerEvent_ / FULL_PRECISION;

    }

    /// @notice Calculate the reward for the `account` position
    function _calculateRewardUntilNow(address account) private view returns(uint256 reward) {
        reward = (_rewardPerTokenStored.sub(_positions[account].rewardPerTokenPaid)).mul(_positions[account].lastLiquidityBalance);
    }

    /// @notice Sync `account` position and eventually claim the accrued reward
    function _syncPosition(address account, uint256 liquidityPoolTokenBalance, address[] memory rewardReceivers, uint256[] memory rewardReceiversPercentage) private returns (uint256 claimedReward) {
        FarmingPosition memory position = _positions[account];

        /// @dev Inline definitions for gas savings
        position.rewardTokenToRedeem = position.rewardTokenToRedeem.add(_calculateRewardUntilNow(account));
        position.lastLiquidityBalance = liquidityPoolTokenBalance;
        position.rewardPerTokenPaid = _rewardPerTokenStored;

        /// @dev Claim the accrued reward
        if (_checkRewardParameters(rewardReceivers, rewardReceiversPercentage)) {
            /// @dev claimedReward is divided by PRECISION to transfer the correct amount
            claimedReward = position.rewardTokenToRedeem / FULL_PRECISION;

            if (claimedReward > 0) {
                uint256 rebuiltReward;
                /// @dev Decrement accrued reward (rebuiltReward) from _reservedBalance and position.rewardTokenToRedeem in 10**18 precision
                _reservedBalance = _reservedBalance.sub(rebuiltReward = claimedReward.mul(FULL_PRECISION));
                position.rewardTokenToRedeem = position.rewardTokenToRedeem.sub(rebuiltReward);

                /// @dev Send reward tokens to the reward receivers
                _transferReward(claimedReward, rewardReceivers, rewardReceiversPercentage);
            }
        }

        /// @dev Reassign memory position to storage _positions
        _positions[account] = position;
    }

    function _transferReward(uint256 claimedReward, address[] memory rewardReceivers, uint256[] memory rewardReceiversPercentage) private {
        address _rewardToken = rewardToken;
        uint256 remainingAmount = claimedReward;
        for(uint256 i = 0; i < rewardReceiversPercentage.length; i++) {
            uint256 value = _calculatePercentage(claimedReward, rewardReceiversPercentage[i]);
            _safeTransfer(_rewardToken, rewardReceivers[i], value);
            remainingAmount -= value;
        }
        _safeTransfer(_rewardToken, rewardReceivers[rewardReceivers.length - 1], remainingAmount);
    }

    function _checkRewardParameters(address[] memory rewardReceivers, uint256[] memory rewardReceiversPercentage) private pure returns(bool) {
        if(rewardReceivers.length == 0) {
            return false;
        }
        require(rewardReceiversPercentage.length == (rewardReceivers.length - 1), "percentage");
        uint256 availableAmount = FULL_PRECISION;
        for(uint256 i = 0; i < rewardReceiversPercentage.length; i++) {
            uint256 percentage = rewardReceiversPercentage[i];
            require(percentage != 0 && percentage < availableAmount, "percentage");
            availableAmount -= percentage;
        }
        require(availableAmount != 0, "percentage");
        return true;
    }

    function _calculatePercentage(uint256 total, uint256 percentage) internal pure returns (uint256) {
        return (total * ((percentage * 1e18) / FULL_PRECISION)) / 1e18;
    }

    function _safeTransfer(address tokenAddress, address to, uint256 value) internal {
        if(value == 0) {
            return;
        }
        if(to == address(this)) {
            return;
        }
        if(tokenAddress == address(0)) {
            require(_sendETH(to, value), 'FARMING: TRANSFER_FAILED');
            return;
        }
        if(to == address(0)) {
            return _safeBurn(tokenAddress, value);
        }
        (bool success, bytes memory data) = tokenAddress.call(abi.encodeWithSelector(IERC20Token(address(0)).transfer.selector, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'FARMING: TRANSFER_FAILED');
    }

    function _safeBurn(address erc20TokenAddress, uint256 value) internal {
        (bool result, bytes memory returnData) = erc20TokenAddress.call(abi.encodeWithSelector(0x42966c68, value));//burn(uint256)
        result = result && (returnData.length == 0 || abi.decode(returnData, (bool)));
        if(!result) {
            (result, returnData) = erc20TokenAddress.call(abi.encodeWithSelector(IERC20Token(erc20TokenAddress).transfer.selector, address(0), value));
            result = result && (returnData.length == 0 || abi.decode(returnData, (bool)));
        }
        if(!result) {
            (result, returnData) = erc20TokenAddress.call(abi.encodeWithSelector(IERC20Token(erc20TokenAddress).transfer.selector, 0x000000000000000000000000000000000000dEaD, value));
            result = result && (returnData.length == 0 || abi.decode(returnData, (bool)));
        }
        if(!result) {
            (result, returnData) = erc20TokenAddress.call(abi.encodeWithSelector(IERC20Token(erc20TokenAddress).transfer.selector, 0xdeaDDeADDEaDdeaDdEAddEADDEAdDeadDEADDEaD, value));
            result = result && (returnData.length == 0 || abi.decode(returnData, (bool)));
        }
    }

    function _sendETH(address to, uint256 value) private returns(bool) {
        assembly {
            let res := call(gas(), to, value, 0, 0, 0, 0)
        }
        return true;
    }

    function _balanceOf(address tokenAddress) private view returns(uint256) {
        return tokenAddress == address(0) ? address(this).balance : IERC20Token(tokenAddress).balanceOf(address(this));
    }

    function _tryNotifyNewRebalanceEvent(uint256 _nextRebalanceEvent) private {
        if(_inhibitCallback) {
            return;
        }
        /// @dev Gas savings to avoid multiple storage loads
        address _farmingLiquidityProvider = farmingLiquidityProvider;

        /// @notice Set the new _nextRebalanceEvent to the farmingliquidityprovider if the caller is not the farmingliquidityprovider
        if(msg.sender != _farmingLiquidityProvider) {
            IFarmingLiquidityProvider(_farmingLiquidityProvider).setNextRebalanceEvent(_nextRebalanceEvent);
        }
    }

    function _totalSupply() internal view returns(uint256) {
        address _farmingLiquidityProvider = farmingLiquidityProvider;
        return _farmingLiquidityProvider == address(this) ? totalFarmingLiquidity : IFarmingLiquidityProvider(_farmingLiquidityProvider).totalFarmingLiquidity();
    }

    function _calculateIfThereIsMoreReward(bool reset) private view returns(uint256 seasonReward) {
        seasonReward = _resetOnly && !reset ? 0 : (_balanceOf(rewardToken).mul(FULL_PRECISION)).sub(_reservedBalance);
    }

    function _initialize(address _farmingLiquidityProvider, uint256 _rebalanceIntervalInEvents) internal {
        require(farmingLiquidityProvider == address(0), 'Farming: ALREADY_INITIALIZED');
        require((farmingLiquidityProvider =_farmingLiquidityProvider) != address(0), 'Farming: LIQUIDITY_PROVIDER');
        rebalanceIntervalInEventSlots = _rebalanceIntervalInEvents / TIME_SLOT_IN_SECONDS;
    }

    function _receive() internal view {
        require(rewardToken == address(0));
        require(msg.sig == bytes4(0));
        require(keccak256(msg.data) == keccak256(""));
    }
}