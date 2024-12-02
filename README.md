# Melusi Escrow Smart Contract

A highly gas-optimized escrow contract for secure token swaps on EVM-compatible blockchains. The contract supports both one-to-one and multi-asset swaps for ERC721 and ERC1155 tokens, with optional native currency additions.

## Key Features

- **Efficient Token Swaps**: Support for both single and multi-asset swaps
- **Token Standards**: Compatible with ERC721 and ERC1155 tokens
- **Native Currency Support**: Option to include ETH/native currency in swaps
- **Gas Optimization**: Heavily optimized using assembly and bit manipulation
- **Subscription System**: Integration with premium subscription model for reduced fees
- **Secure Asset Handling**: Built-in interface validation and safe transfer mechanisms
- **Moderation System**: Role-based access control for fee collection

## Technical Implementation

### Bit Packing

The contract uses efficient bit packing techniques to minimize storage costs:

**Packed Cash Data Structure**:
- Bits [0-127]: `initiationFee`
- Bits [128-255]: `cashToBeAdded`

**Packed Asset Data Structure**:
- Bits [0-159]: `token` address
- Bits [160-183]: `tokenId`
- Bits [184-255]: `value`

### Swap Types

#### Single Asset Swap
Allows one-to-one token swaps with the following structure:
```solidity
struct SingleSwap {
    uint256 packedCashData;
    uint256 packedAssetData0;
    uint256 packedAssetData1;
}
```

#### Multi Asset Swap
Enables swapping multiple tokens simultaneously:
```solidity
struct MultiSwap {
    uint256 packedCashData;
    uint256[] packedAssetsData0;
    uint256[] packedAssetsData1;
}
```

## Usage Guide

### Initiating a Single Swap

```solidity
function initiateSingleSwap(
    uint256 cashToBeAdded,
    uint256 packedAssetData0,
    uint256 packedAssetData1
) external payable
```

1. Pack your asset data using `getPackedSingleAssetData(address token, uint24 tokenId, uint72 value)`
2. Approve the contract to transfer your token
3. Call `initiateSingleSwap` with:
   - `cashToBeAdded`: Amount of ETH the finalizer needs to add
   - `packedAssetData0`: Your packed token data
   - `packedAssetData1`: Desired token data
   - Include required fee in transaction value

### Initiating a Multi Swap

```solidity
function initiateMultiSwap(
    uint256 cashToBeAdded,
    uint256[] calldata packedAssetsData0,
    uint256[] calldata packedAssetsData1
) external payable
```

1. Create Asset structs for your tokens:
```solidity
struct Asset {
    address token;
    uint24 tokenId;
    uint72 value;
}
```
2. Use `getPackedMultiAssetData(Asset[] assets0, Asset[] assets1)` to pack data
3. Approve the contract for all tokens
4. Call `initiateMultiSwap` with packed data and required fee

### Finalizing Swaps

```solidity
function finalizeSingleSwap(address initiator) external payable
function finalizeMultiSwap(address initiator) external payable
```

1. Approve the contract to transfer your tokens
2. Call appropriate finalization function with:
   - `initiator`: Address that initiated the swap
   - Include required fee + `cashToBeAdded` in transaction value

### Cancelling Swaps

```solidity
function cancelSingleSwap() external
function cancelMultiSwap() external
```

Initiators can cancel their swaps at any time to retrieve their tokens and fees.

