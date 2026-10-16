# Keelnet (KEEL)

A fixed-supply ERC-20 token for an IdentityMD custom token launch on Ethereum mainnet.

| Parameter | Value |
| --- | --- |
| Solidity contract | `KeelnetToken` (`src/KeelnetToken.sol`) |
| Token name (`name()`) | `Keelnet` |
| Token symbol (`symbol()`) | `KEEL` |
| Decimals | 18 |
| Total supply | 1,000,000,000 KEEL = `1000000000000000000000000000` minor units |
| Constructor arguments | none |
| Owner / admin | none |
| Compiler | solc 0.8.26, optimizer on (200 runs), `bytecode_hash = "none"`, `cbor_metadata = false` |

## Behaviour

- The constructor mints the whole supply once to `msg.sender`, the address that deploys the
  contract. For the IdentityMD launch that is the ProjectFactory, which then pays the supply out
  (swarm share, pool seed, remainder).
- Transfers are plain OpenZeppelin v5 ERC-20 transfers: no fee, no burn on transfer, no
  reflections, no transfer limits, no exemptions needed. Every launch flow (factory to
  distributor, distributor to claimant, pool seed, swaps either way) moves exactly the amount
  requested.
- There is no owner, no `mint`, no `burn`, no `pause`, no blocklist, no upgrade path, no
  `receive`/`fallback`. Nothing can grow the supply or move or freeze a holder's balance after
  deployment. The runtime contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`.
- The constructor calls no other contract and takes no address, so it deploys on an empty chain
  and the launch's bytecode is reproducible from this repository.

## Assumptions

- The brief asked for a plain token: name, symbol, supply and decimals only. No tax, vesting,
  governance or burn mechanics were requested, so none exist. Adding any later would require a
  new deployment; this contract cannot be changed.
- "Minted once to the deployer" is implemented as `_mint(msg.sender, TOTAL_SUPPLY)` in the
  constructor. Whoever deploys the bytecode holds all of it. Under the launch, that is the factory
  by construction; nothing in this repository names or assumes any other recipient.
- Decimals are the ERC-20 default of 18, matching the brief and the manifest.

## Launch parameters (decided by the launch, recorded here for reference)

These are copied from the launch terms. They are not set anywhere in this repository and the
manifest step writes them into `launch.json` after the work is accepted. Do not add a
`launch.json` to this tree.

| Setting | Value |
| --- | --- |
| Chain | Ethereum mainnet (chain id 1) |
| Paired currency | IMD, `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7` (18 decimals) |
| Pool fee | 12500 (1.25%) |
| Tick spacing | 60 |
| Initial price (sqrtPriceX96, provenance only) | `79228162514264337593543950336` |
| Pool share of supply | 80% (`poolBps` 8000) |
| Opening market cap | 3,400 IMD (`initialMarketCapWei` `3400000000000000000000`) |
| Remainder recipient | `0x0f44a55663e888bb63618a0c31b68cbc6c01aa71` |
| Swarm share | 10% of supply, taken by the factory to the launch's MerkleDistributor |

The deployer derives the actual opening price from the market cap, the supply and the token's
address at launch time.

## After launch

Nothing. The token has no owner-settable configuration, no outside dependencies and no
post-deployment steps. There is no setter to call and no value to supply.

## Operational responsibilities

- **Requester.** Receives the remainder of the supply at the `remainderTo` address above and is
  responsible for custody of that wallet. There is no admin key to protect because the contract
  has no admin.
- **IdentityMD deployer.** Deploys the built bytecode through the factory, records the contract
  under its Solidity name `KeelnetToken`, seeds the pool and forwards the shares. Explorer source
  verification (`forge verify-contract`) is the deployer's step after deployment and is an open
  item until it is done.
- **Nobody.** No one can pause, mint, burn from, freeze or upgrade. If a holder loses a key, the
  tokens are lost; if a holder sends tokens to the token contract's own address, they are stuck,
  as with any plain ERC-20. Users should be told both.

## Security notes

Checked against the pinned security checklist. The relevant items for a plain fixed-supply token:

- Access control: there are no privileged functions, so none can be misused.
- Reentrancy: the contract makes no external calls.
- Input validation: zero-address receivers and spenders revert; over-balance and over-allowance
  transfers revert with typed ERC-6093 errors.
- Events: `Transfer` on the mint and every transfer, `Approval` on every approval.
- Infinite approvals: `type(uint256).max` allowances are honoured and not decremented, as in
  standard OpenZeppelin ERC-20. Holders should approve bounded amounts to contracts they do not
  trust.
- Proxies, delegatecall, oracles, swaps: not used.

Tests passing are not an audit. The token holds no user funds itself, but a separate adversarial
review before release remains the launch policy's responsibility.

## Repository layout

```
foundry.toml              compiler pins and build settings
remappings.txt            forge-std and @openzeppelin/contracts remappings
src/KeelnetToken.sol      the token
script/DeployKeelnet.s.sol reference deploy script (the launch does not use it)
test/KeelnetToken.t.sol   unit and fuzz tests
lib/forge-std             vendored forge-std v1.11.0 (plain files, no submodule)
lib/openzeppelin-contracts vendored OpenZeppelin Contracts v5.4.0 (plain files, no submodule)
```

## Building and testing

```
forge build
forge test
forge fmt --check
```

The fuzz tests are deterministic under the verifier's seed:

```
FOUNDRY_FUZZ_SEED=0x1007a3d09cc5940a03d9d97439ad86a617f052eb5a1f69e16469d737aa578c51 forge test
```

Tests read no environment variables and do not depend on the calling address, so they pass in
any order and in parallel.

## Reference deployment (not the launch)

`script/DeployKeelnet.s.sol` exposes `deploy()`, which creates the token and leaves the supply
with the broadcasting signer. It reads no environment variables; pass the signer and RPC on the
command line:

```
forge script script/DeployKeelnet.s.sol --rpc-url <rpc> --broadcast --account <keystore>
```

This is for local reproduction and review only. The IdentityMD launch deploys the attested
bytecode through its factory; nobody in this job broadcasts anything.
