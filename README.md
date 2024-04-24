## ERC20AdvancedDelegationVotes
Based on OZ's [ERC20Votes](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC20Votes.sol), ERC20AdvancedDelegationVotes is an ERC20 token implementation that allows token holders to delegate to multiple delegates instead of just one.

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Deploy on testnet

```shell
# First, copy .env.example to .env and fill in the required values
$ forge script script/DeployAndMintToAdmin.s.sol --rpc-url YOUR_RPC_URL_HERE --broadcast
```
