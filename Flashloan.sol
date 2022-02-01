pragma solidity ^0.5.0;
pragma experimental ABIEncoderV2;

import "@studydefi/money-legos/dydx/contracts/DydxFlashloanBase.sol";
import "@studydefi/money-legos/dydx/contracts/ICallee.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import './IUniswapV2Router02.sol';
import './IWeth.sol';

contract Flashloan is ICallee, DydxFlashloanBase {
    enum Direction { SushiToUniswap, UniswapToSushi} 
    struct ArbInfo {
        Direction direction;
        uint repayAmount;
    }

    event NewArbitrage (
      Direction direction,
      uint profit,
      uint date
    );

    IUniswapV2Router02 sushi;
    IUniswapV2Router02 uniswap;
    IWeth weth;
    IERC20 aave;
    address beneficiary;
    

    constructor(
        address sushiAddress,
        address uniswapAddress,
        address wethAddress,
        address aaveAddress,
        address beneficiaryAddress
    ) public {
      sushi = IUniswapV2Router02(sushiAddress);
      uniswap = IUniswapV2Router02(uniswapAddress);
      weth = IWeth(wethAddress);
      aave = IERC20(aaveAddress);
      beneficiary = beneficiaryAddress;
    }

    // This is the function that will be called postLoan
    // i.e. Encode the logic to handle your flashloaned funds here
    function callFunction(
        address sender,
        Account.Info memory account,
        bytes memory data
    ) public {
        ArbInfo memory arbInfo = abi.decode(data, (ArbInfo));
        uint256 balanceWeth = weth.balanceOf(address(this));

        if(arbInfo.direction == Direction.SushiToUniswap) {
          //Buy ETH on Sushi
          weth.approve(address(sushi), balanceWeth); 
          address[] memory path = new address[](2);
          path[0] = address(weth);
          path[1] = address(aave);
          uint[] memory minOuts = sushi.getAmountsOut(balanceWeth, path); 
          sushi.swapExactTokensForTokens(
            balanceWeth,
            minOuts[1], 
            path, 
            address(this), 
            now
          );

          //Sell ETH on Uniswap
          address[] memory path2 = new address[](2);
          path2[0] = address(aave);
          path2[1] = address(weth);
          uint[] memory minOuts2 = uniswap.getAmountsOut(address(this).balance, path2); 
          uniswap.swapTokensForExactTokens.value(address(this).balance)(
            minOuts2[1], 
            path2, 
            address(this), 
            now
          );
        } else {
          //Buy ETH on Uniswap
          weth.approve(address(uniswap), balanceWeth); 
          address[] memory path = new address[](2);
          path[0] = address(weth);
          path[1] = address(aave);
          uint[] memory minOuts = uniswap.getAmountsOut(balanceWeth, path); 
          uniswap.swapExactTokensForTokens(
            balanceWeth, 
            minOuts[1], 
            path, 
            address(this), 
            now
          );

          //Sell ETH on Sushi
          address[] memory path2 = new address[](2);
          path2[0] = address(aave);
          path2[1] = address(weth);
          uint[] memory minOuts2 = sushi.getAmountsOut(address(this).balance, path2); 
          sushi.swapTokensForExactTokens.value(address(this).balance)( 
            minOuts2[1], 
            path2, 
            address(this), 
            now
          );
        }
        require(
            weth.balanceOf(address(this)) >= arbInfo.repayAmount,
            "Not enough funds to repay dydx loan!"
        );

        uint profit = weth.balanceOf(address(this)) - arbInfo.repayAmount; 
        weth.transfer(beneficiary, profit);
        emit NewArbitrage(arbInfo.direction, profit, now);
    }

    function initiateFlashloan(
      address _solo, 
      address _token, 
      uint256 _amount, 
      Direction _direction)
        external
    {
        ISoloMargin solo = ISoloMargin(_solo);

        // Get marketId from token address
        uint256 marketId = _getMarketIdFromTokenAddress(_solo, _token);

        // Calculate repay amount (_amount + (2 wei))
        // Approve transfer from
        uint256 repayAmount = _getRepaymentAmountInternal(_amount);
        IERC20(_token).approve(_solo, repayAmount);

        // 1. Withdraw $
        // 2. Call callFunction(...)
        // 3. Deposit back $
        Actions.ActionArgs[] memory operations = new Actions.ActionArgs[](3);

        operations[0] = _getWithdrawAction(marketId, _amount);
        operations[1] = _getCallAction(
            // Encode MyCustomData for callFunction
            abi.encode(ArbInfo({direction: _direction, repayAmount: repayAmount}))
        );
        operations[2] = _getDepositAction(marketId, repayAmount);

        Account.Info[] memory accountInfos = new Account.Info[](1);
        accountInfos[0] = _getAccountInfo();

        solo.operate(accountInfos, operations);
    }

    function() external payable {}
}
