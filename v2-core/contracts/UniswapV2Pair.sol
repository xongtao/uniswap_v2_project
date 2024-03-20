pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath for uint;
    using UQ112x112 for uint224;

    //设置最小流动性
    uint public constant MINIMUM_LIQUIDITY = 10 ** 3;

    /**
        将SELECTOR字节码设置为 transfer 前四个字节可以判定其调用的方法
        'transfer(address,uint256)' transfer函数的签名 再由bytes()转为字节
        最后由keccak256变为计算哈希值 通过bytes4 取前四位 
     */

    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0; // uses single storage slot, accessible via getReserves
    uint112 private reserve1; // uses single storage slot, accessible via getReserves
    uint32 private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    uint public kLast; //  Reserve0 * Reserve1，截至最近的流动性事件之后

    /**
        @dev 防止重入
     */
    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    /**
        @dev 获取储备
        @return _reserve0 储备量0
        @return _reserve1 储备量1
        @return _blockTimeStampLast 时间戳    
     */
    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    /**
        @dev 私有安全发送
        @param token  代币地址
        @param to   接受地址
        @param value 数额  
     */
    function _safeTransfer(address token, address to, uint value) private {
        /**
            token.call 为token合约底层的方法调用 使用有锁的call底层方法，而不是用transfer
            首先可以更好的处理返回值，可以防止重入攻击
            abi.encodeWithSelector(SELETOR, param,param);
            此时的SELETOR为transfer方法，to，value为对应参数。
            solium-disable-next-line
         */

        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));

        // success 表示是否调用成功 data 返回meassage应该为空(0)，或者解码后true
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    //构造方法 默认调用者为工厂地址
    constructor() public {
        factory = msg.sender;
    }

    /**
        @dev 构造函数  只能被工厂合约调用一次
     */
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // 更新储备金，并在每个区块第一次调用时更新价格累加器
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        //判断是否balance0,1 是否有溢出
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        //判断时间戳 转化为unit32
        uint32 blockTimestamp = uint32(block.timestamp % 2 ** 32);
        //计算流逝时间
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired

        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            //永远不会溢出
            //价格0最后累计 += 储备量1 * 2 **112 /储备量0 * 时间流逝
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            //价格1最后累计 += 储备量0 * 2 **112 /储备量1 * 时间流逝
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        //更新时间戳
        blockTimestampLast = blockTimestamp;
        //触发同步事件
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)

    /**
        @dev 如果开启收费，则铸造流动性相当于 sqrt(k) 增长的 1/6 
            计算出流动性增加所对应的税 给feeto地址
     */
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        //调用iuniswap中的feeto方法， feeto() 即 公共变量的getter()
        address feeTo = IUniswapV2Factory(factory).feeTo();
        //这个为一个布尔逻辑表达式，等同于 feeon = (feoTo != address(0))
        //如果feeTO 不等于address(0) 那么返回true，否则返回false
        //如果为true 意味着启用了收税机制，那么可以开始设置收税地址
        feeOn = feeTo != address(0);

        //获取到最后一次的流动性乘积
        //tips klast是一个状态变量， _kLast是一个局部变量，用局部变量进行可以节省gas
        uint _kLast = kLast; // gas savings

        if (feeOn) {
            //true 如果启用了收税地址
            if (_kLast != 0) {
                //当前流动性乘积的平方根
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                //上一次流动性乘积的平方根
                uint rootKLast = Math.sqrt(_kLast);

                //如果流动性增加  计算出所对应的流动性代币给feeto地址
                if (rootK > rootKLast) {
                    //分子 = erc20总量 * (rootK- rooKLast)
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    //分母 = rootK * 5 + rootKLast
                    uint denominator = rootK.mul(5).add(rootKLast);
                    // 流动性 = 分子 /分母
                    uint liquidity = numerator / denominator;
                    // 如果流动性>0,将流动性铸造给feeTo地址
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        //得到合约的储备量0，和储备量1
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings

        //通过调用IERC20.balanceOf获取合约地址中的当前代币余额。
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));

        //amount = 当前余额 -  储备量  即得到当前所带来的量
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        //更新余额，与储备量
        _update(balance0, balance1, _reserve0, _reserve1);

        //计算估计乘积
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    // 这个低级函数应该从执行重要安全检查的合约中调用
    /**
        @dev 这个合约是销毁流动性以便流动性提供者提取资产
        @param to 提取资产的地址
     */
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        //用局部变量代替状态变量以节省gas
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings

        //通过调用IERC20.balanceOf获取合约地址中的当前代币余额。
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));
        //通过balanceof映射获取合约自身的流动性余额
        //是由router合约转过来的lptoken的量
        //即需要取出的量，
        uint liquidity = balanceOf[address(this)];

        //返回铸造开关
        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        //tokenA的数量:amount0 = Lptoken代币数量/总代币数量 * token0的总量
        amount0 = liquidity.mul(balance0) / _totalSupply; // 使用余额确保按比例分配
        //tokenB的数量:amount1 = Lptoken代币数量/总代币数量 * token1的总量
        amount1 = liquidity.mul(balance1) / _totalSupply; // 使用余额确保按比例分配
        //确认 amount 0 && amount 1 >0
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');

        //调用burn函数销毁当前合约内的Lptoken代币(流动性)数量
        _burn(address(this), liquidity);
        //将amount0数量的_token0发送给to
        _safeTransfer(_token0, to, amount0);
        //将amount1数量的_token1发送给to
        _safeTransfer(_token1, to, amount1);

        //更新余额
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        //更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        //更新流动性变量
        if (feeOn) kLast = uint(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    /**
        @notice 这个低级函数应该从执行重要安全检查的合约中调用
        @dev 交换合约
        @param data bytes不定长
        @param amount0Out 取token0数额
        @param amount1Out 取token1数额
     */
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        //确保 取出数额之一大于0
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        //确认取款量是否大于储备量
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;

        // _token{0,1} 的范围，避免堆栈太深的错误
        {
            address _token0 = token0;
            address _token1 = token1;

            require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');

            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            /** 
                @dev 闪电贷  后期重点
            */
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }

        //如果 余额0>储备0-amount0 
        //则   amount0In = 余额0 - (储备0-amounto0ut) 
        //否则 amount0In = 0
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;

        //如果 余额1>储备1-amount1 
        //则   amount1In = 余额1 - (储备1-amounto1ut) 
        //否则 amount1In = 0
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;

        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { //标记作用域 防止堆栈溢出
            // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            //调整后的余额0 = 余额0 * 1000 - （amount0In * 3 );
            uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            //调整后的余额1 = 余额1 * 1000 - （amount1In * 3 );
            uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
            // 确认 调整后的余额0 * 调整后的余额1 >= 储备0 * 储备1 * 100000
            // 判断是否交税
            require(
                balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(1000 ** 2),
                'UniswapV2: K'
            );
        }
        //更新储备
        _update(balance0, balance1, _reserve0, _reserve1);
        //触发事件
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /**
        @dev 强制平衡余额以匹配储备
        @param 如果余额大于储备量，流动性或者管理员都可以提取多余的余额出来以匹配储备量
     */
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        //余额大于储备，即可强制平衡
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    /**
        @dev 强制平衡储备量以匹配余额v
        如果储备量大于余额 ，或者说余额有无可能抗拒的机制性减少
        那么可以调用sync 以 更新储备量的值 以匹配余额
     */
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
