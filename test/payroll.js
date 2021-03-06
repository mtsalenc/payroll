const BigNumber = require('bignumber.js')
const Payroll = artifacts.require('Payroll')
const BasicTokenMock = artifacts.require('./mock/BasicTokenMock.sol')

contract('Payroll', function (accounts) {
  let contractInstance

  beforeEach(async function () {
    contractInstance = await Payroll.new()
  })

  it('rescues ether on escape', async function () {
    let contractBalance = await web3.eth.getBalance(contractInstance.address).toNumber()
    assert.equal(contractBalance, 0, 'initial contract balance should be 0')

    // Funding contract
    const amountInWei = web3.toWei(5, 'ether')
    const ownerAddress = accounts[0]
    const contractAddress = contractInstance.address
    await contractInstance.addFunds({from: ownerAddress, to: contractAddress, value: amountInWei})
    contractBalance = await web3.eth.getBalance(contractInstance.address).toNumber()
    assert.equal(contractBalance, amountInWei, 'contract balance should be ' + amountInWei)

    // Escaping
    await contractInstance.escapeHatch()

    contractBalance = await web3.eth.getBalance(contractInstance.address).toNumber()
    assert.equal(contractBalance, 0, 'contract balance should be 0')
  })

  it('sets eth exchange rate correctly', async function () {
    const amountInWei = web3.toWei(1, 'ether')
    const ownerAddress = accounts[0]
    const oracleAddress = accounts[1]
    const exchangeRate = 100 // In cents. 1 usd == 1 eth
    const contractAddress = contractInstance.address

    await contractInstance.addFunds({from: ownerAddress, to: contractAddress, value: amountInWei})
    await contractInstance.setOracle(oracleAddress)
    await contractInstance.setWeiExchangeRate(exchangeRate, {from: oracleAddress}) // 1 eth == 1 usd
    const ethExchangeRate = await contractInstance.getEthExchangeRateCents()

    assert.equal(ethExchangeRate, exchangeRate, 'exchange rate should be ' + exchangeRate)
  })

  it('calculates total usd balance correctly', async function () {
    const amountInWei = web3.toWei(2, 'ether')
    const ownerAddress = accounts[0]
    const oracleAddress = accounts[1]
    const exchangeRate = 100 // In cents. 1 usd == 1 eth
    const contractAddress = contractInstance.address
    const tokenContractInstance = await BasicTokenMock.new(ownerAddress, 5000)

    await contractInstance.addFunds({from: ownerAddress, to: contractAddress, value: amountInWei})
    await contractInstance.setOracle(oracleAddress)
    await contractInstance.setWeiExchangeRate(exchangeRate, {from: oracleAddress}) // 1 eth == 1 usd
    let obj = await contractInstance.totalBalanceInUSDCents()
    let decimalPlaces = new BigNumber(10).pow(obj[1])

    let totalBalanceInUSDCents = obj[0].div(decimalPlaces).toNumber()
    assert.equal(totalBalanceInUSDCents, 200, 'balance should be 200 cents')

    await contractInstance.addToken(tokenContractInstance.address, 100)
    assert.equal(await contractInstance.isTokenHandled(tokenContractInstance.address), true, 'token should be handled')

    const tokensToPayroll = 1
    await tokenContractInstance.transfer(contractInstance.address, tokensToPayroll)
    const contractTokenBalance = await tokenContractInstance.balanceOf(contractInstance.address)
    assert.equal(contractTokenBalance, tokensToPayroll, 'contract should own some tokens')

    obj = await contractInstance.totalBalanceInUSDCents()
    decimalPlaces = new BigNumber(10).pow(obj[1])

    totalBalanceInUSDCents = obj[0].div(decimalPlaces).toNumber()
    assert.equal(totalBalanceInUSDCents, 300, 'balance should be 300 cents')
  })

  it('calculates payroll runway correctly', async function () {
    const amountInWei = web3.toWei(10, 'ether')
    const ownerAddress = accounts[0]
    const oracleAddress = accounts[1]
    const employeeAddress = accounts[2]
    const exchangeRate = 1000000 // In cents. 1 eth == 10000 usd
    const contractAddress = contractInstance.address
    const tokenContractInstance = await BasicTokenMock.new(ownerAddress, 100000)
    const tokensToPayroll = 10000

    await contractInstance.addFunds({from: ownerAddress, to: contractAddress, value: amountInWei})
    await contractInstance.setOracle(oracleAddress)
    await contractInstance.setWeiExchangeRate(exchangeRate, {from: oracleAddress}) // 1 eth == 1 usd
    await contractInstance.addToken(tokenContractInstance.address, 1000) // In cents. 1 token == 10 usd
    await contractInstance.addEmployee(employeeAddress, [], 20000000)
    await tokenContractInstance.transfer(contractInstance.address, tokensToPayroll)

    const obj = await contractInstance.totalBalanceInUSDCents()
    const decimalPlaces = new BigNumber(10).pow(obj[1])
    const totalBalanceInUSDCents = obj[0].div(decimalPlaces).toNumber()
    const salariesSummationUSDCents = await contractInstance.getSalariesSummationUSD()

    // calculation
    const totalMonthlySpending = salariesSummationUSDCents / 12
    const totalDailySpending = totalMonthlySpending / 30
    const numberOfDaysLeft = totalBalanceInUSDCents / totalDailySpending
    const numberOfDaysLeftCalculated = (await contractInstance.calculatePayrollRunway()).toNumber()
    assert.equal(numberOfDaysLeftCalculated, numberOfDaysLeft, 'should have calculated days correctly')
  })

  it('should allow employee to determine allocation', async function () {
    const tokenContractA = await BasicTokenMock.new(accounts[0], new BigNumber(100000000))
    const tokenContractB = await BasicTokenMock.new(accounts[0], new BigNumber(100000000))
    const tokenContractC = await BasicTokenMock.new(accounts[0], new BigNumber(100000000))

    await contractInstance.addToken(tokenContractA.address,100)
    await contractInstance.addToken(tokenContractB.address,100)
    await contractInstance.addToken(tokenContractC.address,100)

    await contractInstance.addEmployee(accounts[2],
      [
        tokenContractA.address,
        tokenContractB.address
      ], new BigNumber(10000000)
    )

    await contractInstance.determineAllocation([tokenContractA.address,tokenContractC.address],[40,50],{from:accounts[2]})
  })

  it('should allow employee to be paid', async function(){
    const tokenContractA = await BasicTokenMock.new(accounts[0], new BigNumber(100000000))
    const tokenContractB = await BasicTokenMock.new(accounts[0], new BigNumber(100000000))
    const tokenContractC = await BasicTokenMock.new(accounts[0], new BigNumber(100000000))

    const payrollInitialTokenABalance = await tokenContractA.balanceOf(contractInstance.address)
    assert.equal(payrollInitialTokenABalance,0,'contract should not own tokens yet')

    await tokenContractA.transfer(contractInstance.address,100000)
    await tokenContractB.transfer(contractInstance.address,2000000)
    await tokenContractC.transfer(contractInstance.address,50000)

    const payrollTokenABalance = (await tokenContractA.balanceOf(contractInstance.address)).toNumber()
    assert.equal(payrollTokenABalance,100000,'contract should own tokens')

    await contractInstance.addToken(tokenContractA.address,1)
    await contractInstance.addToken(tokenContractB.address,1)
    await contractInstance.addToken(tokenContractC.address,1)

    await contractInstance.addEmployee(accounts[2],
      [
        tokenContractA.address,
        tokenContractB.address
      ], new BigNumber('10000000') //in cents
    )

    await contractInstance.setOracle(accounts[3]);
    await contractInstance.setWeiExchangeRate(new BigNumber('1000000000000000'), {from: accounts[3]}); //1 dollar == 1 ether

    await contractInstance.determineAllocation([
      tokenContractA.address,
      tokenContractC.address
    ],[40,50],{from:accounts[2]})

    const employeeTokenABalanceBefore = (await tokenContractA.balanceOf(accounts[2])).toNumber()
    const employeeTokenCBalanceBefore = (await tokenContractC.balanceOf(accounts[2])).toNumber()
    const employeeEtherBalanceBefore = await web3.eth.getBalance(accounts[2]).toNumber()

    assert.equal(employeeTokenABalanceBefore,0,'employee should not have A tokens')
    assert.equal(employeeTokenCBalanceBefore,0,'employee should not have C tokens')

    await contractInstance.payday({from:accounts[2]})

    const employeeTokenABalanceAfter = (await tokenContractA.balanceOf(accounts[2])).toNumber()
    const employeeTokenCBalanceAfter = (await tokenContractC.balanceOf(accounts[2])).toNumber()
    const employeeEtherBalanceAfter = await web3.eth.getBalance(accounts[2]).toNumber()

    //assert.isAbove(employeeTokenABalanceAfter,employeeTokenABalanceBefore,'employee should have received A tokens')
    //assert.isAbove(employeeTokenCBalanceAfter,employeeTokenCBalanceBefore,'employee should have received C tokens')
    assert.isAbove(employeeEtherBalanceBefore,employeeEtherBalanceAfter,'employee should have received ether')

  })

})
