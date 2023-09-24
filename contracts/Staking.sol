// SPDX-License-Identifier: MIT
pragma solidity 0.8.8;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

interface ICDPToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}

interface AuctionContractInterface {
    function calcDay() external view returns (uint256);

    function lobbyEntry(uint256 _day) external view returns (uint256);

    function balanceOf(address _owner) external view returns (uint256 balance);

    function transfer(
        address _to,
        uint256 _value
    ) external returns (bool success);

    function allowance(
        address owner,
        address spender
    ) external view returns (uint256);

    function transferFrom(
        address _from,
        address _to,
        uint256 _value
    ) external returns (bool success);

    function dev_addr() external view returns (address);
}

contract Staking is Ownable, Initializable {
    uint256 public totalShares = 1;
    uint256 public auctionShares = 1;
    uint256 public totalCDPClaimed;
    uint256 public totalRefShares;
    uint256 public NoUsers;
    uint256 public totalDeposited;

    // The tokens
    ICDPToken public CDP;

    address swiss_addr;
   
    // Info of each user that stakes tokens (CDPToken)
    struct UserInfo {
        address referral;
        uint256 shares; // How many staked tokens the user has provided
        uint256 lastInteraction; // last time user interacted
        uint256 lastUpdate; // last day user total shares was updated
        uint256 lastDayCDP; // last day user CDP was collected
        uint256 CDPCollected;
    }
    mapping(address => UserInfo) public userInfo;

    // users per day
    mapping(uint256 => uint256) public NoUsersPerDay;

    /** Total Rewards per day */
    struct dayInfo {
        uint256 CDPRewards;
        uint256 totalShares;
    }

    // info updated from Auction contract
    mapping(uint256 => dayInfo) public dayInfoMap;

    struct userAuctionEntry {
        uint256 shares;
        bool hasCollectedCDP;
    }

    /* new map for every entry (users are allowed to enter multiple times a day) */
    /** To keep track of user shares per day for claiming purposes*/
    mapping(address => mapping(uint256 => userAuctionEntry))
        public mapUserAuctionEntry;

    /** TokenContract object  */
    AuctionContractInterface _AuctionContract;
    address public AuctionContractAddress;

    address[] public UsersInfo;

    event DepositCDP(address indexed user, uint256 timestamp, uint256 amount);
    event MintShares(address indexed user, uint256 amount);
    event ClaimCDP(address indexed user, uint256 timestamp, uint256 amount);
    event CompoundCDP(address indexed user, uint256 timestamp, uint256 amount);

    constructor() {}

    function initialize(
        address _CDP,
        address _auctionAddress,
        address _swiss_addr
    ) public onlyOwner initializer {
        CDP = ICDPToken(_CDP);
        AuctionContractAddress = _auctionAddress;
        _AuctionContract = AuctionContractInterface(_auctionAddress);
        swiss_addr = _swiss_addr;
    }

    fallback() external payable {}

    receive() external payable {}

    /*
     * @notice Deposit CDP
     * @param _amount: amount to withdraw (in CDPToken)
     */
    function depositCDP(
        uint256 _amount,
        address _referral
    ) external {
        require(msg.sender != _referral, "no self-referring");
        if (_amount > 0) {
            UserInfo storage user = userInfo[msg.sender];

            if (user.lastInteraction == 0) {
                UsersInfo.push(msg.sender);
                NoUsers += 1;
            }

            address ref;

            // Case 1: If no referral is entered (_referral == address(0)) and no referral is stored for the user (user.referral == address(0))
            if (_referral == address(0) && user.referral == address(0)) {
                // Set the ref to the auction address
                ref = AuctionContractAddress;
                // Case 2: If the user has no referral set, or the provided referral matches the user's current referral
            } else if (
                _referral == user.referral || user.referral == address(0)
            ) {
                // Set the ref to the provided referral
                ref = _referral;
            } else {
                // Case 3: The provided referral is different from the user's current referral
                // Update the user's referral to the provided referral
                user.referral = _referral;
                // Set the ref to the provided referral
                ref = _referral;
            }

            uint256 _day = _AuctionContract.calcDay();

            check(user, _day); // update user shares till (_day -1)

            user.shares += _amount;

            if (ref == AuctionContractAddress) {
                auctionShares += (_amount) / 10;
            } else {
                userInfo[ref].shares += _amount / 10;
            }

            totalRefShares += _amount / 10;
            auctionShares += (_amount * 2) / 10;
            totalShares += (_amount * 13) / 10;

            totalDeposited += _amount;

            mapUserAuctionEntry[msg.sender][_day].shares = user.shares; // on depositCDP update user shares
            
            CDP.burnFrom(msg.sender, _amount);

            user.lastInteraction = block.timestamp;
            emit DepositCDP(msg.sender, block.timestamp, _amount);
        }
    }

    /*
     * @notice function to update users shares for the days that he hasn't interacted.
     * @param user: user
     */
    function check(UserInfo storage user, uint256 _day) internal {
        if (_day > 0) {
            uint256 latest = user.lastUpdate > 0 ? user.lastUpdate + 1 : 0; //

            for (uint256 i = latest; i < _day; ) {
                if (mapUserAuctionEntry[msg.sender][i].shares == 0)
                    mapUserAuctionEntry[msg.sender][i].shares = user.shares;

                unchecked {
                    ++i;
                }
            }

            user.lastUpdate = _day - 1;
        }
    }

    /*
     * @notice Claim CDP
     */
    function claimCDP() external {
        uint256 _day = _AuctionContract.calcDay();
        require(_day > 0, "day 0 not complete");
        UserInfo storage user = userInfo[msg.sender];

        check(user, _day); // update user shares till (_day -1)

        uint256 pending;
        uint256 lastDayClaimed = user.lastDayCDP;

        for (uint256 i = lastDayClaimed; i < _day; i++) {
            userAuctionEntry storage userday = mapUserAuctionEntry[msg.sender][
                i
            ];

            if (userday.hasCollectedCDP == false) {
                dayInfo storage info = dayInfoMap[i];
                uint256 totalSharesDay = info.totalShares == 0
                    ? totalShares == 0 ? 1 : totalShares
                    : info.totalShares;
                uint256 userEntries = mapUserAuctionEntry[msg.sender][i].shares; // user shares for day i

                pending += (userEntries * info.CDPRewards) / totalSharesDay;
                userday.hasCollectedCDP = true;
            }
        }

        user.lastDayCDP = _day - 1;

        CDP.transfer(msg.sender, pending);
        totalCDPClaimed += pending;
        user.CDPCollected += pending;
        user.lastInteraction = block.timestamp;

        emit ClaimCDP(msg.sender, block.timestamp, pending);
    }

    /*
     * @notice Compound CDP
     ** @param _day: day to Compound
     */
    function compoundCDP() external {
        uint256 _day = _AuctionContract.calcDay();
        require(_day > 0, "day 0 not complete");
        UserInfo storage user = userInfo[msg.sender];

        check(user, _day); // update user shares till (_day -1)

        uint256 pending;
        uint256 lastDayClaimed = user.lastDayCDP;

        for (uint256 i = lastDayClaimed; i < _day; i++) {
            userAuctionEntry storage userday = mapUserAuctionEntry[msg.sender][
                i
            ];

            if (userday.hasCollectedCDP == false) {
                dayInfo storage info = dayInfoMap[i];
                uint256 totalSharesDay = info.totalShares == 0
                    ? totalShares == 0 ? 1 : totalShares
                    : info.totalShares;
                uint256 userEntries = mapUserAuctionEntry[msg.sender][i].shares; // user shares for day i

                pending += (userEntries * info.CDPRewards) / totalSharesDay;
                userday.hasCollectedCDP = true;
            }
        }

        user.lastDayCDP = _day - 1;
        user.shares += (pending * 115) / 100;

        // Case 1: If no referral is entered (_referral == address(0)) and no referral is stored for the user (user.referral == address(0))
        if (user.referral == address(0)) {
            auctionShares += (pending * 5) / 100;
        } else {
            userInfo[user.referral].shares += (pending * 5) / 100;
        }
        totalDeposited += pending;

        auctionShares += (pending * 10) / 100;
        totalShares += (pending * 130) / 100;

        CDP.burn(pending);
        user.lastInteraction = block.timestamp;
        user.CDPCollected += pending;

        emit CompoundCDP(msg.sender, block.timestamp, pending);
    }

    /**
     * @dev called by auction contract to collect shares for user/day
     */
    function mintShares(address _recipient, uint256 _amount) external {
        require(msg.sender == AuctionContractAddress);
        UserInfo storage user = userInfo[_recipient];
        user.shares += (_amount);
        totalShares += (_amount);
        emit MintShares(_recipient, _amount);
    }

    /**
     * @dev called by auction contract to mint daily distribution and update daily rewards
     */
    function mintCDP(
        uint256 _amount,
        uint256 _day
    ) external {
        require(msg.sender == AuctionContractAddress);
        CDP.mint(address(this), _amount);
        dayInfoMap[_day].CDPRewards = _amount;
        dayInfoMap[_day].totalShares = totalShares;
        NoUsersPerDay[_day] = NoUsers;
    }

    /**
     * @dev called by auction contract to update Auction shares balance
     */
    function BurnSharesfromAuction() external returns (uint256) {
        require(msg.sender == AuctionContractAddress);
        uint256 sharesDistributedinAuction = (5 * auctionShares) / 100;
        totalShares -= sharesDistributedinAuction;
        auctionShares -= sharesDistributedinAuction;

        return sharesDistributedinAuction;
    }

    /*
     * @notice View function to see pending reward on frontend.
     * @notice Pending are calculated as = user shares on that day / total shares on that day * total rewards
     * @param _user: user address
     * @param _day: day
     * @return Pending reward for a given user
     */
    function pendingRewardCDP(
        address _user
    ) public view returns (uint256 totalPending) {
        UserInfo storage user = userInfo[msg.sender];
        uint256 lastDayClaimed = user.lastDayCDP;
        uint256 _day = _AuctionContract.calcDay();

        for (uint256 i = lastDayClaimed; i < _day; i++) {
            userAuctionEntry storage userday = mapUserAuctionEntry[msg.sender][
                i
            ];

            if (userday.hasCollectedCDP == false) {
                dayInfo storage info = dayInfoMap[i];
                uint256 totalSharesDay = info.totalShares == 0
                    ? totalShares == 0 ? 1 : totalShares
                    : info.totalShares;
                uint256 userEntries = mapUserAuctionEntry[_user][i].shares; // user shares for day i

                totalPending +=
                    (userEntries * info.CDPRewards) /
                    totalSharesDay;
            }
        }
    }

    /*
     * @notice function to delete a user's shares if he hasn't interacted for 1111 days.
     * @param _target: user share to be deleted
     */
    function Destroyshares(address _target) external {
        UserInfo storage user = userInfo[_target];

        // Require that the current timestamp is greater than the user's last interaction plus 1111 days
        require(
            block.timestamp > user.lastInteraction + 1111 days,
            "Destroyshares: Time requirement not met"
        );

        // Reduce the total shares and set the user's shares to 0
        totalShares -= user.shares;
        user.shares = 0;
    }

    /*
     * @notice function for a user to show presence.
     */
    function Iamhere() external {
        UserInfo storage user = userInfo[msg.sender];
        user.lastInteraction = block.timestamp;
    }

    function getauctionShares() external view returns (uint256) {
        return auctionShares;
    }

    function gettotalShares() external view returns (uint256) {
        return totalShares;
    }

    function changeAuctionAddy(address _new) external {
        AuctionContractAddress = _new;
        _AuctionContract = AuctionContractInterface(_new);
    }
}
