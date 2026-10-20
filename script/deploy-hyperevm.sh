#!/usr/bin/env bash
set -eo pipefail
export FOUNDRY_PROFILE=size-limited
RPC=$HYPEREVM_TESTNET_RPC_URL
export WMON_ADDRESS=0x5555555555555555555555555555555555555555

forge build

for M in DAO QuadraticDAO LiquidDAO OptimisticDAO DelegateDAO BoardDAO SortitionDAO ConvictionDAO SowellianDAO DecisionMarketsDAO; do
  forge script script/Deploy${M}Factory.s.sol:Deploy${M}Factory \
    --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast --slow \
    | tee -a hyperevm-deploy.log
  sleep 20
done

grep "Factory deployed at" hyperevm-deploy.log