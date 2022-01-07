// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "hardhat/console.sol";

import './Streamonomics.sol';
//import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { ERC721 } from './base/ERC721.sol';
import './base/ERC721Enumerable.sol';
import { ERC721Checkpointable } from './base/ERC721Checkpointable.sol';
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
//import {ILendingPool} from "@aave/protocol-v2/contracts/interfaces/ILendingPool.sol";

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import '@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol';
import '@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol';

interface IUniswapRouter is ISwapRouter {
    function refundETH() external payable;
}

interface Erc20 {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external returns (uint256);
    function decimals() external returns (uint8);
}


interface CErc20 {
    function mint(uint256) external returns (uint256);
    function exchangeRateCurrent() external returns (uint256);
    function supplyRatePerBlock() external returns (uint256);
    function redeem(uint) external returns (uint);
    function redeemUnderlying(uint) external returns (uint);
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external returns (uint256);
    function decimals() external returns (uint8);
}

interface ICompoundComptroller {
    function claimComp(address holder) external;
}

interface ILendingPool {
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf) external;
    function repay(address asset, uint256 amount, uint256 rateMode, address onBehalfOf) external returns (uint256);
}

interface ITokenVestor {
    function deposit(IERC20 token, uint256 amount) external;
    function withdraw(IERC20 token, uint256 amount) external;
    function flowTokenBalance() external returns (uint256);
    function getNetFlow() external returns (int96);
    function registerFlow(address adr, int96 flowRate, bool isPermanent, uint256 cliffEnd, uint256 vestingDuration, uint256 cliffAmount, bytes32 ref) external;
    function registerBatch(address[] calldata adr, int96[] calldata flowRate, uint256[] calldata cliffEnd, uint256[] calldata vestingDuration, uint256[] calldata cliffAmount, bytes32[] calldata ref) external;
    function redirectStreams(address oldRecipient, address newRecipient, bytes32 ref) external;
}

interface IDAOSuperApp {
    function deposit(address tokenAddress, uint _amount, address beneficiary) external;
}

interface IIdleToken {
    function token() external view returns (address underlying);
    function mintIdleToken(uint256 _amount, bool _skipWholeRebalance, address _referral) external returns (uint256 mintedTokens);
    function redeemIdleToken(uint256 _amount) external returns (uint256 redeemedTokens);
    function tokenPrice() external view returns (uint256 price);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external returns (uint256);
    function decimals() external returns (uint8);
}

contract Dog is ERC721, ERC721Checkpointable, Ownable, Streamonomics {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 private constant ONE_18 = 10**18;

    AggregatorV3Interface internal priceFeed;

    // Kovan Contracts
    //IUniswapRouter public constant uniswapRouter = IUniswapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    //address private constant WETH9 = 0xd0A1E359811322d97991E03f863a0C30C2cF029C;
    //address private constant DAI = 0x4F96Fe3b7A6Cf9725f59d353F723c1bDb64CA6Aa;
    //address private constant cDAI = 0xF0d0EB522cfa50B716B3b1604C4F0fA6f04376AD;
    //address private constant cDAIx = 0x3ED99f859D586e043304ba80d8fAe201D4876D57;
    //address private constant comptroller = 0x5eAe89DC1C671724A672ff0630122ee834098657;

    // Mumbai Contracts
    IUniswapRouter public constant uniswapRouter = IUniswapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564); // 

    //address private constant WETH9 = 0x3C68CE8504087f89c640D02d133646d98e64ddd9; // mumbai
    

    address private constant DAI = 0x001B3B4d0F3714Ca98ba10F6042DaEbF0B1B7b6F;
    address private constant aaveLendingPool = 0x9198F13B08E299d85E096929fA9781A1E3d5d827;
    address private constant amWETH = 0x7aE20397Ca327721F013BB9e140C707F82871b56;
    address private constant amWETHx = 0x67A87A1daa04Da7aADA1787c1FaFd178553d9FE1;

    address private constant cDAI = 0xF0d0EB522cfa50B716B3b1604C4F0fA6f04376AD;
    address private constant cDAIx = 0x3ED99f859D586e043304ba80d8fAe201D4876D57;
    address private constant comptroller = 0x5eAe89DC1C671724A672ff0630122ee834098657;

    // Polygon:
    address private constant idleWETH = 0xfdA25D931258Df948ffecb66b5518299Df6527C4;
    address private constant idleWETHx = 0xEB5748f9798B11aF79F892F344F585E3a88aA784;
    address private constant WETH9 = 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619; // polygon

    ITokenVestor private vestor; // Token Vesting contract

    // An address who has permissions to mint Dogs
    address public minter;

    address public treasury;

    IDAOSuperApp public donationDAO;
    uint256 public donationPercentage = 10;

    mapping(uint256 => uint256) public winningBid;

    mapping(uint256 => int96) public flowRates;
    struct Flow {
        uint256 tokenId;
        uint256 timestamp;
        int96 flowRate;
    }
    mapping(uint256 => Flow[]) private flowsForToken;
    
    uint256 public lastId; // this is so we can increment the number

    // default to 4 weeks
    uint256 public reserveDuration = 60*60*24*28;

    // IPFS content hash of contract-level metadata
    string private _contractURIHash = 'QmYuKfPPTT14eTHsiaprGrTpuSU5Gzyq7EjMwwoPZvaB6o';

    uint256 constant YEAR = 60*60*24*365;

    event TreasuryUpdated(
        address oldAddress,
        address newAddress
    );

    event VestorUpdated(
        address oldAddress,
        address newAddress
    );

    event MinterUpdated(
        address oldAddress,
        address newAddress
    );

    event DonationPercentageUpdated(
        uint256 oldPercentage,
        uint256 newPercentage
    );

    modifier onlyMinter() {
        require(msg.sender == minter, 'Sender is not the minter');
        _;
    }
    modifier onlyMinterOrOwner() {
        require( (msg.sender == minter) || (msg.sender == owner()), 'Sender is not the minter nor owner');
        _;
    }

    constructor(address _tokenVestor, address _donationDAO) 
        
        // hardcoding to make testing faster
        ERC721(
            "Degen Dog",//_name,  
            "DOG"//_symbol
            ) {

        vestor = ITokenVestor(_tokenVestor);
        donationDAO = IDAOSuperApp(_donationDAO);

        // chainlink ETH/DAI on Kovan
        priceFeed = AggregatorV3Interface(0x22B58f1EbEDfCA50feF632bD73368b2FdA96D541);

        // default streamonomics -- can be replaced with setStreamonomics
        streamonomics.push(Streamonomic(10,1,1,1));
        streamonomics.push(Streamonomic(30,1,5,20));
        streamonomics.push(Streamonomic(10,10,1,1));

    }

    function setVestor(address _vestor) external onlyOwner {
        emit VestorUpdated(address(vestor), _vestor);
        vestor = ITokenVestor(_vestor);
    }

    function _targetReserves() internal returns(uint256 targetReserves) {
        int96 totalFlowRate = vestor.getNetFlow() * -1;
        targetReserves = uint256(uint96(totalFlowRate)).mul(reserveDuration);
    }
    function setreserveDuration(uint256 _duration) external onlyOwner {
        require(_duration > 0, "!zero");
        reserveDuration = _duration;
    }
    function _targetReserveForAmount(uint256 amt) internal view returns(uint256 reserve) {
        uint256 pct;
        for(uint i = 0; i < streamonomics.length; i++) {
            pct += streamonomics[i].percentage;
        }
        reserve = amt.mul(pct).div(100).div(YEAR).mul(reserveDuration);
    }

    function setTreasury(address _treasury) external onlyOwner {
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    function setDonationPercentage(uint256 _pct) external onlyOwner {
        emit DonationPercentageUpdated(donationPercentage, _pct);
        uint256 streamPct;
        for(uint i = 0; i < streamonomics.length; i++) {
            streamPct += streamonomics[i].percentage;
        }
        require(_pct <= (100 - streamPct), "!>100");
        donationPercentage = _pct;
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return "https://degendogs.club/meta/";
    }

    function _idle(uint256 tokens) internal returns (uint256) {
        Erc20 underlying = Erc20(WETH9);
        IIdleToken iToken = IIdleToken(idleWETH);
        uint256 _numTokensBefore = iToken.balanceOf(address(this));
        uint256 _numTokensToSupply = tokens;
        underlying.approve(idleWETH, _numTokensToSupply);
        uint256 mintResult = iToken.mintIdleToken(_numTokensToSupply, true, address(this));  // TODO: what is best address for referral?
        uint256 _numTokensAfter = iToken.balanceOf(address(this));
        uint256 iTokens = _numTokensAfter.sub(_numTokensBefore);
        return iTokens;
    }

    function _defi(uint256 amount, address newOwner) internal returns(uint256) {
        IERC20 token = IERC20(WETH9);
        IIdleToken iToken = IIdleToken(idleWETH);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        uint256 afterBalance = token.balanceOf(address(this));
        require(beforeBalance.add(amount) == afterBalance, "Token transfer call did not transfer expected amount");
        
        uint256 toIdleAmount = amount;
        if ( address(donationDAO) != address(0) ) {
            if (donationPercentage > 0) {
                uint256 donationAmount = amount.mul(donationPercentage).div(100);
                token.approve(address(donationDAO), donationAmount);
                donationDAO.deposit(WETH9, donationAmount, newOwner);
                toIdleAmount -= donationAmount;
            }
        }
        
        console.log("toIdleAmount", toIdleAmount);
        uint256 iTokens = _idle(toIdleAmount);  // WETH for idleWETH
        console.log("iTokens", iTokens);
        uint256 price = iToken.tokenPrice();
        console.log("price", price);
        //mintedTokens = _amount.mul(ONE_18).div(idlePrice);
        uint256 estTokens = amount.mul(ONE_18).div(price);
        console.log("estTokens", estTokens);

        uint256 vestorBalance = vestor.flowTokenBalance();
        uint256 target = _targetReserves().add(_targetReserveForAmount(estTokens));
        if ( target > vestorBalance ) {
            uint256 depAmount = target.sub(vestorBalance);
            iToken.approve(address(vestor), depAmount);
            vestor.deposit(IERC20(idleWETH), depAmount);
        }
        uint256 iBalance = iToken.balanceOf(address(this));
        if ( treasury != address(0) ) {
            iToken.transfer(treasury, iBalance);
        }
        return estTokens;
    }

    // temporary functions for dev because I keep losing all my faucet ETH to older versions of contracts!!
    function withdrawToken(address _tokenContract) external onlyOwner {
        IERC20 tokenContract = IERC20(_tokenContract);

        // transfer the token from address of this contract
        // to address of the user (executing the withdrawToken() function)
        tokenContract.transfer(msg.sender, tokenContract.balanceOf(address(this)) );
    }
    function withdrawETH() external payable onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }
    
    // @dev creates the NFT, but it remains in the contract
    function mint() external onlyMinterOrOwner returns (uint256) {
        //flowRates[lastId] = flowRate;
        _mint(owner(), address(this), lastId);
        uint256 dogId = lastId;
        lastId += 1;
        return dogId;
    }
    
    event NFTIssued(uint256 indexed tokenId, address indexed owner);
    
    // @dev issues the NFT, transferring it to a new owner, and starting the streams
    function issue(address newOwner, uint256 tokenId, uint256 amount) external onlyMinterOrOwner {
        console.log("start issue");
        require(newOwner != address(this), "Issue to a new address");
        require(ownerOf(tokenId) == address(this), "NFT already issued");
        uint256 iTokensAmount;
        if (amount > 0) {
            iTokensAmount = _defi(amount, newOwner);
        }
        winningBid[tokenId] = iTokensAmount;
        emit NFTIssued(tokenId, newOwner);
        this.safeTransferFrom(address(this), newOwner, tokenId);
    }

    function _beforeTokenTransfer(
        address oldReceiver,
        address newReceiver,
        uint256 tokenId
    ) internal override(ERC721, ERC721Checkpointable) {
        super._beforeTokenTransfer(oldReceiver, newReceiver, tokenId);
        require(newReceiver != address(0), "New receiver is zero address");
        // @dev because our app is registered as final, we can't take downstream apps

        if ( oldReceiver == address(this) ) {
            uint256 _amount = winningBid[tokenId];
            flowRates[tokenId] = 0;

            // loop through streamonomics rules
            for(uint i = 0; i < streamonomics.length; i++) {
                console.log("i", i);
                Streamonomic memory rule = streamonomics[i];
                // skip the rule if we are too early for it to apply
                if ( rule.start <= tokenId ) {
                    uint256 pieces = rule.limit;
                    console.log("pieces", pieces);
                    if ( tokenId.sub(rule.start) < rule.step.mul(rule.limit) ) {
                        // share with < rule.limit tokens
                        pieces = tokenId.sub(rule.start).div(rule.step) + 1;
                    }
                    console.log("pieces", pieces);
                    uint256 share = _amount.mul(rule.percentage).div(pieces).div(100);
                    console.log("share", share);
                    int96 flowRate = int96(uint96(share.div(YEAR)));
                    console.log("flowRate: ->");
                    console.logInt(flowRate);
                    uint256 latest = tokenId - rule.start;
                    uint256 count;
                    // start from current tokenId and move backwards based on `start` and `step` increments
                    for(uint256 j = latest; j >= 0; j -= rule.step) {
                        console.log("j", j);
                        count++;
                        console.log("count", count);
                        address receiver = ownerOf(j);
                        console.log("receiver", receiver);
                        if ( receiver != address(this) ) {
                            bytes32 ref = keccak256(abi.encode(address(this), j));
                            console.log("ref:->");
                            console.logBytes32(ref);
                            vestor.registerFlow(receiver, flowRate, false, block.timestamp - 1, YEAR, 0, ref);
                            console.log("after registerFlow");
                            flowRates[j] += flowRate;
                        }
                        // check if next j iteration takes us below zero
                        if ( rule.step > j ) {
                            console.log("BREAK: rule.step >= j");
                            break;
                        }
                        // check limit
                        if ( count == rule.limit ) {
                            console.log("BREAK: count == limit");
                            break;
                        }
                    }
                }
            }

        } else {
            if (newReceiver != address(this)) {
                // being transferred to new owner - redirect the flow
                //console.log("ready to redirectStreams", oldReceiver, newReceiver);
                //console.logBytes32( keccak256(abi.encode(address(this), tokenId)) );
                vestor.redirectStreams(oldReceiver, newReceiver, keccak256(abi.encode(address(this), tokenId)));
                //console.log("after redirectStreams");
            }
        }
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC721, ERC721Enumerable) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function setMinter(address _minter) external onlyOwner {
        emit MinterUpdated(minter, _minter);
        minter = _minter;
    }

    /**
     * @notice The IPFS URI of contract-level metadata.
     */
    function contractURI() public view returns (string memory) {
        return string(abi.encodePacked('ipfs://', _contractURIHash));
    }

    /**
     * @notice Set the _contractURIHash.
     * @dev Only callable by the owner.
     */
    function setContractURIHash(string memory newContractURIHash) external onlyOwner {
        _contractURIHash = newContractURIHash;
    }

    receive() external payable {
        //_defi(msg.value);
    }
}
