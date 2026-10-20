#!/usr/bin/env bash
set -eo pipefail
export FOUNDRY_PROFILE=size-limited
RPC=https://sepolia.base.org
export WMON_ADDRESS=0x4200000000000000000000000000000000000006

forge build

for M in DAO QuadraticDAO LiquidDAO OptimisticDAO DelegateDAO BoardDAO SortitionDAO ConvictionDAO SowellianDAO DecisionMarketsDAO; do
  forge script script/Deploy${M}Factory.s.sol:Deploy${M}Factory \
    --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast \
    | tee -a base-deploy.log
  sleep 20
done

grep "Factory deployed at" base-deploy.log