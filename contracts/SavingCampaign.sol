// SPDX-License-Identifier: BSD 3-Clause License
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract SavingChallenge {
    enum Stages {
        //Stages of the round
        Setup,
        Save,
        Finished
    }

    struct User {
        address userAddr;
        uint256 availableCashIn;
        uint256 availableSavings;
        uint8 latePayments;
        bool isActive;
    }

    mapping(address => User) public users;
    address public partner;

    //Constructor deployment variables
    uint256 public cashIn;
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
    event PayCashIn(address indexed user, bool indexed success);
    event PayPlatformFee(address indexed user, bool indexed success);
    event RemoveUser(address indexed removedAddress);
    event Payment(address indexed user, bool indexed success);
    event WithdrawFunds(address indexed user, uint256 indexed amount, bool indexed success);
    //event EndRound(address indexed roundAddress, uint256 indexed startAt, uint256 indexed endAt);

    constructor(
        uint256 _cashIn,
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
        require(_cashIn >= 10, "El deposito de seguridad debe ser minimo de 10 USD");
        require(_saveAmount >= 10, "El pago debe ser minimo de 10 USD");
        require(_partnerFee<= 10000);
        partner = _partner;
        partnerFee = (saveAmount * 100 * _partnerFee * numPayments)/1000000;
        devFund = _devFund;
        cashIn = _cashIn * 10 ** stableToken.decimals();
        saveAmount = _saveAmount * 10 ** stableToken.decimals();
        stage = Stages.Setup;
        numPayments = _numPayments;
        require(_payTime > 0, "El tiempo para pagar no puede ser menor a un dia");
        payTime = _payTime * 60; //86400;
        platformFee = (cashIn * 100 * _platformFee)/ 1000000;
        withdrawFee = _withdrawFee;
        emit ChallengeCreated(saveAmount, numPayments);
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

    function registerUser()
    external atStage(Stages.Setup)
    {
        require(
            !users[msg.sender].isActive,
            "Ya estas registrado en esta ronda"
        );
        users[msg.sender] = User(msg.sender, cashIn - platformFee, 0, 0, true); //create user
        (bool registerSuccess) = transferFrom(address(this), cashIn - platformFee);
        emit PayCashIn(msg.sender, registerSuccess);
        (bool payFeeSuccess) = transferFrom(devFund, platformFee);
        emit PayPlatformFee(msg.sender, payFeeSuccess);
        addressOrderList.push(msg.sender);
        emit RegisterUser(msg.sender);
    }

    function removeMe()
        external
        atStage(Stages.Setup) {
        require(msg.sender == partner || users[msg.sender].isActive == true,
					"No tienes autorizacion para eliminar a este usuario"
				);
        if(users[msg.sender].availableCashIn >0){
          uint256 availableCashInTemp = users[msg.sender].availableCashIn;
          users[msg.sender].availableCashIn = 0;
          transferTo(users[msg.sender].userAddr, availableCashInTemp);
        }
      users[msg.sender].isActive = false;
      emit RemoveUser(msg.sender);
    }

    function startRound() external onlyPartner(partner) atStage(Stages.Setup) {
        stage = Stages.Save;
        startTime = block.timestamp;
    }

    function addPayment(uint256 _payAmount)
        external
        isRegisteredUser(users[msg.sender].isActive)
        atStage(Stages.Save) {
        require(_payAmount <= futurePayments() && _payAmount > 0 , "Pago incorrecto");
        uint8 realPayment = getRealPayment();
        if (payment < realPayment){
            AdvancePayment();
        }

        uint256 deposit = _payAmount;
        users[msg.sender].availableSavings+= deposit;
        (bool success) = transferFrom(address(this), _payAmount);
        emit Payment(msg.sender, success);
    }

    function earlyWithdraw()
        external
        isRegisteredUser(users[msg.sender].isActive)
        atStage(Stages.Save)
    {
        uint8 realPayment = getRealPayment();
        require(realPayment > numPayments, "Challenge is not over yet");
        if (payment < realPayment){
            AdvancePayment();
        }
        uint256 savedAmountTemp = 0;
        savedAmountTemp = users[msg.sender].availableSavings + users[msg.sender].availableCashIn - partnerFee;
        uint256 withdrawFeeTemp = 0;
        withdrawFeeTemp = (savedAmountTemp * 100 * withdrawFee)/ 1000000;
        users[msg.sender].availableSavings = 0;
        users[msg.sender].availableCashIn = 0;
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
            uint256 obligation = cashIn + (saveAmount * (payment-1));

            if (obligation > users[useraddress].availableSavings){
                users[useraddress].latePayments++;
            }
        }
        payment++;
    }

    function endRound() public atStage(Stages.Save) {
        require (getRealPayment() > numPayments, "Challenge is not over yet");
        uint256 partnerFeeTemp = 0;
        for (uint8 i = 0; i < addressOrderList.length ; i++) {
            address useraddress = addressOrderList[i];
            if( users[useraddress].isActive == true){
                partnerFeeTemp += partnerFee;
                uint256 savedAmountTemp = 0;
                savedAmountTemp = users[useraddress].availableSavings + users[useraddress].availableCashIn - partnerFee;
                users[useraddress].availableSavings = 0;
                users[useraddress].availableCashIn = 0;
                (bool success) = transferTo(users[useraddress].userAddr, savedAmountTemp);
                emit WithdrawFunds(users[useraddress].userAddr, savedAmountTemp, success);
            }
        }
        (bool success) = transferTo(users[partner].userAddr, partnerFeeTemp);
    }

    //Getters
    function futurePayments() public view returns (uint256) {
			uint256 totalSaving = ((saveAmount * numPayments) + cashIn);
			uint256 futurePayment = totalSaving - users[msg.sender].availableCashIn - users[msg.sender].availableSavings;
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