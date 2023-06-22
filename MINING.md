# Potrero Mining

At this time, Potreros can be efficiently mined with GPU or even CPU mining machines.

Note: as of 5/28/23 CPU mining is probably out of question.

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

A number of mining pools have been confirmed to work reliably.

| Pool                             | Stratum                          | Payout | Fee  | Added     |
| :------------------------------- | :------------------------------- | :----- | :--- | :-------- |
| http://pool.potrerocoin.com      | pool.potrerocoin:3000            | 1 min  | 1%   | 5/26/2023 |
| https://wsdpool.online           | serveo.net:7077                  | 6 h    | 1%   | 6/22/2023 |
| https://cminer.org               | cminer.org:4073                  | 1 h    | 0.5% | 6/22/2023 |
