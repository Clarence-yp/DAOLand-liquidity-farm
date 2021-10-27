// SPDX-License-Identifier: MIT
pragma solidity ^0.8.6;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract Farming is AccessControl, ReentrancyGuard {
	using SafeERC20 for IERC20;
	
	bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
	
	struct CommonStakingInfo {
		uint256 rewardsPerEpoch;
		uint256 startTime;
		uint256 epochDuration;
		uint256 rewardsPerDeposit;
		uint256 rewardProduced;
		uint256 produceTime;
		uint256 pastProduced;
		uint256 totalStaked;
		uint256 totalDistributed;
		uint256 fineCoolDownTime;
		uint256 finePercent;
		uint256 accumulatedFine;
		address depositToken;
		address rewardToken;
	}

	struct Staker {
		uint256 amount;
		uint256 rewardAllowed;
		uint256 rewardDebt;
		uint256 distributed;
		uint256 noFineUnstakeOpenSince;
		uint256 requestedUnstakeAmount;
	}
	
	mapping(address => Staker) public stakers;
	
	// ERC20 DLD token staking to the contract
	// and DLS token earned by stakers as reward.
	ERC20 public depositToken;
	ERC20 public rewardToken;
	
	// Common contract configuration variables.
	uint256 public rewardsPerEpoch;
	uint256 public startTime;
	uint256 public epochDuration;
	
	uint256 public rewardsPerDeposit;
	uint256 public rewardProduced;
	uint256 public produceTime;
	uint256 public pastProduced;
	
	uint256 public totalStaked;
	uint256 public totalDistributed;
	
	uint256 public constant precision = 10 ** 20;
	uint256 public finePercent; // calcs with precision
	uint256 public fineCoolDownTime;
	uint256 public accumulatedFine;
	
	bool public isStakeAvailable = true;
	bool public isUnstakeAvailable = true;
	bool public isClaimAvailable = true;
	
	event tokensStaked(uint256 amount, uint256 time, address indexed sender);
	event tokensClaimed(uint256 amount, uint256 time, address indexed sender);
	event tokensUnstaked(
		uint256 amount,
		uint256 fineAmount_,
		uint256 time,
		address indexed sender
	);
	event requestedTokensUnstake(
		uint256 amount,
		uint256 requestApplyTimestamp,
		uint256 time,
		address indexed sender
	);
	
	constructor(
		uint256 _rewardsPerEpoch,
		uint256 _startTime,
		uint256 _epochDuration,
		uint256 _fineCoolDownTime,
		uint256 _finePercent,
		address _depositToken,
		address _rewardToken
	) {
		_setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
		_setupRole(ADMIN_ROLE, msg.sender);
		_setRoleAdmin(ADMIN_ROLE, DEFAULT_ADMIN_ROLE);
		
		rewardsPerEpoch = _rewardsPerEpoch;
		startTime = _startTime;
		
		epochDuration = _epochDuration;
		
		produceTime = _startTime;
		
		fineCoolDownTime = _fineCoolDownTime;
		finePercent = _finePercent;
		
		rewardToken = ERC20(_rewardToken);
		depositToken = ERC20(_depositToken);
	}

	/// @dev withdraw fines to sender by token address, if sender is admin
	function withdrawFine() external onlyRole(ADMIN_ROLE) {
		require(accumulatedFine > 0, "Farming: accumulated fine is zero");
		IERC20(depositToken).safeTransfer(
			msg.sender,
			accumulatedFine
		);
		accumulatedFine = 0;
	}

	/// @dev withdrawToken - withdraw token to sender by token address, if sender is admin
	function withdrawToken(address _token, uint256 _amount) 
		external
		onlyRole(ADMIN_ROLE) 
	{
		IERC20(_token).safeTransfer(
			msg.sender,
			_amount
		);
	}

	/// @dev set staking state (in terms of STM)	
	function setAvailability(bool[] calldata _state) external onlyRole(ADMIN_ROLE) {
		if (isStakeAvailable != _state[0]) {
			isStakeAvailable = _state[0];
		}
		if (isUnstakeAvailable != _state[1]) {
			isUnstakeAvailable = _state[1];
		}
		if (isClaimAvailable != _state[2]) {
			isClaimAvailable = _state[2];
		}
	}
	
	/// @dev setReward - sets amount of reward during `distributionTime`
	function setReward(uint256 _amount) external onlyRole(ADMIN_ROLE){
		pastProduced = _produced();
		produceTime = block.timestamp;
		rewardsPerEpoch = _amount;
	}
	
	function stake(uint256 _amount) external {
		require(isStakeAvailable, "Farming: stake is not available now");
		require(
			block.timestamp > startTime,
			"Farming: stake time has not come yet"
		);
		Staker storage staker = stakers[msg.sender];
		
		// Transfer specified amount of staking tokens to the contract
		IERC20(depositToken).safeTransferFrom(
			msg.sender,
			address(this),
			_amount
		);
		
		if (totalStaked > 0) {
			update();
		}
		staker.rewardDebt += (_amount * rewardsPerDeposit) / 1e20;
		
		totalStaked += _amount;
		staker.amount += _amount;
		
		update();
		emit tokensStaked(_amount, block.timestamp, msg.sender);
	}

	function unstake(uint256 _amount) external nonReentrant {
		require(isUnstakeAvailable, "Farming: unstake is not available now");
		Staker storage staker = stakers[msg.sender];
		
		require(
			staker.amount >= _amount,
			"Farming: not enough tokens to unstake"
		);
		
		update();
		
		staker.rewardAllowed += (_amount * rewardsPerDeposit / 1e20);
		staker.amount -= _amount;
		
		uint256 unstakeAmount_;
		uint256 fineAmount_;

		if (
			block.timestamp > staker.noFineUnstakeOpenSince
			|| _amount > staker.requestedUnstakeAmount
			|| staker.noFineUnstakeOpenSince == 0
			|| staker.requestedUnstakeAmount == 0
		) {
			fineAmount_ = finePercent * _amount / precision;
			unstakeAmount_ = _amount - fineAmount_;
			accumulatedFine += fineAmount_;
			if (
				staker.noFineUnstakeOpenSince == 0
				|| staker.requestedUnstakeAmount == 0
			) {
				staker.noFineUnstakeOpenSince = 0;
				staker.requestedUnstakeAmount = 0;
			}
		} else {
			unstakeAmount_ = _amount;
		}
		
		IERC20(depositToken).safeTransfer(msg.sender, unstakeAmount_);
		totalStaked -= _amount;
	
		emit tokensUnstaked(unstakeAmount_, fineAmount_, block.timestamp, msg.sender);
	}
		
	function requestUnstakeWithoutFine(uint256 amount) external {
		require(isUnstakeAvailable, "Farming: unstake is not available now");
		Staker storage staker = stakers[msg.sender];
		require(
			staker.amount >= amount,
			"Farming: not enough tokens to unstake"
		);
		
		require(
			staker.requestedUnstakeAmount <= amount,
			"Farming: you already have request with greater or equal amount"
		);
		
		staker.noFineUnstakeOpenSince = block.timestamp + fineCoolDownTime;
		staker.requestedUnstakeAmount = amount;
		emit requestedTokensUnstake(amount, staker.noFineUnstakeOpenSince, block.timestamp, msg.sender);
	}

	/// @dev claim available rewards
	function claim() external nonReentrant {
		require(isClaimAvailable, "Farming: claim is not available now");
		if (totalStaked > 0) 
			update();
		
		uint256 reward_ = _calcReward(msg.sender, rewardsPerDeposit);
		require(reward_ > 0, "Farming: nothing to claim");
		
		Staker storage staker = stakers[msg.sender];
		
		staker.distributed += reward_;
		totalDistributed += reward_;
		
		IERC20(rewardToken).safeTransfer(msg.sender, reward_);
		emit tokensClaimed(reward_, block.timestamp, msg.sender);
	}

	/// @dev core function, must be invoked after any balances changed
	function update() public {
		uint256 rewardProducedAtNow_ = _produced();
		if (rewardProducedAtNow_ > rewardProduced) {
			uint256 producedNew_ = rewardProducedAtNow_ - rewardProduced;
			if (totalStaked > 0) {
				rewardsPerDeposit = rewardsPerDeposit + (producedNew_ * 1e20 / totalStaked);
			}
			rewardProduced += producedNew_;
		}
	}

	/// @dev calculates the necessary parameters for staking
	function _produced() internal view returns (uint256) {
		return
		pastProduced + (rewardsPerEpoch * (block.timestamp - produceTime)) / epochDuration;
	}
	
	function _calcReward(address _user, uint256 _tps)
		internal
		view
		returns (uint256)
	{
		Staker memory staker_ = stakers[_user];
		return ((staker_.amount * _tps) / 1e20) + 
			staker_.rewardAllowed - staker_.distributed - staker_.rewardDebt;
	}

	function getCommonStakingInfo() external view returns(CommonStakingInfo memory) {
		return CommonStakingInfo({
		rewardsPerEpoch: rewardsPerEpoch,
		startTime: startTime,
		epochDuration: epochDuration,
		rewardsPerDeposit: rewardsPerDeposit,
		rewardProduced: rewardProduced,
		produceTime: produceTime,
		pastProduced: pastProduced,
		totalStaked: totalStaked,
		totalDistributed: totalDistributed,
		fineCoolDownTime: fineCoolDownTime,
		finePercent: finePercent,
		accumulatedFine: accumulatedFine,
		depositToken: address(depositToken),
		rewardToken: address(rewardToken)
		});
	}

	function getUserInfo(address _user) external view returns (Staker memory) {
		Staker memory staker = stakers[_user];
		return Staker({
			amount: staker.amount,
			rewardAllowed: getRewardInfo(_user),
			rewardDebt: staker.rewardDebt,
			distributed: staker.distributed,
			noFineUnstakeOpenSince: staker.noFineUnstakeOpenSince,
			requestedUnstakeAmount: staker.requestedUnstakeAmount
		});
	}
	
	/// @dev returns available reward of staker
	function getRewardInfo(address _user) public view returns (uint256) {
		uint256 rewardsPerDeposit_ = rewardsPerDeposit;
		if (totalStaked > 0) {
			uint256 rewardProducedAtNow_ = _produced();
			if (rewardProducedAtNow_ > rewardProduced) {
				uint256 producedNew_ = rewardProducedAtNow_ - rewardProduced;
				rewardsPerDeposit_ += ((producedNew_ * 1e20) / totalStaked);
			}
		}
		uint256 reward_ = _calcReward(_user, rewardsPerDeposit_);
		
		return reward_;
	}
}
