// SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract Math {
    using SafeMath for uint256;
    uint256 private constant EXP_SCALE = 1e18;
    uint256 private constant HALF_EXP_SCALE = EXP_SCALE / 2;

    function getExp(uint256 num, uint256 denom)
        internal
        pure
        returns (uint256)
    {
        (bool successMul, uint256 scaledNumber) = num.tryMul(EXP_SCALE);
        if (!successMul) return 0;
        (bool successDiv, uint256 rational) = scaledNumber.tryDiv(denom);
        if (!successDiv) return 0;
        return rational;
    }

    function mulExp(uint256 a, uint256 b) internal pure returns (uint256) {
        (bool successMul, uint256 doubleScaledProduct) = a.tryMul(b);
        if (!successMul) return 0;
        (
            bool successAdd,
            uint256 doubleScaledProductWithHalfScale
        ) = HALF_EXP_SCALE.tryAdd(doubleScaledProduct);
        if (!successAdd) return 0;
        (bool successDiv, uint256 product) = doubleScaledProductWithHalfScale
            .tryDiv(EXP_SCALE);
        assert(successDiv == true);
        return product;
    }

    function percentage(uint256 _num, uint256 _percentage)
        internal
        pure
        returns (uint256)
    {
        uint256 rational = getExp(_num, 5);
        return mulExp(rational, _percentage);
    }
}

contract CRYPTONICS is ERC20Burnable, Ownable, Math {
    using SafeMath for uint256;
    uint256 public totalBorrowed;
    uint256 public totalReserve;
    uint256 public totalDeposit;
    uint256 public maxLTV = 4; // 1 = 20%
    uint256 public ethTreasury;
    uint256 public totalCollateral;
    uint256 public baseRate = 20000000000000000;
    uint256 public fixedAnnuBorrowRate = 300000000000000000;
    uint256 public rewardRatePerMinute = 694444444444444 wei; // 0.1 divided by 1440 (number of minutes in a day)

    AggregatorV3Interface internal constant priceFeed = AggregatorV3Interface(0x9326BFA02ADD2366b30bacB125260Af641031331);

    mapping(address => uint256) private usersCollateral;
    mapping(address => uint256) private usersBorrowed;
    mapping(address => uint256) private lastRewardTime;
    mapping(address => uint256) private rewardPoints; // Accumulated reward points

    constructor(address initialOwner) Ownable(initialOwner) ERC20("CRYPTONICS", "CPT") {}

    // Set a fixed exchange rate
    function getExchangeRate() public pure returns (uint256) {
        return 100000000000000000000000000; // 0.0000000001 Ether = 1 CRYPTONICS token
    }

    // Bond ETH and accumulate reward points
    function bondAsset(uint256 _amount) external payable {
        totalDeposit += _amount;
        uint256 pointsToEarn = _amount.mul(rewardRatePerMinute).mul(60); // Accumulate reward points based on time and amount
        rewardPoints[msg.sender] = rewardPoints[msg.sender].add(pointsToEarn);
        lastRewardTime[msg.sender] = block.timestamp;
    }

    // Unbond CPT tokens and receive ETH
    function unbondAsset(uint256 _amount) external {
        uint256 ethToReceive = mulExp(_amount, getExchangeRate());
        totalDeposit -= ethToReceive;
        burn(_amount);
        payable(msg.sender).transfer(ethToReceive);
        lastRewardTime[msg.sender] = block.timestamp;
    }

    // Add collateral
    function addCollateral(uint256 _amount) external payable {
        require(_amount > 0, "Can't send 0 ethers");
        usersCollateral[msg.sender] += _amount;
        totalCollateral += _amount;
        lastRewardTime[msg.sender] = block.timestamp;
    }

    // Remove collateral
    function removeCollateral(uint256 _amount) external {
        uint256 wethPrice = 1; // Set a fixed value
        uint256 collateral = usersCollateral[msg.sender];
        require(collateral > 0, "Don't have any collateral");
        uint256 borrowed = usersBorrowed[msg.sender];
        uint256 amountLeft = mulExp(collateral, wethPrice).sub(borrowed);
        uint256 amountToRemove = mulExp(_amount, wethPrice);
        require(amountToRemove < amountLeft, "Not enough collateral to remove");
        usersCollateral[msg.sender] -= _amount;
        totalCollateral -= _amount;
        payable(msg.sender).transfer(_amount);
        lastRewardTime[msg.sender] = block.timestamp;
    }

    // Borrow ETH
    function borrow(uint256 _amount) external {
        usersBorrowed[msg.sender] += _amount;
        totalBorrowed += _amount;
        lastRewardTime[msg.sender] = block.timestamp;
    }

    // Repay borrowed ETH
    function repay(uint256 _amount) external payable {
        require(usersBorrowed[msg.sender] > 0, "No debt to repay");
        (uint256 fee, uint256 paid) = calculateBorrowFee(_amount);
        usersBorrowed[msg.sender] -= paid;
        totalBorrowed -= paid;
        totalReserve += fee;
        lastRewardTime[msg.sender] = block.timestamp;
    }

    // Calculate borrowing fee
    function calculateBorrowFee(uint256 _amount)
        public
        pure
        returns (uint256, uint256)
    {
        uint256 borrowRate = 0; // Set to zero as Aave is not working
        uint256 fee = mulExp(_amount, borrowRate);
        uint256 paid = _amount.sub(fee);
        return (fee, paid);
    }

    // Liquidate user's assets if LTV exceeds the maximum
    function liquidation(address _user) external onlyOwner {
        uint256 wethPrice = 1; // Set a fixed value
        uint256 collateral = usersCollateral[_user];
        uint256 borrowed = usersBorrowed[_user];
        uint256 collateralToUsd = mulExp(wethPrice, collateral);
        if (borrowed > percentage(collateralToUsd, maxLTV)) {
            uint256 amountEth = collateral; // Set collateral as the amount
            totalReserve += amountEth;
            usersBorrowed[_user] = 0;
            usersCollateral[_user] = 0;
            totalCollateral -= collateral;
            payable(_user).transfer(amountEth);
        }
    }

    // Get available cash
    function getCash() public view returns (uint256) {
        return totalDeposit.sub(totalBorrowed);
    }

    // Get the borrowing limit
    function _borrowLimit() public view returns (uint256) {
        uint256 amountLocked = usersCollateral[msg.sender];
        require(amountLocked > 0, "No collateral found");
        uint256 amountBorrowed = usersBorrowed[msg.sender];
        uint256 wethPrice = 1; // Set a fixed value
        uint256 amountLeft = mulExp(amountLocked, wethPrice).sub(
            amountBorrowed
        );
        return percentage(amountLeft, maxLTV);
    }

    // Get CPT balance of an account
    function getCPTBalance(address account) external view returns (uint256) {
        return balanceOf(account);
    }

    // Get the last reward time of a user
    function getLastRewardTime(address user) external view returns (uint256) {
        return lastRewardTime[user];
    }

    // Calculate rewards based on the elapsed time
    function calculateRewards(address user) public view returns (uint256) {
        uint256 timeElapsed = block.timestamp.sub(lastRewardTime[user]);
        return timeElapsed.mul(rewardRatePerMinute);
    }

    // Claim rewards and mint CPT tokens based on accumulated reward points
    function claimRewards() external {
        uint256 rewards = rewardPoints[msg.sender] / 1e18;
        rewardPoints[msg.sender] = 0; // Reset accumulated reward points
        _mint(msg.sender, rewards);
        lastRewardTime[msg.sender] = block.timestamp;
    }

    receive() external payable {}

    fallback() external payable {}
}