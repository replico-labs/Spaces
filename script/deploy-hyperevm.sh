#!/usr/bin/env bash
set -eo pipefail
export FOUNDRY_PROFILE=size-limited
RPC=$HYPEREVM_TESTNET_RPC_URL
export WMON_ADDRESS=0x5555555555555555555555555555555555555555
# The Pyth Entropy adapter (README, deployed addresses): settles tied Delegate council seats.
export RANDOMNESS_SOURCE=0xeEdE1CBa9f2A86AEB145a71167ee2020396C3BD3

forge build

for M in DAO QuadraticDAO LiquidDAO OptimisticDAO DelegateDAO BoardDAO SortitionDAO ConvictionDAO SowellianDAO DecisionMarketsDAO Wrapper; do
  forge script script/Deploy${M}Factory.s.sol:Deploy${M}Factory \
    --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast --slow \
    | tee -a hyperevm-deploy.log
  sleep 20
done

# The Launcher may call the token models' factories from this run.
LAUNCH_FACTORIES=$(for F in DAOFactory QuadraticDAOFactory LiquidDAOFactory OptimisticDAOFactory DelegateDAOFactory SortitionDAOFactory ConvictionDAOFactory SowellianDAOFactory DecisionMarketsDAOFactory; do
  grep "  $F deployed at:" hyperevm-deploy.log | tail -1 | awk '{print $NF}'
done | paste -sd, -)
export LAUNCH_FACTORIES
forge script script/DeployLaunchFactory.s.sol:DeployLaunchFactory \
  --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast --slow \
  | tee -a hyperevm-deploy.log

grep "Factory deployed at" hyperevm-deploy.log