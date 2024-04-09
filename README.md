## Lyra Governance Token

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
