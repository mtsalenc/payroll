pragma solidity ^0.4.4;

import './interfaces/PayrollInterface.sol';
import 'zeppelin-solidity/contracts/lifecycle/Pausable.sol';
import 'zeppelin-solidity/contracts/math/SafeMath.sol';
import 'zeppelin-solidity/contracts/token/ERC20Basic.sol';
import 'zeppelin-solidity/contracts/token/SafeERC20.sol';


contract Payroll is PayrollInterface, Pausable{
  using SafeMath for uint256;
  using SafeERC20 for ERC20Basic;

  address oracle;
  mapping(address=>uint) addressToEmployeeId;
  mapping(uint=>address) employeeIdToAddress;
  mapping(uint=>Employee) employeeIdToEmployee;

  uint256 lastEmployeeId;
  uint256 employeeCount;
  uint256 salariesSummationUSDCents;
  uint256 weiUSDRateCents;

  Token[] tokensHandled;
  mapping(address=>uint) addressToTokenId;
  mapping(uint=>address) tokenIdToAddress;

  uint8 tokensHandledLimit = 20;
  uint8 constant TWELVE_MONTHS = 12;
  uint8 constant THIRTY_DAYS = 30;
  uint8 constant RATE_DECIMALS = 18;

  struct Employee{
    address accountAddress;
    address[] allowedTokens;
    uint256 yearlyUSDSalaryCents;
    uint256 lastPayoutTimestamp;

    address[] tokenAllocated;
    uint256[] tokenAllocation;
  }

  struct Token{
    address tokenAddress;
    uint256 usdRateCents;
  }

  function setTokensHandledLimit(uint8 _tokensHandledLimit) public onlyOwner whenNotPaused{
    require(tokensHandled.length < _tokensHandledLimit);
    tokensHandledLimit = _tokensHandledLimit;
  }

  function addFunds() payable public whenNotPaused{}

  function addEmployee(address _accountAddress,address[] _allowedTokens,uint256 _initialYearlyUSDSalaryCents) public
   whenNotPaused
   onlyOwner
   belowTokenNumberLimit(_allowedTokens)
   employeeNotExists(_accountAddress)
   tokensAreHandled(_allowedTokens)
  {
    address[] memory emptyAddrArr;
    uint256[] memory emptyIntArr;
    Employee memory employee = Employee(
      _accountAddress,
      _allowedTokens,
      0,
      0, //assuming employee will be allowed to collect his first payout immediately
      emptyAddrArr,
      emptyIntArr
    );

    lastEmployeeId++;
    employeeCount++;
    uint256 employeeId = lastEmployeeId;

    addressToEmployeeId[_accountAddress] = employeeId;
    employeeIdToAddress[employeeId] = _accountAddress;
    employeeIdToEmployee[employeeId] = employee;

    setEmployeeSalary(employeeId,_initialYearlyUSDSalaryCents);
  }

  function setEmployeeSalary(uint256 employeeId, uint256 yearlyUSDSalaryCents) public
   whenNotPaused
   onlyOwner
   employeeExists(employeeId)
    {
    Employee storage employee = employeeIdToEmployee[employeeId];
    salariesSummationUSDCents = salariesSummationUSDCents.sub(employee.yearlyUSDSalaryCents);
    employee.yearlyUSDSalaryCents = yearlyUSDSalaryCents;
    salariesSummationUSDCents = salariesSummationUSDCents.add(employee.yearlyUSDSalaryCents);
  }

  function removeEmployee(uint256 employeeId) public
   whenNotPaused
   onlyOwner
   employeeExists(employeeId){
    Employee memory employee = employeeIdToEmployee[employeeId];
    setEmployeeSalary(employeeId,0);

    employeeCount--;
    addressToEmployeeId[employee.accountAddress] = 0;
    employeeIdToAddress[employeeId] = 0;

    address[] memory emptyArr;
    uint256[] memory emptyIntArr;
    Employee memory emptyStruct = Employee(0,emptyArr,0,0,emptyArr,emptyIntArr);
    employeeIdToEmployee[employeeId] = emptyStruct;
  }

  function addToken(address tokenAddress,uint256 usdRateCents) public
   onlyOwner
   whenNotPaused
   tokenNotHandled(tokenAddress){
    Token memory token = Token(tokenAddress,usdRateCents);
    tokensHandled.push(token);

    uint256 tokenId = tokensHandled.length.sub(1);
    addressToTokenId[tokenAddress] = tokenId;
    tokenIdToAddress[tokenId] = tokenAddress;
  }

  function removeToken(address tokenAddress) public
   onlyOwner
   whenNotPaused
   tokenHandled(tokenAddress){
    uint256 tokenId = addressToTokenId[tokenAddress];
    if(tokensHandled.length==1){
      delete tokensHandled[tokenId];
      tokenIdToAddress[tokenId] = 0;
    }else{
      //overwrite with last element so we don't leave a gap.
      uint256 lastItemId = tokensHandled.length-1;
      address lastItemAddress = tokenIdToAddress[lastItemId];

      tokensHandled[tokenId].tokenAddress = lastItemAddress;
      tokensHandled[tokenId].usdRateCents = tokensHandled[lastItemId].usdRateCents;

      addressToTokenId[lastItemAddress] = tokenId;
      tokenIdToAddress[lastItemId] = 0;

      delete tokensHandled[lastItemId];
    }
    addressToTokenId[tokenAddress] = 0;
  }

  function setOracle(address oracleAddress) public onlyOwner whenNotPaused{
    oracle = oracleAddress;
  }

  function setExchangeRate(address token,uint256 usdExchangeRateCents) public
   whenNotPaused
   onlyOracle
   tokenHandled(token){
    uint256 tokenId = addressToTokenId[token];
    tokensHandled[tokenId].usdRateCents = usdExchangeRateCents;
  }

  function setWeiExchangeRate(uint256 usdExchangeRateCents) public whenNotPaused onlyOracle {
    weiUSDRateCents = usdExchangeRateCents;
  }

  function escapeHatch() public onlyOwner whenNotPaused{
    pause();
    if(this.balance>0){
      msg.sender.transfer(this.balance);
    }

    for(uint256 i=0;i<tokensHandled.length;i++){
      ERC20Basic token = ERC20Basic(tokensHandled[i].tokenAddress);
      if(token.balanceOf(this)>0){
        token.safeTransfer(msg.sender,token.balanceOf(this));
      }
    }

  }

  function payday() public onlyEmployee onlyOnceAMonth whenNotPaused{
    //WIP

    uint256 employeeId = getEmployeeId(msg.sender);
    Employee employee = employeeIdToEmployee[employeeId];
    uint256 monthlyUsdCents = employee.yearlyUSDSalaryCents.div(TWELVE_MONTHS);

    uint256 remainingAllocation = 100; //percentage
    /* for(uint8 i=0;i<employee.tokenAllocation.length;i++){
      remainingAllocation = remainingAllocation.sub(employee.tokenAllocation[i]);

      uint256 usdCentsForToken = monthlyUsdCents.div(employee.tokenAllocation[i]);
      usdCentsForToken = usdCentsForToken.mul(100);
    } */

    uint256 amountInWei = monthlyUsdCents.mul(weiUSDRateCents);
    amountInWei = amountInWei.div(remainingAllocation);
    amountInWei = amountInWei.mul(100);
    msg.sender.send(amountInWei);
  }

  function determineAllocation(address[] _tokens, uint256[] _distribution) public
    onlyEmployee
    onlyOnceAMonth
    tokensAreHandled(_tokens)
    belowTokenNumberLimit(_tokens)
  {
    require(_tokens.length == _distribution.length);

    Employee storage employee = employeeIdToEmployee[addressToEmployeeId[msg.sender]];
    uint256 allocationSummation = 0;
    for(uint8 i = 0;i<_tokens.length;i++){
      allocationSummation = allocationSummation.add(_distribution[i]);
    }
    require(allocationSummation <= 100); //remainder will be paid in eth

    for(i = 0;i<_tokens.length;i++){
      if(employee.tokenAllocation.length<i+1){
        employee.tokenAllocation.length += 1;
        employee.tokenAllocated.length += 1;
      }
      employee.tokenAllocated[i]=_tokens[i];
      employee.tokenAllocation[i]=_distribution[i];
    }

  }

  function calculatePayrollBurnrate() view public returns (uint256){
    return salariesSummationUSDCents.div(TWELVE_MONTHS);
  }

  function calculatePayrollRunway() view public thereAreEmployees returns (uint256) {
    var (totalUSDCents,decimalPlaces) = totalBalanceInUSDCents();
    uint256 spentUSDCentsPerMonth = salariesSummationUSDCents.div(TWELVE_MONTHS);
    uint256 spentUSDCentsPerDay = spentUSDCentsPerMonth.div(THIRTY_DAYS);

    return totalUSDCents.div(spentUSDCentsPerDay).div(10**uint256(RATE_DECIMALS));
  }

  function totalBalanceInUSDCents() view public returns(uint256,uint8) {
    uint256 totalUSDCents = this.balance.mul(weiUSDRateCents); //assumes oracle set eth rate already

    for(uint256 i = 0;i<tokensHandled.length;i++){
      Token memory token = tokensHandled[i];
      ERC20Basic tokenContract = ERC20Basic(token.tokenAddress);
      if(tokenContract.balanceOf(this)>0){
        uint256 tokens = tokenContract.balanceOf(this);
        uint256 tokensValueInUsdCents = tokens.mul(token.usdRateCents).mul(10**uint(RATE_DECIMALS));
        totalUSDCents = totalUSDCents.add(tokensValueInUsdCents);
      }
    }

    return (totalUSDCents,RATE_DECIMALS);
  }

  // public getters
  function getEmployeeId(address employeeAddress) view public returns (uint256){
    return addressToEmployeeId[employeeAddress];
  }

  function getEmployeeCount() view public returns (uint256){
    return employeeCount;
  }

  function getEmployee(uint256 employeeId) view public returns (address,address[],uint256) {
    Employee memory employee = employeeIdToEmployee[employeeId];
    return (employee.accountAddress,employee.allowedTokens,employee.yearlyUSDSalaryCents);
  }

  function getSalariesSummationUSD() view public returns (uint256){
    return salariesSummationUSDCents;
  }

  function getToken(address tokenAddress) view public
    tokenHandled(tokenAddress) returns (address,uint256)
  {
    uint256 tokenId = addressToTokenId[tokenAddress];
    Token memory token = tokensHandled[tokenId];
    return (token.tokenAddress,token.usdRateCents);
  }

  function getEthExchangeRateCents() view public returns (uint256){
    return weiUSDRateCents;
  }

  function isTokenHandled(address tokenAddress) view public returns(bool){
    uint256 tokenId = addressToTokenId[tokenAddress];
    if(tokensHandled.length==0){
      return false;
    }

    Token memory token = tokensHandled[tokenId];
    if(token.tokenAddress==tokenAddress){
      return true;
    }else{
      return false;
    }

  }

  // modifiers
  modifier thereAreEmployees(){
    require(employeeCount>0);
    _;
  }

  modifier employeeExists(uint256 employeeId){
    Employee storage employee = employeeIdToEmployee[employeeId];
    if(employee.accountAddress==0){
       revert();
    }
    _;
  }

  modifier employeeNotExists(address employeeAddress){
    uint256 employeeId = addressToEmployeeId[employeeAddress];
    if(employeeId!=0){ //employee id will always be >= 1
       revert();
    }
    _;
  }

  modifier onlyOracle(){
    require(msg.sender == oracle);
    _;
  }

  modifier tokenNotHandled(address _tokenAddress){
    if(tokensHandled.length!=0){
      uint256 tokenId = addressToTokenId[_tokenAddress];
      Token memory token = tokensHandled[tokenId];
      require(token.tokenAddress!=_tokenAddress);
    }
    _;
  }

  modifier tokenHandled(address _tokenAddress){
    require(tokensHandled.length>0);
    require(isTokenHandled(_tokenAddress));
    _;
  }

  modifier tokensAreHandled(address[] _tokenAddresses){
    require(tokensHandled.length>0);
    require(_tokenAddresses.length<=tokensHandled.length);
    require(_tokenAddresses.length<=tokensHandledLimit);
    for(uint8 i = 0;i<_tokenAddresses.length;i++){
      require(isTokenHandled(_tokenAddresses[i]));
    }
    _;
  }

  modifier belowTokenNumberLimit(address[] tokenAddresses){
    require(tokenAddresses.length <= tokensHandledLimit);
    _;
  }

  modifier onlyEmployee(){
    require(employeeCount>0);
    require(addressToEmployeeId[msg.sender]!=0);
    _;
  }

  modifier onlyOnceAMonth(){
    uint256 THIRTY_DAYS_IN_SECONDS = 30 * 86400;
    uint256 employeeId = addressToEmployeeId[msg.sender];
    Employee memory employee = employeeIdToEmployee[employeeId];
    require(block.timestamp>employee.lastPayoutTimestamp.add(THIRTY_DAYS_IN_SECONDS));
    _;
  }

}
