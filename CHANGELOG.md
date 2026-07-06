# Changelog

## 1.0.0 (2026-07-06)


### Features

* add allowance store model ([d793bca](https://github.com/lambdasistemi/cardano-multisig/commit/d793bca746934e1fd123048307304b8d80ca93d1))
* add checkpointed fee chain follower ([cfee945](https://github.com/lambdasistemi/cardano-multisig/commit/cfee9452b0aff4d40fe83f46e335b2644605f0e4))
* add devnet server run recipe ([6b65e7e](https://github.com/lambdasistemi/cardano-multisig/commit/6b65e7ec0c28a0502570072936cc94a1eb7dee7c))
* add fee status endpoint ([20d629b](https://github.com/lambdasistemi/cardano-multisig/commit/20d629b85854d5d844e27e46569f000daa4a2257))
* add fee tag metadata codec ([c685b10](https://github.com/lambdasistemi/cardano-multisig/commit/c685b1012691bbad81bd0371ed89ad3efaf8cf05))
* add liveness monitor tick ([c2f1361](https://github.com/lambdasistemi/cardano-multisig/commit/c2f136117f3dee6bb57a90a65f3025bbc6a62106))
* add pending transaction store ([4109d9d](https://github.com/lambdasistemi/cardano-multisig/commit/4109d9d2a0c4d295177578e766a2c7c3681ceb33))
* add publish admission gate ([94fe8e5](https://github.com/lambdasistemi/cardano-multisig/commit/94fe8e561ebbe3a4d2c32ae526f2f8b41db5cb1e))
* add signer-controlled filter query ([25b4f90](https://github.com/lambdasistemi/cardano-multisig/commit/25b4f90aeaeb8e76041c0384b6608fa8d6c7561f))
* add witness collection core ([612b439](https://github.com/lambdasistemi/cardano-multisig/commit/612b4390bec87e707a9565d20b8463b0b7b2c9fd))
* admit publish on indexed fee allowance ([53bcae8](https://github.com/lambdasistemi/cardano-multisig/commit/53bcae8130d8a8a89c6e4f6ed18c9b17ae8ba191))
* ChainSource with N2C phase-1 pre-flight (E2 slice 2) ([b5813f8](https://github.com/lambdasistemi/cardano-multisig/commit/b5813f85f561de7d3c3447a0edd4044eb4b4fafd))
* read NETWORK and PORT from env; operator schedule reports network ([9698b03](https://github.com/lambdasistemi/cardano-multisig/commit/9698b03aa0de64f62bbd9709cac7fcc301502654))
* record malformed fee payments ([e7e78be](https://github.com/lambdasistemi/cardano-multisig/commit/e7e78be76e46795de5f8914f4269837180a1dce5))
* scaffold haskell/nix service with /v1 server skeleton ([35cd627](https://github.com/lambdasistemi/cardano-multisig/commit/35cd627dcf5f6460ca6ab718d4e69ca3006e03b7))
* start fee indexer with server ([c1814c3](https://github.com/lambdasistemi/cardano-multisig/commit/c1814c3943b61838b5e6e99fd76c076420aab71e))
* submit ready entries with receipts ([6cd44f9](https://github.com/lambdasistemi/cardano-multisig/commit/6cd44f9329c759dbee19ee5e2c516b4410bf3e75))
* wire cardano-tx-tools closure (CHaP, crypto libs, phase-1 re-export) ([d85cd19](https://github.com/lambdasistemi/cardano-multisig/commit/d85cd195ce95db0ea548ef84a90cebcb93aa3c00))
* wire liveness into server ([2d2a525](https://github.com/lambdasistemi/cardano-multisig/commit/2d2a525df7870da2901f44b8470bf0b54554aa60))
* wire publish HTTP routes ([a578df7](https://github.com/lambdasistemi/cardano-multisig/commit/a578df7a2b819717802889da87947a08d3f35d02))
* wire witness collection routes ([40b4cdf](https://github.com/lambdasistemi/cardano-multisig/commit/40b4cdf308bd81eaec2747fbf7e80f162c0576fb))


### Bug Fixes

* **ci:** drop docker publish jobs (no daemon on nixos runners) ([730bc4e](https://github.com/lambdasistemi/cardano-multisig/commit/730bc4e93098ef104c6bcff0a91421d5b5f98bb6))
* pin dev-shell tools to index-state 2026-04-17 with cabal-fmt allow-newer ([bcb0bf2](https://github.com/lambdasistemi/cardano-multisig/commit/bcb0bf2788f54115e46a920002452918f7bb7012))
* use cabal-check for dev-shell CI gate ([f13d7f4](https://github.com/lambdasistemi/cardano-multisig/commit/f13d7f4acd04ff4af134a9e8b5850b56dcf101d9))

## Changelog

All notable changes to this project are documented in this file. The
format is managed by [release-please](https://github.com/googleapis/release-please).
