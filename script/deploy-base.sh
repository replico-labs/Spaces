#!/usr/bin/env bash
set -eo pipefail
export FOUNDRY_PROFILE=size-limited
RPC=https://sepolia.base.org
export WMON_ADDRESS=0x4200000000000000000000000000000000000006
# The Pyth Entropy adapter (README, deployed addresses): settles tied Delegate council seats.
export RANDOMNESS_SOURCE=0xaB7325AFfF2A7851457c52565Cfe4DC53DC9B1Fc

forge build

for M in DAO QuadraticDAO LiquidDAO OptimisticDAO DelegateDAO BoardDAO SortitionDAO ConvictionDAO SowellianDAO DecisionMarketsDAO Wrapper; do
  forge script script/Deploy${M}Factory.s.sol:Deploy${M}Factory \
    --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast \
    | tee -a base-deploy.log
  sleep 20
done

# The Launcher may call the token models' factories from this run.
LAUNCH_FACTORIES=$(for F in DAOFactory QuadraticDAOFactory LiquidDAOFactory OptimisticDAOFactory DelegateDAOFactory SortitionDAOFactory ConvictionDAOFactory SowellianDAOFactory DecisionMarketsDAOFactory; do
  grep "  $F deployed at:" base-deploy.log | tail -1 | awk '{print $NF}'
done | paste -sd, -)
export LAUNCH_FACTORIES
forge script script/DeployLaunchFactory.s.sol:DeployLaunchFactory \
  --rpc-url $RPC --private-key $PRIVATE_KEY --broadcast \
  | tee -a base-deploy.log

grep "Factory deployed at" base-deploy.log