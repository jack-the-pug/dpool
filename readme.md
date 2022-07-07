# dPool 

> **Warning**
> NOT AUDITED - WIP - USE AT OWN RISK

dPool is a gas optimized smart contract for batch sending both native and ERC-20 tokens.

Contract Address: 0x1468E381595179DaBFE5bBfc72c9A27950A114C3 on Polygon Mainnet
### Main features

- isolated non-upgradeable contract dedicated to each user
- batch sending both native and ERC-20 tokens
- send multiple tokens in the same batch
- 2-step batch payment, set recipients first, pay later (by another address)
- pull mode: recipients need to claim by themselves
- send with permit (EIP-2612)