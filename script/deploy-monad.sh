#!/usr/bin/env bash
set -e
RPC=https://testnet-rpc.monad.xyz
export WMON_ADDRESS=0xFb8bf4c1CC7a94c73D209a149eA2AbEa852BC541

forge build --via-ir

for M in DAO QuadraticDAO LiquidDAO OptimisticDAO DelegateDAO BoardDAO SortitionDAO ConvictionDAO SowellianDAO DecisionMarketsDAO; do
  forge script script/Deploy${M}Factory.s.sol:Deploy${M}Factory \
    --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast --via-ir \
    | tee -a monad-deploy.log
done

grep "Factory deployed at" monad-deploy.log