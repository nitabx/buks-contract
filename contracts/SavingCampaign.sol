// SPDX-License-Identifier: BSD 3-Clause License
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract SavingChallenge {
    enum Stages {
        //Stages of the round
        Save,
        Finished
    }

    struct User {
        address userAddr;
        uint256 availableSavings;
        uint8 latePayments;
        bool isActive;
    }

    mapping(address => User) public users;
    address public partner;

    //Constructor deployment variables
    uint256 public saveAmount;
    uint256 public numPayments;
    address public devFund; // fees will be sent here

    //Counters and flags
    uint8 public payment = 1;
    uint256 public startTime;
    address[] public addressOrderList;
    Stages public stage;

    //Time constants in seconds
    // Weekly by Default
    uint256 public payTime = 0;
    uint256 public partnerFee = 0;
    uint256 public platformFee = 0;
    uint256 public withdrawFee = 0;
    ERC20 public stableToken; // USDC Polygon Muimbai 0x0FA8781a83E46826621b3BC094Ea2A0212e71B23

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
        ERC20 _token,
        address _devFund,
        uint256 _platformFee, //input = 1 is 0.01
        uint256 _withdrawFee
    ) public {
        stableToken = _token;
        require(_partner != address(0), "Partner address cant be zero");
        require(_saveAmount >= 10, "El pago debe ser minimo de 10 USD");
        require(_partnerFee<= 10000);
        partner = _partner;
        saveAmount = _saveAmount * 10 ** stableToken.decimals();
        devFund = _devFund;
        stage = Stages.Save;
        numPayments = _numPayments;
        partnerFee = (saveAmount * 100 * _partnerFee * numPayments)/1000000;
        require(_payTime > 0, "El tiempo para pagar no puede ser menor a un dia");
        payTime = _payTime * 60; //86400;
        platformFee = (saveAmount * 100 * _platformFee)/ 1000000;
        withdrawFee = _withdrawFee;
        emit ChallengeCreated(saveAmount, numPayments);
        startTime = block.timestamp;
    }

    modifier atStage(Stages _stage) {
        require(stage == _stage, "Stage incorrecto para ejecutar la funcion");
        _;
    }

    modifier onlyPartner(address partner) {
        require(msg.sender == partner, "Only the partner can call this function");
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
            users[msg.sender] = User(msg.sender, 0, 0, true); //create user
            (bool payFeeSuccess) = transferFrom(devFund, platformFee);
            emit PayPlatformFee(msg.sender, payFeeSuccess);
            addressOrderList.push(msg.sender);
        }
        require(users[msg.sender].isActive == true, "Usuario no registrado");
        if(users[msg.sender].availableSavings == 0){
            (bool registerSuccess) = transferFrom(address(this), saveAmount - platformFee);
            users[msg.sender].availableSavings+= (saveAmount - platformFee);
            emit RegisterUser(msg.sender);
        }
        else{
            (bool success) = transferFrom(address(this), saveAmount);
            users[msg.sender].availableSavings+= saveAmount;
            emit Payment(msg.sender, success);
        }
    }

    function earlyWithdraw()
        external
        isRegisteredUser(users[msg.sender].isActive)
        atStage(Stages.Save)
    {
        require (getRealPayment() < numPayments, "Challenge is not over yet");
        uint8 realPayment = getRealPayment();
        if (payment <= realPayment){
            AdvancePayment();
        }
        uint256 savedAmountTemp = 0;
        savedAmountTemp = users[msg.sender].availableSavings - partnerFee;
        uint256 withdrawFeeTemp = 0;
        withdrawFeeTemp = (savedAmountTemp * 100 * withdrawFee)/ 1000000;
        users[msg.sender].availableSavings = 0;
        users[msg.sender].isActive = false;
        (bool payPartnerSuccess) = transferTo(partner, partnerFee);
        (bool withdrawSuccess) = transferTo(users[msg.sender].userAddr, (savedAmountTemp - withdrawFeeTemp));
        emit WithdrawFunds(users[msg.sender].userAddr, savedAmountTemp, withdrawSuccess);
        transferTo(devFund, withdrawFeeTemp);
    }


    function withdrawChallenge() external atStage(Stages.Save) isRegisteredUser(users[msg.sender].isActive){
        require (getRealPayment() > numPayments, "Challenge is not over yet");
        uint256 savedAmountTemp = 0;
        savedAmountTemp = users[msg.sender].availableSavings - partnerFee;
        users[msg.sender].availableSavings = 0;
        users[msg.sender].isActive = false;
        (bool payPartnerSuccess) = transferTo(partner, partnerFee);
        (bool withdrawSuccess) = transferTo(users[msg.sender].userAddr, savedAmountTemp);
        emit WithdrawFunds(users[msg.sender].userAddr, savedAmountTemp, withdrawSuccess);
    }

    function transferFrom(address _to, uint256 _payAmount) internal returns (bool) {
      bool success = stableToken.transferFrom(msg.sender, _to, _payAmount);
      return success;
    }

    function transferTo(address _to, uint256 _amount) internal returns (bool) {
      bool success = stableToken.transfer(_to, _amount);
      return success;
    }

    function AdvancePayment() private {
        for (uint8 i = 0; i < addressOrderList.length ; i++) {
            address useraddress = addressOrderList[i];
            uint256 obligation = ((saveAmount * payment) - partnerFee);

            if (obligation > users[useraddress].availableSavings){
                users[useraddress].latePayments++;
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
}
