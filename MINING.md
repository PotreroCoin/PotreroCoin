# Potrero Mining

At this time, Potreros can be efficiently mined with GPU or even CPU mining machines.

Note: as of 5/28/23 CPU mining is probably out of question.

## Solo mining via CLI

For quick solo mining runs you can also use `potrero-cli`/`bitcoin-cli`:

```
bitcoin-cli generatetoaddress <count> <address> [gpu] [maxtries]
```

Add the literal `gpu` after the payout address to request the GPU mining path (defaults to a CPU fallback), and optionally follow it with a numeric `maxtries` to limit how many hashing rounds are attempted (default 1000000).

## How to mine Potreros?

1. Obtain suitable hardware and software.
2. Create an account with your favorite mining pool then log in, if required.
3. Configure your mining device. Add your Potrero payout address.
4. Start mining!

Example using CCminer under Windows

`
ccminer.exe -a scrypt -o stratum+tcp://pool.potrerocoin.com:3000 -u PirwxqAfPhXubsQnhWn91wXhVNz9MvZZCc
`

## Potrero Mining Pools
To add a new mining pool to the list below, create a New Issue with title "new pool" and submit the request with a clear and accurate description of the pool, rewards and fees.
https://github.com/PotreroCoin/PotreroCoin/issues/new  
or reach out via Discord https://discord.gg/9zqQHtRH9q

## Mining Pools

| Pool                             | Stratum                          | Payout | Fee  | Added     |
| :------------------------------- | :------------------------------- | :----- | :--- | :-------- |
| http://pool.potrerocoin.com      | pool.potrerocoin:3000            | 1 min  | 1%   | 5/26/2023 |
