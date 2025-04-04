// SPDX-License-Identifier: MIT

pragma solidity 0.8.18; 

interface IERC165 {
    function supportsInterface(bytes4 _interfaceId)
    external
    view
    returns (bool);
}

interface IERC721 {
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;
}

interface IERC1155 {
    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes calldata data) external;
}

interface IMelusiRouter {
    function hasSubscription(address user) external view returns (bool);
    function swapFee() external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

contract MelusiEscrow {
    /**
     * @dev Failed to transfer Ether to recipient address.
     */
    error CashTransferFailed();

    /**
     * @dev Value for cash to be added or the amount of Ether sent with the transaction exceeds the max limit of uint128.
     */
    error CashToBeAddedOrValueTooHigh();

    /**
     * @dev The swap being attempted to access does not exist.
     */
    error SwapNonExistent();

    /**
     * @dev The caller already has an active single asset swap.
     */
    error SingleSwapExists();

    /**
     * @dev The caller already has an active multi asset swap.
     */
    error MultiSwapExists();

    /**
     * @dev The caller did not provide the correct amount of fee required to perform the action.
     */
    error FeeValidationFailed();

    /**
     * @dev The provided packed asset/s data does not meet the requirements.
     */
    error InvalidAssetsProvided();

    /**
     * @dev Failed to validate interface support for the provided token.
     */
    error FailedToValidateInterfaceSupport();

    /**
     * @dev Access is restricted to addresses with the `MODERATOR_ROLE`
     */
    error OnlyModerator();

    // packedCashData Bits Layout:
    // - [0..127]   `initiationFee`
    // - [128..255] `cashToBeAdded`

    // packedAssetData Bits Layout:
    // - [0..159]   `token`
    // - [160..183] `tokenId`
    // - [184..255] `value`

    struct SingleSwap {
        uint256 packedCashData;
        uint256 packedAssetData0;
        uint256 packedAssetData1;
    }

    struct MultiSwap {
        uint256   packedCashData; 
        uint256[] packedAssetsData0;
        uint256[] packedAssetsData1;
    }

    /**
     * @dev `value` should always be 0 for ERC721/ERC721A NFTs
    */
    struct Asset {
        address token;
        uint24  tokenId;
        uint72  value; 
    } // Struct only used as input during data packing for multi swap

    bytes32 private constant MODERATOR_ROLE = 0x71f3d55856e4058ed06ee057d79ada615f65cdf5f9ee88181b914225088f834f; // keccak256("MODERATOR_ROLE")

    bytes4 private constant _INTERFACE_ID_721  = 0x80ac58cd;
    bytes4 private constant _INTERFACE_ID_1155 = 0xd9b67a26;
    
    IMelusiRouter 
    private 
    constant _MELUSI_LIB = IMelusiRouter(0x0000000000000000000000000000000000000000); 
    address private constant _TREASURY = 0x0000000000000000000000000000000000000000;

    uint256 public accumulatedFee;

    mapping(address => SingleSwap) private _singleSwapsPackedData; 
    mapping(address => MultiSwap)  private _multiSwapsPackedData;

    event SingleSwapInitiated(address indexed initiator, uint256 packedAssetData0, uint256 packedAssetData1, uint initiationFee);
    event SingleSwapFinalized(address indexed initiator, address indexed finalizer, uint256 packedAssetData0, uint256 packedAssetData1, uint256 cashAdded, uint256 finalizationFee);
    event SingleSwapCancelled(address indexed initiator, uint256 feeRefunded);

    event MultiSwapInitiated(address indexed initiator, uint256[] packedAssetsData0, uint256[] packedAssetsData1, uint initiationFee);
    event MultiSwapFinalized(address indexed initiator, address indexed finalizer, uint256[] packedAssetsData0, uint256[] packedAssetsData1, uint finalizationFee);
    event MultiSwapCancelled(address indexed initiator, uint256 feeRefunded);

    event FeeCollected(address collector, uint256 amount);

    /**
     * @dev Reverts if either `msg.value` or `cashToBeAdded` is greater than the uint128 max limit.
     */
    modifier cashInRange(uint256 cashToBeAdded){
        bool notInRange;

        assembly {
            notInRange := or(lt(shl(128, 1), callvalue()), lt(shl(128, 1), cashToBeAdded))
        }

        if(notInRange) _revert(CashToBeAddedOrValueTooHigh.selector);
        _;
    }

    /**
     * @notice Initiates a one to one asset swap.
     * @param cashToBeAdded    Amount of cash to be added by the swap finalizer.
     * @param packedAssetData0 Packed data of the asset that the initiator will be providing.
     * @param packedAssetData1 Packed data of the asset that the finalizer will be providing.
     * 
     * Requirements:
     * 
     * - caller must not have an active single swap.
     * - all packed asset data must contain valid token information.
     * - eth sent with transaction and `cashToBeAdded` should be within valid uint128 range.
     * - appropriate amount of fee must have been sent.
     * - caller must have approved contract to transfer token in `packedAssetData0`.
     */
    function initiateSingleSwap(
        uint256 cashToBeAdded,
        uint256 packedAssetData0,
        uint256 packedAssetData1
    ) external payable cashInRange(cashToBeAdded) {
        SingleSwap storage singleSwap = _singleSwapsPackedData[msg.sender];
        if(singleSwap.packedAssetData0 != 0) 
            _revert(SingleSwapExists.selector);

        _validateFee(msg.value, 2);
        
        if(packedAssetData0 == 0 || packedAssetData1 == 0) _revert(InvalidAssetsProvided.selector);  

        singleSwap.packedCashData = getPackedCashData(msg.value, cashToBeAdded); 
        singleSwap.packedAssetData0 = packedAssetData0;
        singleSwap.packedAssetData1 = packedAssetData1;

        (address token, uint256 tokenId, uint256 value) = getUnpackedSingleAssetData(packedAssetData0);

        _transferAsset(msg.sender, address(this), token, tokenId, value);

        emit SingleSwapInitiated(msg.sender, packedAssetData0, packedAssetData1, msg.value);
    }

    /**
     * @notice Initiates a multi asset swap.
     * @param cashToBeAdded     Amount of cash to be added by the swap finalizer.
     * @param packedAssetsData0 Packed data of the asset/s that the initiator will be providing.
     * @param packedAssetsData1 Packed data of the asset/s that the finalizer will be providing.
     * 
     * Requirements:
     * 
     * - caller must not have an active multi swap.
     * - all packed asset data must contain valid token information.
     * - eth sent with transaction and `cashToBeAdded` should be within valid uint128 range.
     * - appropriate amount of fee must have been sent.
     * - caller must have approved contract to transfer tokens in `packedAssetsData0`.
     */
    function initiateMultiSwap(
        uint256 cashToBeAdded,
        uint256[] calldata packedAssetsData0,
        uint256[] calldata packedAssetsData1
    ) external payable cashInRange(cashToBeAdded) {
        MultiSwap storage multiswap = _multiSwapsPackedData[msg.sender];
        if(multiswap.packedAssetsData0.length != 0) 
            _revert(MultiSwapExists.selector);

        uint256 length0 = packedAssetsData0.length; 
        uint256 length1 = packedAssetsData1.length;

        if(length0 <= 1 && length1 <= 1) _revert(InvalidAssetsProvided.selector);
        _validateFee(msg.value, length0 + length1);

        multiswap.packedCashData = getPackedCashData(msg.value, cashToBeAdded);
        multiswap.packedAssetsData0 = packedAssetsData0;
        multiswap.packedAssetsData1 = packedAssetsData1;

        address token;
        uint256 tokenId;
        uint256 value;

        for(uint256 i; i < length0; ) {
            (token, tokenId, value) = getUnpackedSingleAssetData(packedAssetsData0[i]);
            _transferAsset(msg.sender, address(this), token, tokenId, value);

            unchecked {
                i = i + 1;
            }
        }

        emit MultiSwapInitiated(msg.sender, packedAssetsData0, packedAssetsData1, msg.value);
    }

    /**
     * @notice Finalizes an active one to one asset swap.
     * @param initiator Address of the swap initiator.
     * 
     * Requirements:
     * 
     * - `initiator` must have an active single swap.
     * - caller must have approved the contract to transfer the output token specified in the swap.
     * - appropriate amount of fee must have been sent.
     * - if `cashToBeAdded` is a positive integer, caller must have sent that value along with the fee.
     */
    function finalizeSingleSwap(address initiator) external payable {
        SingleSwap memory singleSwap = _singleSwapsPackedData[initiator];
        uint packedAssetData0 = singleSwap.packedAssetData0;
        uint packedAssetData1 = singleSwap.packedAssetData1;

        if(packedAssetData1 == 0) 
            _revert(SwapNonExistent.selector);

        (uint256 initiationFee, uint256 cashToBeAdded) = getUnpackedCashData(singleSwap.packedCashData);
        uint256 finalizationFee = msg.value - cashToBeAdded;

        _validateFee(finalizationFee, 2);

        delete _singleSwapsPackedData[initiator];
        unchecked {
            accumulatedFee = accumulatedFee + initiationFee + finalizationFee;
        }

        (
            address tokenIn, 
            uint256 tokenIdIn, 
            uint256 valueIn
        ) = getUnpackedSingleAssetData(packedAssetData0);

        (
            address tokenOut, 
            uint256 tokenIdOut, 
            uint256 valueOut
        ) = getUnpackedSingleAssetData(packedAssetData1);

        _transferAsset(msg.sender, initiator, tokenOut, tokenIdOut, valueOut);
        _transferAsset(address(this), msg.sender, tokenIn, tokenIdIn, valueIn);

        if(cashToBeAdded > 0) _sendCash(initiator, cashToBeAdded);

        emit SingleSwapFinalized(initiator, msg.sender, packedAssetData0, packedAssetData1, cashToBeAdded, finalizationFee);
    }

    /**
     * @notice Finalizes an active multi asset swap.
     * @param initiator Address of the swap initiator.
     * 
     * Requirements:
     * 
     * - `initiator` must have an active multi swap.
     * - caller must have approved the contract to transfer the output tokens specified in the swap.
     * - appropriate amount of fee must have been sent.
     * - if `cashToBeAdded` is a positive integer, caller must have sent that value along with the fee.
     */
    function finalizeMultiSwap(address initiator) external payable {
        MultiSwap memory multiSwap = _multiSwapsPackedData[initiator];
        uint256 length0 = multiSwap.packedAssetsData0.length;
        uint256 length1 = multiSwap.packedAssetsData1.length;

        if(length1 == 0) _revert(SwapNonExistent.selector);

        (uint256 initiationFee, uint256 cashToBeAdded) = getUnpackedCashData(multiSwap.packedCashData);
        uint256 finalizationFee = msg.value - cashToBeAdded;

        _validateFee(finalizationFee, length0 + length1);

        delete _multiSwapsPackedData[initiator];
        unchecked {
            accumulatedFee = accumulatedFee + initiationFee + finalizationFee; 
        }

        address token;
        uint256 tokenId;
        uint256 value;

        for(uint256 i; i < length1; ) {
            (token, tokenId, value) = getUnpackedSingleAssetData(multiSwap.packedAssetsData1[i]);
            _transferAsset(msg.sender, initiator, token, tokenId, value);

            unchecked {
                i = i + 1;
            }
        }

        if(cashToBeAdded > 0) _sendCash(initiator, cashToBeAdded);

        for(uint256 j; j < length0; ) {
            (token, tokenId, value) = getUnpackedSingleAssetData(multiSwap.packedAssetsData0[j]);
            _transferAsset(address(this), msg.sender, token, tokenId, value);

            unchecked {
                j = j + 1;
            }
        }

        emit MultiSwapFinalized(initiator, msg.sender, multiSwap.packedAssetsData0, multiSwap.packedAssetsData1, finalizationFee);
    }

    /**
     * @notice Cancels active single asset swap initiated by the caller if it exists.
     *         Returns the token that was being kept in escrow along with any fee that was taken.
     */
    function cancelSingleSwap() external {
        SingleSwap memory singleSwap = _singleSwapsPackedData[msg.sender];

        if(singleSwap.packedAssetData0 == 0) _revert(SwapNonExistent.selector);

        delete _singleSwapsPackedData[msg.sender];

        (uint256 feeToBeRefunded, ) = getUnpackedCashData(singleSwap.packedCashData);
        (address token, uint256 tokenId, uint256 value) = getUnpackedSingleAssetData(singleSwap.packedAssetData0);

        _transferAsset(address(this), msg.sender, token, tokenId, value);
        if(feeToBeRefunded > 0) _sendCash(msg.sender, feeToBeRefunded);

        emit SingleSwapCancelled(msg.sender, feeToBeRefunded);
    }

    /**
     * @notice Cancels active multi asset swap initiated by the caller if it exists.
     *         Returns the tokens that were being kept in escrow along with any fee that was taken.
     */
    function cancelMultiSwap() external {
        MultiSwap memory multiSwap = _multiSwapsPackedData[msg.sender];
        uint256 length0 = multiSwap.packedAssetsData0.length;

        if(length0 == 0) _revert(SwapNonExistent.selector);

        delete _multiSwapsPackedData[msg.sender];

        (uint256 feeToBeRefunded, ) = getUnpackedCashData(multiSwap.packedCashData);

        address token;
        uint256 tokenId;
        uint256 value;

        for(uint256 i; i < length0; ) {
            (token, tokenId, value) = getUnpackedSingleAssetData(multiSwap.packedAssetsData0[i]);
            _transferAsset(address(this), msg.sender, token, tokenId, value);

            unchecked {
                i = i + 1;
            }
        }

        if(feeToBeRefunded > 0) _sendCash(msg.sender, feeToBeRefunded);

        emit MultiSwapCancelled(msg.sender, feeToBeRefunded);
    }

    /**
     * @dev Returns packed data arrays corresponding to the provided asset arrays.
     * @param assets0 Array of assets the initiator will provide. 
     * @param assets1 Array of assets the finalizer will provide. 
     * 
     * Requirements:
     * 
     * - both asset arrays should contain one or more assets. Use `getPackedSingleAssetData` instead to pack one asset.
     * - assets provided must contain valid token data each supporting their relevant interface id.
     */
    function getPackedMultiAssetData(
        Asset[] calldata assets0,
        Asset[] calldata assets1
    ) external view returns (uint256[] memory, uint256[] memory) {
        uint256 length0 = assets0.length;
        uint256 length1 = assets1.length;

        if(length0 <= 1 && length1 <= 1) 
            _revert(InvalidAssetsProvided.selector);

        uint256[] memory packedAssetsData0 = new uint256[](length0); 
        uint256[] memory packedAssetsData1 = new uint256[](length1);

        for(uint256 i; i < length0; ) {
            packedAssetsData0[i] = 
            getPackedSingleAssetData(assets0[i].token, assets0[i].tokenId, assets0[i].value);

            unchecked {
                i = i + 1;
            }
        }
        
        for(uint256 j; j < length1; ) {
            packedAssetsData1[j] = 
            getPackedSingleAssetData(assets1[j].token, assets1[j].tokenId, assets1[j].value);

            unchecked {
                j = j + 1;
            }
        }

        return (packedAssetsData0, packedAssetsData1);
    }

    /**
     * @notice Transfers accumulated fee to the treasury.
     *         Marked as payable to reduce gas usage.
     *         Correct input assumed due to restricted acccess.
     * 
     * Requirements:
     * 
     * - caller must have `MODERATOR_ROLE`
     */
    function collectAccumulatedFee() external payable {
        if(!_MELUSI_LIB.hasRole(MODERATOR_ROLE, msg.sender))
            _revert(OnlyModerator.selector);

        uint amount = accumulatedFee;
        accumulatedFee = 0;

        _sendCash(_TREASURY, amount);

        emit FeeCollected(msg.sender, amount);
    }

    /**
     * @dev ERC721Receiver compliance.
     */
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4) {
        return 0x150b7a02; // onERC721Received.selector
    }

    /**
     * @dev ERC1155Receiver compliance.
     */
    function onERC1155Received(
        address operator,
        address from,
        uint256 id,
        uint256 value,
        bytes calldata data
    ) external returns (bytes4) {
        return 0xf23a6e61; // onERC1155Received.selector
    }

    /**
     * @dev Packs the provided asset details.
     * @param token       Address of the token contract.
     * @param tokenId     id of the token.
     * @param value       Amount of tokens to be transferred. Should be zero for ERC721 tokens.
     * @return packedData Packed data containing the provided asset details.
     * 
     * Requirements:
     * 
     * - provided token must support their relevant interface id.
     */
    function getPackedSingleAssetData(address token, uint24 tokenId, uint72 value) public view returns (uint256 packedData) {
        _supportsInterface(token, value);
        assembly {
            packedData := or(or(shl(96, token), shl(72, tokenId)), value)
        }
    }

    /**
     * @dev Unpacks and returns asset details from the provided packed data.
     */
    function getUnpackedSingleAssetData(uint256 packedData) public pure returns (address token, uint24 tokenId, uint72 value) {
        assembly {
            token := shr(96, packedData)
            tokenId := and(shr(72, packedData), 0xFFFFFF)
            value := and(packedData, 0xFFFFFFFFFFFFFFFFFFFF)
        }
    }

    /**
     * @dev Packs the provided `initiationFee` and `cashToBeAdded` and returns the packed data.
     *      Used internally by the contract to pack cash data.
     * NOTE: `initiationFee` and `cashToBeAdded` must be within the range 0 to 2**128 - 1.
     */
    function getPackedCashData(uint256 initiationFee, uint256 cashToBeAdded) public pure returns (uint packedCashData) {
        assembly {
            packedCashData := or(shl(128, initiationFee), cashToBeAdded)
        }
    }
    
    /**
     * @dev Unpacks the provided `packedCashData` and returns the `initiationFee` and `cashToBeAdded` values inside it.
     */
    function getUnpackedCashData(uint256 packedCashData) public pure returns (uint256 initiationFee, uint256 cashToBeAdded) {
        assembly {
            initiationFee := shr(128, packedCashData)
            cashToBeAdded := and(packedCashData, 0xffffffffffffffffffffffffffffffff) // Correct mask for lower 128 bits
        }
    }

    /**
     * @dev Validates whether the caller has sent the correct amount of swap fee with the transaction.
     *      If the caller has premium subscription then fee is not taken.
     */
    function _validateFee(uint256 feeAmount, uint256 totalAssets) private view {
        bool incorrectFee = _MELUSI_LIB.hasSubscription(msg.sender) 
                            ? feeAmount > 0 
                            : feeAmount != (_MELUSI_LIB.swapFee() * totalAssets);
        
        if(incorrectFee)
            _revert(FeeValidationFailed.selector);
    }

    /**
     * @dev Performs a token transfer using the appropriate interface.
     */
    function _transferAsset(address from, address to, address token, uint256 tokenId, uint256 value) private {
        if(value == 0) 
            IERC721(token).safeTransferFrom(from, to, tokenId, "");
        else 
            IERC1155(token).safeTransferFrom(from, to, tokenId, value, "");
    }

    /**
     * @dev Transfers `amount` of native currency to `recipient`
     */
    function _sendCash(address recipient, uint256 amount) private {
        bool transferError;
        assembly {
            transferError := iszero(call(gas(), recipient, amount, 0, 0, 0, 0))
        }

        if(transferError) _revert(CashTransferFailed.selector);
    }

    /**
     * @dev For efficient reverts.
     */
    function _revert(bytes4 errorSelector) private pure {
        assembly {
            mstore(0x00, errorSelector)
            revert(0x00, 0x04)
        }
    }

    /**
     * @dev Validates whether the token address provided supports the relevant interface id.
     */
    function _supportsInterface(address token, uint256 value) private view {
        bool success;
        bytes memory data;

        if(value == 0) 
            (success, data) =
            token.staticcall(abi.encodeWithSelector(IERC165.supportsInterface.selector, _INTERFACE_ID_721));
        else
            (success, data) =
            token.staticcall(abi.encodeWithSelector(IERC165.supportsInterface.selector, _INTERFACE_ID_1155));

        if(!success || !abi.decode(data, (bool))) _revert(FailedToValidateInterfaceSupport.selector);
    }
}
