// SPDX-License-Identifier: BSD 3-Clause License
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import "hardhat/console.sol";
import "@aave/core-v3/contracts/interfaces/IPool.sol";
import "@aave/periphery-v3/contracts/misc/WalletBalanceProvider.sol";


contract SavingChallenge {
    enum Stages {
        //Stages of the round
        Save,
        Finished
    }

    struct User {
        address userAddr;
        uint256 availableSavings;
        uint8 validPayments;
        uint8 latePayments;
        bool isActive;
    }

    mapping(address => User) public users;
    address public partner;

    //Constructor deployment variables
    uint256 public saveAmount;
    uint256 public numPayments;
    address public devFund; // fees will be sent here
    uint256 public totalSavings;

    //Counters and flags
    uint8 public payment = 1;
    uint256 public startTime;
    address[] public addressOrderList;
    Stages public stage;
    uint256 public devEaring = 0;

    //Time constants in seconds
    uint256 public payTime = 0;
    uint256 public partnerFee = 0;
    uint256 public platformFee = 0;
    uint256 public withdrawFee = 0;

    //ERC20 public stableToken;  // aAvaUSDC Fuji 0x2c4a078f1FC5B545f3103c870d22f9AC5F0F673E
    address public stableToken = 0x6a17716Ce178e84835cfA73AbdB71cb455032456;
    address aavePool = 0xf319Bb55994dD1211bC34A7A26A336C6DD0B1b00;
    address payable aaveBalanceProvider = payable(0xd2495B9f9F78092858e09e294Ed5c17Dbc5fCfA8);
    address aaveToken = 0x2c4a078f1FC5B545f3103c870d22f9AC5F0F673E;
   
    // BucksEvents
    event ChallengeCreated(uint256 indexed saveAmount, uint256 indexed numPayments);
    event RegisterUser(address indexed user);
    event PayPlatformFee(address indexed user, bool indexed success);
    event RemoveUser(address indexed removedAddress);
    event Payment(address indexed user, bool indexed success);
    event WithdrawFunds(address indexed user, uint256 indexed amount, bool indexed success);
    //event EndRound(address indexed roundAddress, uint256 indexed startAt, uint256 indexed endAt);

    constructor(
        uint256 _saveAmount,
        uint256 _numPayments,
        address _partner,
        uint256 _partnerFee, //input = 1 is 0.01
        uint256 _payTime,
        address _devFund,
        uint256 _platformFee, //input = 1 is 0.01
        uint256 _withdrawFee
    ) public {
        require(_partner != address(0), "Partner address cant be zero");
        require(_saveAmount >= 1, "El pago debe ser minimo de 1 USD");
        require(_partnerFee <= 10000);
        partner = _partner;
        saveAmount = _saveAmount * 10 ** 6;
        devFund = _devFund;
        stage = Stages.Save;
        numPayments = _numPayments;
        partnerFee = (saveAmount * 100 * _partnerFee * numPayments)/1000000;
        require(_payTime > 0, "El tiempo para pagar no puede ser menor a un dia");
        payTime = _payTime * 60;//86400;
        platformFee = (saveAmount * 100 * _platformFee)/ 1000000;
        withdrawFee = _withdrawFee;
        totalSavings = 0;
        emit ChallengeCreated(saveAmount, numPayments);
        startTime = block.timestamp;
    }

    modifier atStage(Stages _stage) {
        require(stage == _stage, "Stage incorrecto para ejecutar la funcion");
        _;
    }

    modifier onlyAdmin(address devFund) {
        require(msg.sender == devFund, "Only the admin can call this function");
        _;
    }

    modifier isRegisteredUser(bool user) {
        require(user == true, "Usuario no registrado");
        _;
    }

    function addPayment()
        external
        atStage(Stages.Save) {
        require(saveAmount <= futurePayments(), "Pago incorrecto");
        require (getRealPayment() <= numPayments, "Challenge is not over yet");
        uint8 realPayment = getRealPayment();
        if (payment < realPayment){
            AdvancePayment();
        }
        if (payment == 1 && users[msg.sender].isActive == false){
            users[msg.sender] = User(msg.sender, 0, 0, 0, true); //create user
            (bool payFeeSuccess) = transferFrom(devFund, platformFee);
            emit PayPlatformFee(msg.sender, payFeeSuccess);
            addressOrderList.push(msg.sender);
            console.log("Partner fee = ", partnerFee);
            console.log();
        }
        require(users[msg.sender].isActive == true, "Usuario no registrado");
        if(users[msg.sender].availableSavings == 0){
            (bool registerUser) = transferFrom(address(this), saveAmount - platformFee);
            emit RegisterUser(msg.sender);
            users[msg.sender].availableSavings+= (saveAmount - platformFee);
            IERC20(stableToken).approve(aavePool, (saveAmount - platformFee));
            IPool(aavePool).supply(stableToken, (saveAmount - platformFee), address(this), 0);
            totalSavings += saveAmount;
            users[msg.sender].validPayments++;
            //IPool(aavePool).withdraw(stableToken, 1111111, partner);
        }
        else{
            (bool success) = transferFrom(address(this), saveAmount);
            emit Payment(msg.sender, success);
            users[msg.sender].availableSavings+= saveAmount;
            IERC20(stableToken).approve(aavePool, (saveAmount));
            IPool(aavePool).supply(address(stableToken), saveAmount, address(this), 0);
            totalSavings += saveAmount;   
            users[msg.sender].validPayments++;
        }
    }

    function withdrawChallenge() external atStage(Stages.Save) isRegisteredUser(users[msg.sender].isActive){
        if (getRealPayment() > numPayments){
            console.log("Withdraw");
            uint8 realPayment = getRealPayment();
            if (payment < realPayment && realPayment < numPayments+2){
                AdvancePayment();
            }
            uint256 savedAmountTemp = 0;
            uint256 totNumPayments = totalSavings / saveAmount;
            uint256 earning = 0;
            uint256 earningTemp = getChallengeBalance() - devEaring;
            earning = ((earningTemp * users[msg.sender].validPayments) / totNumPayments) - users[msg.sender].availableSavings;
            savedAmountTemp = users[msg.sender].availableSavings - partnerFee + earning;
            users[msg.sender].availableSavings = 0;
            users[msg.sender].isActive = false;
            totalSavings -= (users[msg.sender].validPayments * saveAmount);
            IPool(aavePool).withdraw(stableToken, savedAmountTemp, msg.sender);
            if (partnerFee > 0){
                IPool(aavePool).withdraw(stableToken, partnerFee, partner);
            }
            //emit WithdrawFunds(users[msg.sender].userAddr, savedAmountTemp, withdrawSuccess);
        }
        else{
            console.log("Early Withdraw");
            uint8 realPayment = getRealPayment();
            if (payment < realPayment){
                AdvancePayment();
            }
            uint256 savedAmountTemp = 0;
            savedAmountTemp = users[msg.sender].availableSavings - partnerFee;
            uint256 withdrawFeeTemp = 0;
            withdrawFeeTemp = (savedAmountTemp * 100 * withdrawFee)/ 1000000;
            users[msg.sender].availableSavings = 0;
            users[msg.sender].isActive = false;
            devEaring += withdrawFeeTemp;
            totalSavings -= (users[msg.sender].validPayments * saveAmount);
            if (partnerFee > 0){
                IPool(aavePool).withdraw(stableToken, partnerFee, partner);
            }
            IPool(aavePool).withdraw(stableToken, savedAmountTemp - withdrawFeeTemp, msg.sender);
            //(bool withdrawSuccess) =  
            //emit WithdrawFunds(users[msg.sender].userAddr, savedAmountTemp, withdrawSuccess);
        }
    }

    function endChallenge() external atStage(Stages.Save) onlyAdmin(msg.sender){
        require(getRealPayment() > numPayments + 2, "Challenge is not over yet!");
        uint256 devEarning = 0;
        devEarning = WalletBalanceProvider(aaveBalanceProvider).balanceOf(address(this), aaveToken);
        IPool(aavePool).withdraw(address(stableToken), devEarning, devFund);
        stage = Stages.Finished;
    }

    function transferFrom(address _to, uint256 _payAmount) internal returns (bool) {
      bool success = IERC20(stableToken).transferFrom(msg.sender, _to, _payAmount);
      return success;
    }

    function transferTo(address _to, uint256 _amount) internal returns (bool) {
      bool success = IERC20(stableToken).transfer(_to, _amount);
      return success;
    }

    function AdvancePayment() private {
        for (uint8 i = 0; i < addressOrderList.length ; i++) {
            address useraddress = addressOrderList[i];
            //uint256 obligation = ((saveAmount * payment) - platformFee);
            uint256 donePayments = ((users[useraddress].availableSavings+platformFee)/saveAmount);
            console.log("Pagos hechos ", i, " : ", donePayments);
            if (donePayments < payment){
                console.log("donePayments < payment is true");
                if (payment-users[useraddress].latePayments > donePayments){
                    console.log("payment-users[useraddress].latePayments > donePayments is true, aumento de latePayment");
                    users[useraddress].latePayments++;
                }
            }
        }
        payment++;
    }

    //Getters
    function futurePayments() public view returns (uint256) {
			uint256 totalSaving = ((saveAmount * numPayments));
			uint256 futurePayment = totalSaving - users[msg.sender].availableSavings - platformFee;
			return futurePayment;
    }

    function getRealPayment() public view atStage(Stages.Save) returns (uint8){
			uint8 realPayment = uint8((block.timestamp - startTime) / payTime)+1;
			return (realPayment);
    }

    function getUserCount() public view returns (uint){
        return(addressOrderList.length);
    }

    function getUserAvailableSavings(address _userAddr) public view returns (uint256){
			return(users[_userAddr].availableSavings);
    }

    function getUserLatePayments(address _userAddr) public view returns (uint8){
			return(users[_userAddr].latePayments);
    }

    function getUserIsActive(address _userAddr) public view returns (bool){
			return(users[_userAddr].isActive);
    }

    function getUserValidPayments(address _userAddr) public view returns (uint256){
            return(users[_userAddr].validPayments);
    }

    function getChallengeBalance() public view returns (uint256){
            return(WalletBalanceProvider(aaveBalanceProvider).balanceOf(address(this), aaveToken));
    }
}
