// SPDX-License-Identifier: MIT
pragma solidity 0.8.8;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

interface PensionContractInterface {
    function getauctionShares() external view returns (uint256);

    function mintCDP(
        uint256 _amount,
        uint256 _day
    ) external;

    function mintShares(address _recipient, uint256 _amount) external;

    function gettotalShares() external view returns (uint256);

    function BurnSharesfromAuction() external returns (uint256);
}

contract Auction is Ownable, Initializable {
    event UserEnterAuction(
        address indexed addr,
        uint256 timestamp,
        uint256 entryAmountPLS,
        uint256 day
    );
    event UsercollectAuctionShares(
        address indexed addr,
        uint256 timestamp,
        uint256 day,
        uint256 tokenAmount
    );

    event DailyAuctionEnd(
        uint256 timestamp,
        uint256 day,      
        uint256 PLSTotal,
        uint256 tokenTotal
    );
    event AuctionStarted(uint256 timestamp);

    uint256 public constant FEE_DENOMINATOR = 1000;

    /** Taxes */
    address public swiss_addr;

    /* Record the current day of the programme */
    uint256 public currentDay;

    /* Auction participants data */
    struct userAuctionEntry {
        uint256 totalDepositsPLS;
        uint256 day;
        bool hasCollected;
    }

    /* new map for every entry (users are allowed to enter multiple times a day) */
    mapping(address => mapping(uint256 => userAuctionEntry))
        public mapUserAuctionEntry;

    /** Total PLS deposited for the day */
    mapping(uint256 => uint256) public PLSauctionDeposits;

    /** Total shares distributed for the day */
    mapping(uint256 => uint256) public shares;

    /** Total CDP minted for the day */
    mapping(uint256 => uint256) public CDPMinted;

    // Record the contract launch time & current day
    uint256 public launchTime;
    address public CDP;
    uint256 public totalPLSdeposited;

    /** TokenContract object  */
    PensionContractInterface public _PensionContract;
    address payable public PensionContractAddress;

    constructor() {
        swiss_addr = msg.sender;
    }

    receive() external payable {}

    /** 
        @dev is called when we're ready to start the auction
        @param _pensionaddress address of the pension contract

    */
    function startAuction(
        address _CDP,
        address _pensionaddress
    ) external onlyOwner initializer {
        require(
            _pensionaddress != address(0),
            "Pension contract address cannot be zero"
        );
        CDP = _CDP;
        launchTime = block.timestamp;
        currentDay = calcDay();
        PensionContractAddress = payable(_pensionaddress);
        _PensionContract = PensionContractInterface(_pensionaddress);

        renounceOwnership();
        emit AuctionStarted(block.timestamp);
    }

    /**
        @dev Calculate the current day based off the auction start time 
    */
    function calcDay() public view returns (uint256) {
        if (launchTime == 0) return 0;
        return (block.timestamp - launchTime) / 20 hours;
    }

    /**
        @dev Called daily, can be done manually in explorer but will be automated with a script
        this prevent the first user transaction of the day having to pay all the gas to run this 
        function. For security all tokens are kept in the token contract, divs are sent to the 
        div contract for div rewards and taxs are sent to the tax contract.
    */
    function doDailyUpdate() public {
        uint256 _nextDay = calcDay();
        uint256 _currentDay = currentDay;
 
        // this is true once a day
        if (_currentDay != _nextDay) {
            //mints the CDP for the current day
            _mintDailyCDPandShares(_currentDay);

            //mints CDP for days that were skipped
            for(uint256 i = _currentDay + 1; i < _nextDay; i++) {
                _mintPastDailyCDP(i);
            }

            emit DailyAuctionEnd(
                block.timestamp,
                currentDay,
                PLSauctionDeposits[currentDay],
                shares[currentDay]
            );

            currentDay = _nextDay;
        }
    }

    /**
     * @dev entering the Auction for the current day
     */
    function enterAuction() external payable {
        require((launchTime > 0), "Project not launched");
        require(msg.value > 0, "msg value is 0 ");
        doDailyUpdate();

        uint256 _currentDay = currentDay;
        PLSauctionDeposits[_currentDay] += msg.value;

        mapUserAuctionEntry[msg.sender][_currentDay] = userAuctionEntry({
            totalDepositsPLS: mapUserAuctionEntry[msg.sender][_currentDay]
                .totalDepositsPLS + msg.value,
            day: _currentDay,
            hasCollected: false
        });
        totalPLSdeposited += msg.value;
        emit UserEnterAuction(
            msg.sender,
            block.timestamp,
            msg.value,
            _currentDay
        );
    }

    /**
     * @dev External function for leaving the Auction / collecting the shares
     * @param targetDay Target day of Auction to collect
     */
    function collectAuctionShares(uint256 targetDay) external {
        require(
            mapUserAuctionEntry[msg.sender][targetDay].hasCollected == false,
            "Tokens already collected for day"
        );
        require(
            targetDay < currentDay,
            "cant collect tokens for current active day"
        );

        uint256 _sharesToPay = calcTokenValue(msg.sender, targetDay);
        mapUserAuctionEntry[msg.sender][targetDay].hasCollected = true;

        PensionContractInterface(PensionContractAddress).mintShares(
            msg.sender,
            _sharesToPay
        );

        emit UsercollectAuctionShares(
            msg.sender,
            block.timestamp,
            targetDay,
            _sharesToPay
        );
    }

    /**
     * @dev Calculating user's share from Auction based on their & of deposits for the day
     * @param _Day The Auction day
     */
    function calcTokenValue(
        address _address,
        uint256 _Day
    ) public view returns (uint256 _tokenValue) {
        //   require(_Day < calcDay(), "day must have ended");
        uint256 _entryDay = mapUserAuctionEntry[_address][_Day].day;

        if (shares[_entryDay] == 0) {
            // No token minted for that day ( this happens when no deposits for the day)
            return 0;
        }
        if (_entryDay < currentDay) {
            _tokenValue =
                (shares[_entryDay] *
                    mapUserAuctionEntry[_address][_Day].totalDepositsPLS) /
                PLSauctionDeposits[_entryDay];
        } else {
            _tokenValue = 0;
        }

        return _tokenValue;
    }

    /**
        @dev Send PLS to swiss
    */
    function withdrawPLS() external {
        uint256 _bal = address(this).balance;
        payable(swiss_addr).transfer(_bal); // send PLS to swiss
    }

    /**
        @dev Mints CDP in Pension contract and shares for the day 
        @param _day the day to mint the CDP + shares for
    */
    function _mintDailyCDPandShares(uint256 _day) internal {
        // CDP is minted from Pension contract every day
        uint256 MintedCDP = todayMintedCDP();
        CDPMinted[_day] = MintedCDP;
        PensionContractInterface(PensionContractAddress).mintCDP(
            MintedCDP,
            _day
        );

        // shares that belong to auction are burned as they are distributed in Pension to users
        uint256 nextDayShares = PensionContractInterface(PensionContractAddress)
            .BurnSharesfromAuction();
        shares[_day] = nextDayShares; // this is the amount of shares that are for sale on _day
    }

    /**
        @dev Only mints CDP in Pension contract days that weren't updated
        @param _day the skipped day to mint the CDP
    */
    function _mintPastDailyCDP(uint256 _day) internal {
        // CDP is minted from Pension from previous days
        uint256 MintedCDP = todayMintedCDP();
        CDPMinted[_day] = MintedCDP;
        PensionContractInterface(PensionContractAddress).mintCDP(
            MintedCDP,
            _day
        );
    }

    /**
     * @dev This is the amount of CDP tokens that are minted on current day
     */
    function todayMintedCDP() public view returns (uint256) {
        uint256 totalSupply = IERC20(CDP).totalSupply();
        uint256 totalShares = PensionContractInterface(PensionContractAddress)
            .gettotalShares();
        uint256 historicSupply = (totalShares * 10) / 13;
        return (((totalSupply + historicSupply) * 10000) / 103563452);
    }

    function getStatsLoop(
        uint256 _day
    )
        external
        view
        returns (
            uint256 yourDeposit,
            uint256 totalDeposits,
            uint256 youReceive,
            bool claimedis,
            uint256 sharesis
        )
    {
        yourDeposit = mapUserAuctionEntry[msg.sender][_day].totalDepositsPLS;
        totalDeposits = PLSauctionDeposits[_day];
        youReceive = calcTokenValue(msg.sender, _day);
        claimedis = mapUserAuctionEntry[msg.sender][_day].hasCollected;
        sharesis = shares[_day];
    }

    function getStatsLoops(
        uint256 _day,
        uint256 numb,
        address account
    )
        external
        view
        returns (
            uint256[10] memory yourDeposits,
            uint256[10] memory totalDeposits,
            uint256[10] memory youReceives,
            bool[10] memory claimedis,
            uint256[10] memory sharesDay
        )
    {
        for (uint256 i = 0; i < numb; ) {
            yourDeposits[i] = mapUserAuctionEntry[account][_day + i]
                .totalDepositsPLS;
            totalDeposits[i] = PLSauctionDeposits[_day + i];
            youReceives[i] = calcTokenValue(account, _day + i);
            claimedis[i] = mapUserAuctionEntry[account][_day + i].hasCollected;
            sharesDay[i] = shares[_day + 1];
            unchecked {
                ++i;
            }
        }
        return (yourDeposits, totalDeposits, youReceives, claimedis, sharesDay);
    }
}