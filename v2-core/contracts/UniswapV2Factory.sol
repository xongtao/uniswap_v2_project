pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo;  //收税地址
    address public feeToSetter;  //管理者可以设置收税地址

    mapping(address => mapping(address => address)) public getPair;
    
    address[] public allPairs;//所有配对合约的地址

    //设置触发事件 indexed索引 可以通过索引查事件的 pair地址   uint标记事件顺序 
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);
    
    /**
        @dev 设置管理员
     */
    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }
    /** 
        @dev  传入token A 与 token B 的地址 创建pair合约并返回
        @param tokenA tokenA
        @param tokenB tokenB
        @return 返回pair合约地址
    */
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        //判断tokenA 不等于tokenb
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');

        //三目运算比较token A B哪个值小，小的在前，从而保证creat2方法中的参数salt唯一 ，取别名token0，token1；
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        //address(0)是00000...地址，简单判断地址是否有效，因为token0<token1,所以只需判断一个
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');

        //getpair映射，判断是否已经存在对应pair，token0=>token1
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        
        //获取pair合约编译后 的字节码
        bytes memory bytecode = type(UniswapV2Pair).creationCode;

        //将token0与token1进行打包得到一个字节序列，然后通过取哈希方法得到byte32位的数据
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));

        // 内联汇编(opcode) ：直接调用evm底层  creat2:通过预先对合约进行编译，来提前预知地址
        // 0代表创建交易对合约不需要发送以太币， add(bytecode,32)表示跳过字节码直接到实际代码部分，mload(bytecode)表示字节码大小
        // salt表示合约创建唯一  
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }

        //调用pair合约 传递token0 token1,进行初始化
        IUniswapV2Pair(pair).initialize(token0, token1);

        //正反存储 token0token1的合约地址 
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }



    /**
       @dev 管理员设置收税地址
       @param _feeTo 收税地址
    */
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    /** 
        @dev 设置管理员地址 只有合约发起者可以设置 
        @param _feeToSetter 管理员地址 
    */
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
