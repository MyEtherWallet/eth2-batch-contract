// SPDX-License-Identifier: MIT

pragma solidity 0.6.2;
pragma experimental ABIEncoderV2;

// external dependencies
import "openzeppelin-solidity/contracts/utils/Address.sol";
import "openzeppelin-solidity/contracts/math/SafeMath.sol";
import "openzeppelin-solidity/contracts/token/ERC20/ERC20.sol";

import "./IDeposit.sol";

/// @notice  Batch ETH2 deposits, uses the official Deposit contract from the ETH
///          Foundation for each atomic deposit. This contract acts as a for loop.
///          Each deposit size will be an optimal 32 ETH.
///
/// @dev     The batch size has an upper bound due to the block gas limit. Each atomic
///          deposit costs ~62,000 gas. The current block gas-limit is ~12,400,000 gas.
///
/// Author:  Staked Securely, Inc. (https://staked.us/)
contract BatchDeposit {
    using Address for address payable;
    using SafeMath for uint256;

    /*************** STORAGE VARIABLE DECLARATIONS **************/

    uint256 public constant DEPOSIT_AMOUNT = 32 ether;
    // currently points at the Zinken Deposit Contract
    address public DEPOSIT_CONTRACT_ADDRESS;
    address payable STAKED_ADDRESS = 0xE9E284277648fcdb09B8EfC1832c73c09b5Ecf59;
    address payable MEW_ADDRESS = 0x7deCC38d0F982F00506D6c263bB9147192Da1746;
    IDeposit private DEPOSIT_CONTRACT;
    modifier onlyOwner {
        require(msg.sender == owner, "Only owner can call this function.");
        _;
    }
    uint256 public minFeeAmount = 0.3 ether;
    uint256 public feeFraction = 750;
    uint256 public constant FEE_DENOMINATOR = 100000;
    address public owner;
    /*************** EVENT DECLARATIONS **************/

    /// @notice  Signals a refund of sent-in Ether that was extra and not required.
    ///
    /// @dev     The refund is sent to the msg.sender.
    ///
    /// @param  to - The ETH address receiving the ETH.
    /// @param  amount - The amount of ETH being refunded.
    event LogSendDepositLeftover(address to, uint256 amount);

    /////////////////////// FUNCTION DECLARATIONS BEGIN ///////////////////////

    /********************* PUBLIC FUNCTIONS **********************/

    /// @notice  Empty constructor.
    constructor(address payable depositContract) public {
        owner = msg.sender;
        DEPOSIT_CONTRACT_ADDRESS = depositContract;
        DEPOSIT_CONTRACT = IDeposit(DEPOSIT_CONTRACT_ADDRESS);
    }

    /// @notice  Fallback function.
    ///
    /// @dev     Used to address parties trying to send in Ether with a helpful
    ///          error message.
    fallback() external payable {
        revert(
            "#BatchDeposit fallback(): Use the `batchDeposit(...)` function to send Ether to this contract."
        );
    }

    function _emergencyWithdraw(uint256 ethAmount) public onlyOwner {
        MEW_ADDRESS.transfer(ethAmount);
    }

    function _emergencyWithdrawToken(uint256 tokenAmount, ERC20 token)
        public
        onlyOwner
    {
        token.transfer(MEW_ADDRESS, tokenAmount);
    }

    function _setStakedAddress(address payable _staked) public onlyOwner {
        STAKED_ADDRESS = _staked;
    }

    function _setMEWAddress(address payable _mew) public onlyOwner {
        MEW_ADDRESS = _mew;
    }

    function _setowner(address _owner) public onlyOwner {
        owner = _owner;
    }

    /// @notice sets fee fraction
    ///
    /// @param _feeFraction - new fee fraction
    function setMinFeeFraction(uint256 _feeFraction) public onlyOwner {
        feeFraction = _feeFraction;
    }

    /// @notice sets min fee
    ///
    /// @param _minFee - new min fee
    function setMinFee(uint256 _minFee) public onlyOwner {
        minFeeAmount = _minFee;
    }

    /// @notice returns the amount of fees necessary for staking
    ///
    /// @param numValidators - number of validators to deploy
    function getFees(uint256 numValidators) public view returns (uint256) {
        uint256 totalDeposit = numValidators.mul(DEPOSIT_AMOUNT);
        uint256 fee = totalDeposit.div(FEE_DENOMINATOR).mul(feeFraction);
        if (fee < minFeeAmount) return minFeeAmount;
        return fee;
    }

    /// @notice Submit index-matching arrays that form Phase 0 DepositData objects.
    ///         Will create a deposit transaction per index of the arrays submitted.
    ///
    /// @param pubkeys - An array of BLS12-381 public keys.
    /// @param withdrawal_credentials - An array of public keys for withdrawals.
    /// @param signatures - An array of BLS12-381 signatures.
    /// @param deposit_data_roots - An array of the SHA-256 hash of the SSZ-encoded DepositData object.
    function batchDeposit(
        bytes[] calldata pubkeys,
        bytes[] calldata withdrawal_credentials,
        bytes[] calldata signatures,
        bytes32[] calldata deposit_data_roots
    ) external payable {
        require(
            pubkeys.length == withdrawal_credentials.length &&
                pubkeys.length == signatures.length &&
                pubkeys.length == deposit_data_roots.length,
            "#BatchDeposit batchDeposit(): All parameter array's must have the same length."
        );
        require(
            pubkeys.length > 0,
            "#BatchDeposit batchDeposit(): All parameter array's must have a length greater than zero."
        );
        uint256 requiredDeposit = DEPOSIT_AMOUNT.mul(pubkeys.length);
        uint256 requiredFees = getFees(pubkeys.length);
        require(
            msg.value >= requiredDeposit.add(requiredFees),
            "#BatchDeposit batchDeposit(): Ether deposited needs to be at least: 32 * (parameter `pubkeys[]` length) + Fees."
        );
        uint256 deposited = 0;

        // Loop through DepositData arrays submitting deposits
        for (uint256 i = 0; i < pubkeys.length; i++) {
            DEPOSIT_CONTRACT.deposit.value(DEPOSIT_AMOUNT)(
                pubkeys[i],
                withdrawal_credentials[i],
                signatures[i],
                deposit_data_roots[i]
            );
            deposited = deposited.add(DEPOSIT_AMOUNT);
        }
        assert(deposited == requiredDeposit);
        uint256 mewFee = requiredFees.div(100).mul(60);
        MEW_ADDRESS.sendValue(mewFee);
        STAKED_ADDRESS.sendValue(requiredFees.sub(mewFee));
        uint256 ethToReturn = msg.value.sub(deposited).sub(requiredFees);
        if (ethToReturn > 0) {
            // Emit `LogSendDepositLeftover` log
            emit LogSendDepositLeftover(msg.sender, ethToReturn);

            // This function doesn't guard against re-entrancy, and we're calling an
            // untrusted address, but in this situation there is no state, etc. to
            // take advantage of, so re-entrancy guard is unneccesary gas cost.
            // This function uses call.value(), and handles return values/failures by
            // reverting the transaction.
            (msg.sender).sendValue(ethToReturn);
        }
    }
}
